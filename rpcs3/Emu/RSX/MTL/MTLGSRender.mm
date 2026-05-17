#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

#include "stdafx.h"
#include "MTLGSRender.h"
#include "Emu/RSX/RSXThread.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_log, "MTL");

// ---------------------------------------------------------------------------
// MTLState — all Obj-C objects, invisible to C++ translation units.
// Also owns the per-frame command buffer and drawable.
// ---------------------------------------------------------------------------
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

		mtl_log.success("Metal renderer initialised (device=%s)",
			[[m_mtl->device name] UTF8String]);
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
		// Acquire a drawable for this frame if we don't have one.
		if (!m_mtl->drawable)
		{
			m_mtl->drawable = [m_mtl->layer nextDrawable];
			if (!m_mtl->drawable)
			{
				mtl_log.warning("ensure_render_encoder: nextDrawable returned nil.");
				return false;
			}
		}

		if (!m_mtl->cmd_buffer)
			m_mtl->cmd_buffer = [m_mtl->command_queue commandBuffer];

		MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture     = m_mtl->drawable.texture;
		pass.colorAttachments[0].loadAction  = MTLLoadActionLoad;   // preserve previous contents
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;

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
// Pipeline cache
// ---------------------------------------------------------------------------
mtl::program* MTLGSRender::get_pipeline(MTLVertexProgram& vs, MTLFragmentProgram& fs)
{
	const pipeline_key key{ vs.get_compiled_hash(), fs.get_compiled_hash() };

	auto it = m_pipeline_cache.find(key);
	if (it != m_pipeline_cache.end())
		return it->second.get();

	auto prog = std::make_unique<mtl::program>();
	if (!prog->build((__bridge void*)m_mtl->device, vs.compiled, fs.compiled))
	{
		mtl_log.error("get_pipeline: failed to compile MTLRenderPipelineState.");
		return nullptr;
	}

	auto* raw = prog.get();
	m_pipeline_cache.emplace(key, std::move(prog));
	return raw;
}

// ---------------------------------------------------------------------------
// flip — end current encoder, present, reset ring, begin next frame
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

		if (m_mtl->cmd_buffer && m_mtl->drawable)
		{
			[m_mtl->cmd_buffer presentDrawable:m_mtl->drawable];
			[m_mtl->cmd_buffer commit];
		}
		else if (!m_mtl->drawable)
		{
			// Nothing was drawn this frame — issue a blank clear.
			id<MTLCommandBuffer> cmd = [m_mtl->command_queue commandBuffer];
			id<CAMetalDrawable>  drw = [m_mtl->layer nextDrawable];
			if (drw)
			{
				MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture     = drw.texture;
				pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 1);

				[[cmd renderCommandEncoderWithDescriptor:pass] endEncoding];
				[cmd presentDrawable:drw];
				[cmd commit];
			}
		}

		// Reset per-frame state.
		m_mtl->cmd_buffer = nil;
		m_mtl->drawable   = nil;
		m_attrib_ring.reset();
	}

	GSRender::flip(info);
}

// ---------------------------------------------------------------------------
// Stubs — filled in subsequent phases
// ---------------------------------------------------------------------------
void MTLGSRender::clear_surface(u32 /*mask*/) {}

void MTLGSRender::do_local_task(rsx::FIFO::state state)
{
	rsx::thread::do_local_task(state);
}

u64 MTLGSRender::get_cycles() { return 0; }

#pragma GCC diagnostic pop
