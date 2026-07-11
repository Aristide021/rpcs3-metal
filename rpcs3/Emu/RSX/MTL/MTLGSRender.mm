#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

// Apple's CarbonCore MachineExceptions.h (transitively via Foundation) defines
// `Vector128` as a typedef union. This collides with RPCS3's `Vector128`
// concept in util/v128.hpp. Rename Apple's symbol during the Obj-C imports.
#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>
#undef Vector128

#include "stdafx.h"
#include "MTLGSRender.h"
#include "MTLFormats.h"
#include "Emu/RSX/RSXThread.h"
#include "Emu/RSX/Common/surface_store.h"
#include "Emu/RSX/Program/SPIRVCommon.h"
#include "Emu/Cell/lv2/sys_rsx.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_log, "MTL");

// ---------------------------------------------------------------------------
// MTLState — all Obj-C objects, invisible to C++ translation units.
// Also owns the per-frame command buffer and drawable.
// ---------------------------------------------------------------------------
// CPUThread (which we transitively inherit from via GSRender→rsx::thread) has
// a `u32 id` member that shadows Obj-C's `id` keyword inside method bodies.
// These namespace-scope typedefs let us refer to id<Protocol> types inside
// method bodies without triggering the shadow.
typedef id<MTLBuffer>              MTLBufferRef;
typedef id<MTLTexture>             MTLTextureRef;
typedef id<MTLBlitCommandEncoder>  MTLBlitCommandEncoderRef;
typedef id<MTLRenderCommandEncoder> MTLRenderCommandEncoderRef;
typedef id<MTLRenderPipelineState> MTLRenderPipelineStateRef;
typedef id<MTLDepthStencilState>   MTLDepthStencilStateRef;
typedef id<MTLSamplerState>        MTLSamplerStateRef;
typedef id<CAMetalDrawable>        CAMetalDrawableRef;

struct MTLState
{
	id<MTLDevice>            device        = nil;
	id<MTLCommandQueue>      command_queue = nil;
	CAMetalLayer*            layer         = nil;

	// Per-frame state
	id<MTLCommandBuffer>        cmd_buffer       = nil;
	id<MTLRenderCommandEncoder> render_encoder   = nil;
	id<CAMetalDrawable>         drawable         = nil;
};

// ---------------------------------------------------------------------------
// MTLGSRender
// ---------------------------------------------------------------------------

MTLGSRender::MTLGSRender(utils::serial* ar)
	: GSRender(ar)
	, m_mtl(std::make_unique<MTLState>())
{
}

MTLGSRender::~MTLGSRender() = default;

void MTLGSRender::on_exit()
{
	@autoreleasepool
	{
		end_render_encoder();

		if (m_stub_buffer)
		{
			MTLBufferRef stub_obj = (__bridge MTLBufferRef)m_stub_buffer;
			[stub_obj release];
			m_stub_buffer = nullptr;
		}

		m_pipeline_cache.clear();
		m_texture_cache.clear();
		m_sampler_cache.clear();
		m_ds_cache.clear();
		m_rtts.clear();

		spirv::finalize_compiler_context();

		m_mtl->cmd_buffer     = nil;
		m_mtl->drawable       = nil;
		m_mtl->render_encoder = nil;
		m_mtl->command_queue  = nil;
		m_mtl->layer          = nil;
		m_mtl->device         = nil;
	}

	GSRender::on_exit();
}

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------
void MTLGSRender::on_init_thread()
{
	GSRender::on_init_thread();

	@autoreleasepool
	{
		m_mtl->device = MTLCreateSystemDefaultDevice();
		if (!m_mtl->device)
		{
			mtl_log.fatal("MTLCreateSystemDefaultDevice() returned nil.");
			return;
		}

		mtl_log.notice("Metal device: %s", [[m_mtl->device name] UTF8String]);

		m_mtl->command_queue = [m_mtl->device newCommandQueue];

		NSView* view = static_cast<NSView*>(m_frame->handle());

		m_mtl->layer = static_cast<CAMetalLayer*>(view.layer);
		if (!m_mtl->layer || ![m_mtl->layer isKindOfClass:[CAMetalLayer class]])
		{
			m_mtl->layer    = [CAMetalLayer layer];
			view.layer      = m_mtl->layer;
			view.wantsLayer = YES;
		}

		m_mtl->layer.device          = m_mtl->device;
		m_mtl->layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
		m_mtl->layer.framebufferOnly = NO;
		m_mtl->layer.drawableSize    = view.bounds.size;

		// Initialise the shared vertex/index ring buffer.
		if (!m_attrib_ring.init((__bridge void*)m_mtl->device))
		{
			mtl_log.fatal("Failed to initialise attribute ring buffer.");
			return;
		}

		// glslang must be initialized once before compile_glsl_to_spv() can succeed.
		spirv::initialize_compiler_context();

		// Initialise caches.
		m_rtts.init((__bridge void*)m_mtl->device);
		m_ds_cache.init((__bridge void*)m_mtl->device);
		m_texture_cache.init((__bridge void*)m_mtl->device);
		m_sampler_cache.init((__bridge void*)m_mtl->device);

		// Allocate a persistent zeroed buffer for UBO stubs.
		// NOTE: must use `auto` rather than `id<MTLBuffer>` because the inherited
		// `CPUThread::id` member shadows Obj-C's `id` keyword inside method bodies.
		auto stub = [m_mtl->device newBufferWithLength:k_stub_buffer_size
		                                       options:MTLResourceStorageModeShared];
		if (stub)
		{
			[stub retain];
			memset(stub.contents, 0, k_stub_buffer_size);
			m_stub_buffer = (__bridge void*)stub;
		}

		mtl_log.success("Metal renderer initialised (device=%s)",
			[[m_mtl->device name] UTF8String]);
	}

	// Show the gs_frame window immediately. Without this, gs_frame::show() only
	// fires on the first flip — and our renderer may not produce a flip until the
	// PS3 program issues its first cellGcmSetFlip, leaving the window invisible.
	if (m_frame)
	{
		m_frame->show();
	}
}

// ---------------------------------------------------------------------------
// Render encoder lifecycle
// ---------------------------------------------------------------------------
bool MTLGSRender::ensure_render_encoder()
{
	if (m_encoder_handle)
		return true; // already open

	@autoreleasepool
	{
		if (!m_mtl->cmd_buffer)
			m_mtl->cmd_buffer = [m_mtl->command_queue commandBuffer];

		MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];

		if (m_color_count > 0)
		{
			// Render to RSX off-screen surfaces.
			for (u8 i = 0; i < m_color_count; ++i)
			{
				if (!m_current_color[i])
					continue;
				MTLTextureRef tex = (__bridge MTLTextureRef)m_current_color[i]->texture();
				pass.colorAttachments[i].texture     = tex;
				pass.colorAttachments[i].loadAction  = MTLLoadActionLoad;
				pass.colorAttachments[i].storeAction = MTLStoreActionStore;
			}

			if (m_current_depth)
			{
				MTLTextureRef dtex = (__bridge MTLTextureRef)m_current_depth->texture();
				pass.depthAttachment.texture     = dtex;
				pass.depthAttachment.loadAction  = MTLLoadActionLoad;
				pass.depthAttachment.storeAction = MTLStoreActionStore;
			}
		}
		else
		{
			// No RSX surfaces bound yet — fall back to the CAMetalLayer drawable.
			if (!m_mtl->drawable)
			{
				m_mtl->drawable = [m_mtl->layer nextDrawable];
				if (!m_mtl->drawable)
				{
					mtl_log.warning("ensure_render_encoder: nextDrawable returned nil.");
					return false;
				}
			}
			pass.colorAttachments[0].texture     = m_mtl->drawable.texture;
			pass.colorAttachments[0].loadAction  = MTLLoadActionLoad;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		}

		m_mtl->render_encoder = [m_mtl->cmd_buffer renderCommandEncoderWithDescriptor:pass];
		m_encoder_handle = (__bridge void*)m_mtl->render_encoder;
		return true;
	}
}

void MTLGSRender::end_render_encoder()
{
	if (!m_encoder_handle)
		return;

	@autoreleasepool
	{
		[m_mtl->render_encoder endEncoding];
		m_mtl->render_encoder = nil;
		m_encoder_handle      = nullptr;
	}
}

// ---------------------------------------------------------------------------
// begin / end — RSX draw sequence lifecycle
// ---------------------------------------------------------------------------
void MTLGSRender::begin()
{
	rsx::thread::begin();

	if (skip_current_frame || cond_render_ctrl.disable_rendering())
		return;

	// Allocate / reuse RSX render surfaces for this draw.
	prepare_rtts(rsx::framebuffer_creation_context::context_draw);
}

void MTLGSRender::end()
{
	if (skip_current_frame || cond_render_ctrl.disable_rendering()
		|| !m_graphics_state.test(rsx::rtt_config_valid))
	{
		execute_nop_draw();
		rsx::thread::end();
		return;
	}

	// Decompile VS/FS if the pipeline is dirty.
	if (m_graphics_state & rsx::pipeline_state::invalidate_pipeline_bits)
	{
		mtl_log.warning("MTL: end() E1 — before analyse_current_rsx_pipeline");
		analyse_current_rsx_pipeline();
		mtl_log.warning("MTL: end() E2 — before get_current_vertex_program");
		get_current_vertex_program(vs_sampler_state);
		mtl_log.warning("MTL: end() E3 — before get_current_fragment_program");
		get_current_fragment_program(fs_sampler_state);
		mtl_log.warning("MTL: end() E4 — before make_unique programs");

		m_vertex_prog   = std::make_unique<MTLVertexProgram>();
		m_fragment_prog = std::make_unique<MTLFragmentProgram>();

		mtl_log.warning("MTL: end() E5 — before VS Decompile");
		m_vertex_prog->Decompile(current_vertex_program);
		mtl_log.warning("MTL: end() E6 — before FS Decompile (vs msl_source len=%zu)",
			m_vertex_prog->compiled.msl_source.size());
		m_fragment_prog->Decompile(current_fragment_program);
		mtl_log.warning("MTL: end() E7 — both Decompiles done (fs msl_source len=%zu)",
			m_fragment_prog->compiled.msl_source.size());

		m_current_pipeline = nullptr; // invalidate cached pipeline handle
		m_graphics_state.clear(rsx::pipeline_state::invalidate_pipeline_bits);
	}

	mtl_log.warning("MTL: end() E8 — before rsx::thread::end()");
	rsx::thread::end();
	mtl_log.warning("MTL: end() E9 — after rsx::thread::end()");
}

// ---------------------------------------------------------------------------
// Pipeline cache
// ---------------------------------------------------------------------------
mtl::program* MTLGSRender::get_pipeline(MTLVertexProgram& vs, MTLFragmentProgram& fs,
                                        const mtl::pipeline_raster_config& raster)
{
	const pipeline_key key{ vs.get_compiled_hash(), fs.get_compiled_hash(), raster.hash() };

	auto it = m_pipeline_cache.find(key);
	if (it != m_pipeline_cache.end())
		return it->second.get();

	auto prog = std::make_unique<mtl::program>();
	if (!prog->build((__bridge void*)m_mtl->device, vs.compiled, fs.compiled, raster))
	{
		mtl_log.error("get_pipeline: failed to compile MTLRenderPipelineState.");
		return nullptr;
	}

	auto* raw = prog.get();
	m_pipeline_cache.emplace(key, std::move(prog));
	return raw;
}

// ---------------------------------------------------------------------------
// flip — blit RSX display surface → CAMetalLayer, present, reset for next frame
// ---------------------------------------------------------------------------
void MTLGSRender::flip(const rsx::display_flip_info_t& info)
{
	if (!m_mtl->layer)
	{
		GSRender::flip(info);
		return;
	}

	@autoreleasepool
	{
		end_render_encoder();

		if (!m_mtl->cmd_buffer)
			m_mtl->cmd_buffer = [m_mtl->command_queue commandBuffer];

		CAMetalDrawableRef drw = [m_mtl->layer nextDrawable];
		if (drw)
		{
			// Try to find the RSX surface that backs this display buffer.
			mtl::surface* src_surf = nullptr;
			if (info.buffer < display_buffers_count)
			{
				const u32 rsx_addr = rsx::get_address(display_buffers[info.buffer].offset,
				                                       CELL_GCM_LOCATION_LOCAL);
				src_surf = m_rtts.find(rsx_addr);
			}

			if (src_surf && src_surf->texture())
			{
				// Blit the RSX surface into the drawable via a blit encoder.
				MTLTextureRef src_tex = (__bridge MTLTextureRef)src_surf->texture();
				MTLBlitCommandEncoderRef blit = [m_mtl->cmd_buffer blitCommandEncoder];

				const NSUInteger blit_w = std::min<NSUInteger>(src_surf->width,  drw.texture.width);
				const NSUInteger blit_h = std::min<NSUInteger>(src_surf->height, drw.texture.height);

				[blit copyFromTexture:src_tex
				          sourceSlice:0
				          sourceLevel:0
				         sourceOrigin:MTLOriginMake(0, 0, 0)
				           sourceSize:MTLSizeMake(blit_w, blit_h, 1)
				            toTexture:drw.texture
				     destinationSlice:0
				     destinationLevel:0
				    destinationOrigin:MTLOriginMake(0, 0, 0)];
				[blit endEncoding];
			}
			else
			{
				// No RSX surface found — clear to black.
				MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture     = drw.texture;
				pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 1);
				[[m_mtl->cmd_buffer renderCommandEncoderWithDescriptor:pass] endEncoding];
			}

			[m_mtl->cmd_buffer presentDrawable:drw];
		}

		[m_mtl->cmd_buffer commit];

		// Wait for GPU to finish reading from the attrib ring before resetting it.
		// TODO(phase 8+): replace with a dispatch_semaphore for double-buffered
		// latency, or per-frame ring slices for full parallelism.
		[m_mtl->cmd_buffer waitUntilCompleted];

		// Reset per-frame state.
		m_mtl->cmd_buffer = nil;
		m_mtl->drawable   = nil;
		m_attrib_ring.reset();
	}

	GSRender::flip(info);
}

// ---------------------------------------------------------------------------
// prepare_rtts — allocate / reuse RSX render target surfaces
// ---------------------------------------------------------------------------
void MTLGSRender::prepare_rtts(rsx::framebuffer_creation_context context)
{
	get_framebuffer_layout(context, m_framebuffer_layout);
	if (!m_graphics_state.test(rsx::rtt_config_valid))
		return;

	if (m_framebuffer_layout.ignore_change)
		return;

	const u16 w = m_framebuffer_layout.width;
	const u16 h = m_framebuffer_layout.height;
	const auto color_fmt = m_framebuffer_layout.color_format;
	const auto depth_fmt = m_framebuffer_layout.depth_format;

	// Determine which color targets are active for this draw call.
	const auto draw_targets = rsx::utility::get_rtt_indexes(m_framebuffer_layout.target);
	m_color_count = 0;
	for (u8 i = 0; i < 4; ++i)
		m_current_color[i] = nullptr;

	for (u8 idx : draw_targets)
	{
		const u32 addr = m_framebuffer_layout.color_addresses[idx];
		if (!addr)
			continue;
		const u32 pitch = m_framebuffer_layout.actual_color_pitch[idx];
		m_current_color[m_color_count++] =
			m_rtts.get_color(addr, color_fmt, w, h, pitch);
	}

	// Depth surface (may be zero if depth is disabled).
	m_current_depth = nullptr;
	if (m_framebuffer_layout.zeta_address)
	{
		m_current_depth = m_rtts.get_depth(
			m_framebuffer_layout.zeta_address, depth_fmt, w, h,
			m_framebuffer_layout.actual_zeta_pitch);
	}

	m_graphics_state.clear(rsx::rtt_config_dirty);
}

// ---------------------------------------------------------------------------
// Stubs — filled in subsequent phases
// ---------------------------------------------------------------------------
void MTLGSRender::clear_surface(u32 mask)
{
	const u8 ctx_mask =
		((mask & RSX_GCM_CLEAR_COLOR_RGBA_MASK) ? u8(rsx::framebuffer_creation_context::context_clear_color) : 0u) |
		((mask & RSX_GCM_CLEAR_DEPTH_STENCIL_MASK) ? u8(rsx::framebuffer_creation_context::context_clear_depth) : 0u);
	prepare_rtts(rsx::framebuffer_creation_context{ctx_mask});
}

void MTLGSRender::do_local_task(rsx::FIFO::state state)
{
	rsx::thread::do_local_task(state);
}

u64 MTLGSRender::get_cycles() { return 0; }

#pragma GCC diagnostic pop
