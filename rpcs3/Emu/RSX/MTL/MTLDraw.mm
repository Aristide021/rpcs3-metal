#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

// See MTLGSRender.mm for why this rename is needed.
#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

// CPUThread::id (inherited) shadows Obj-C's `id` keyword inside method bodies.
// Use these typedefs in method scope instead of writing id<Protocol> directly.
typedef id<MTLBuffer>               MTLBufferRef;
typedef id<MTLTexture>              MTLTextureRef;
typedef id<MTLRenderCommandEncoder> MTLRenderCommandEncoderRef;
typedef id<MTLRenderPipelineState>  MTLRenderPipelineStateRef;
typedef id<MTLDepthStencilState>    MTLDepthStencilStateRef;
typedef id<MTLSamplerState>         MTLSamplerStateRef;

#include "stdafx.h"
#include "MTLGSRender.h"
#include "MTLBufferAllocator.h"
#include "MTLRasterState.h"
#include "../Common/BufferUtils.h"
#include "../rsx_methods.h"
#include "util/logs.hpp"
#include "Emu/RSX/Core/RSXDrawCommands.h"

LOG_CHANNEL(mtl_log, "MTL");

// ---------------------------------------------------------------------------
// Primitive type mapping
// ---------------------------------------------------------------------------
namespace
{
	// Returns {MTLPrimitiveType, needs_emulated_index_buffer}
	std::pair<MTLPrimitiveType, bool> get_primitive(rsx::primitive_type mode)
	{
		switch (mode)
		{
		case rsx::primitive_type::points:
			return { MTLPrimitiveTypePoint,         false };
		case rsx::primitive_type::lines:
			return { MTLPrimitiveTypeLine,           false };
		case rsx::primitive_type::line_loop:
		case rsx::primitive_type::line_strip:
			return { MTLPrimitiveTypeLineStrip,      false };
		case rsx::primitive_type::triangles:
			return { MTLPrimitiveTypeTriangle,       false };
		case rsx::primitive_type::triangle_strip:
		case rsx::primitive_type::quad_strip:
			return { MTLPrimitiveTypeTriangleStrip,  false };
		case rsx::primitive_type::triangle_fan:
		case rsx::primitive_type::quads:
		case rsx::primitive_type::polygon:
			// Emulate as triangle list via index buffer.
			return { MTLPrimitiveTypeTriangle,       true  };
		default:
			return { MTLPrimitiveTypeTriangle,       true  };
		}
	}

	// ---------------------------------------------------------------------------
	// Metal-flavoured vertex input state (mirrors VK's vertex_input_state)
	// ---------------------------------------------------------------------------
	struct vertex_input_state
	{
		MTLPrimitiveType  primitive;
		MTLIndexType      index_type;      // ignored when !has_index_buffer
		bool              index_rebase;
		bool              has_index_buffer;
		u32  min_index;
		u32  max_index;
		u32  vertex_draw_count;
		u32  vertex_index_offset;
		usz  index_buffer_offset;    // byte offset inside the shared ring
	};

	// ---------------------------------------------------------------------------
	// Generate an emulated (triangulated) index buffer into the ring
	// ---------------------------------------------------------------------------
	vertex_input_state generate_emulated_index(
		const rsx::draw_clause& clause,
		u32 vertex_count,
		mtl::buffer_ring& ring)
	{
		const u32 index_count = get_index_count(clause.primitive, vertex_count);
		const usz upload_size = index_count * sizeof(u16);

		const usz offset = ring.alloc(upload_size, 64);
		void* buf = ring.ptr_at(offset);

		g_fxo->get<rsx::dma_manager>().emulate_as_indexed(buf, clause.primitive, vertex_count);

		return vertex_input_state{
			MTLPrimitiveTypeTriangle,
			MTLIndexTypeUInt16,
			false, true,
			0, vertex_count - 1,
			index_count, 0,
			offset
		};
	}

	// ---------------------------------------------------------------------------
	// Draw command visitor — Metal variant of VK's draw_command_visitor
	// ---------------------------------------------------------------------------
	struct draw_command_visitor
	{
		draw_command_visitor(mtl::buffer_ring& ring, rsx::vertex_input_layout& layout)
			: m_ring(ring), m_layout(layout) {}

		vertex_input_state operator()(const rsx::draw_array_command& /*cmd*/)
		{
			const auto [prim, emulated] = get_primitive(
				rsx::method_registers.current_draw_clause.primitive);
			const u32 vertex_count = rsx::method_registers.current_draw_clause.get_elements_count();
			const u32 min_index    = rsx::method_registers.current_draw_clause.min_index();
			const u32 max_index    = min_index + vertex_count - 1;

			if (emulated)
				return generate_emulated_index(
					rsx::method_registers.current_draw_clause, vertex_count, m_ring);

			return { prim, MTLIndexTypeUInt16, false, false,
			         min_index, max_index, vertex_count, 0, 0 };
		}

		vertex_input_state operator()(const rsx::draw_indexed_array_command& cmd)
		{
			const auto [prim, emulated] = get_primitive(
				rsx::method_registers.current_draw_clause.primitive);

			rsx::index_array_type index_type =
				rsx::method_registers.current_draw_clause.is_immediate_draw
					? rsx::index_array_type::u32
					: rsx::method_registers.index_type();

			const u32 type_size   = get_index_type_size(index_type);
			u32 index_count       = rsx::method_registers.current_draw_clause.get_elements_count();
			if (emulated)
				index_count = get_index_count(
					rsx::method_registers.current_draw_clause.primitive, index_count);

			const usz upload_size = index_count * type_size;
			const usz offset      = m_ring.alloc(upload_size, 64);

			u32 min_index = 0, max_index = 0;
			std::tie(min_index, max_index, index_count) = write_index_array_data_to_buffer(
				std::span<std::byte>(static_cast<std::byte*>(m_ring.ptr_at(offset)), upload_size),
				cmd.raw_index_buffer,
				index_type,
				rsx::method_registers.current_draw_clause.primitive,
				rsx::method_registers.restart_index_enabled(),
				rsx::method_registers.restart_index(),
				[](auto p) { return get_primitive(p).second; });

			if (min_index >= max_index)
				return { prim, MTLIndexTypeUInt16, false, false, 0, 0, 0, 0, 0 };

			const MTLIndexType mtl_idx_type =
				(index_type == rsx::index_array_type::u32)
					? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;

			const u32 index_offset = rsx::method_registers.vertex_data_base_index();
			return { prim, mtl_idx_type, true, true,
			         min_index, max_index, index_count, index_offset, offset };
		}

		vertex_input_state operator()(const rsx::draw_inlined_array& /*cmd*/)
		{
			const auto& clause = rsx::method_registers.current_draw_clause;
			const auto [prim, emulated] = get_primitive(clause.primitive);
			const u32 stream_length = clause.inline_vertex_array.size();
			const u32 vertex_count  =
				u32(stream_length * sizeof(u32)) /
				m_layout.interleaved_blocks[0]->attribute_stride;

			if (!emulated)
				return { prim, MTLIndexTypeUInt16, false, false,
				         0, vertex_count - 1, vertex_count, 0, 0 };

			return generate_emulated_index(clause, vertex_count, m_ring);
		}

	private:
		mtl::buffer_ring&        m_ring;
		rsx::vertex_input_layout& m_layout;
	};
}

// ---------------------------------------------------------------------------
// MTLGSRender::emit_geometry
// ---------------------------------------------------------------------------
void MTLGSRender::emit_geometry(u32 sub_index)
{
	auto& draw_call = rsx::method_registers.current_draw_clause;

	const rsx::flags32_t vertex_state_mask = rsx::vertex_base_changed | rsx::vertex_arrays_changed;
	const rsx::flags32_t state_flags =
		(sub_index == 0)
			? rsx::vertex_arrays_changed
			: draw_call.execute_pipeline_dependencies(m_ctx);

	if (state_flags & rsx::vertex_arrays_changed)
	{
		m_draw_processor.analyse_inputs_interleaved(m_vertex_layout, current_vp_metadata);
	}
	else if (state_flags & rsx::vertex_base_changed)
	{
		for (auto& info : m_vertex_layout.interleaved_blocks)
		{
			info->vertex_range.second = 0;
			const auto base_offset = rsx::method_registers.vertex_data_base_offset();
			info->real_offset_address = rsx::get_address(
				rsx::get_vertex_offset_from_base(base_offset, info->base_offset),
				info->memory_location);
		}
	}
	else
	{
		for (auto& info : m_vertex_layout.interleaved_blocks)
			info->vertex_range.second = 0;
	}

	if ((state_flags & vertex_state_mask) && !m_vertex_layout.validate())
	{
		// No valid vertex inputs — flush remaining pipeline deps as NOPs.
		do { draw_call.execute_pipeline_dependencies(m_ctx); } while (draw_call.next());
		draw_call.end();
		return;
	}

	// --- Resolve draw command (builds index buffer if needed) ---
	draw_command_visitor visitor(m_attrib_ring, m_vertex_layout);
	auto upload = std::visit(visitor, m_draw_processor.get_draw_command(rsx::method_registers));

	if (!upload.vertex_draw_count)
		return;

	// --- Upload vertex attribute data into the UMA ring ---
	const u32 vertex_count = (upload.max_index - upload.min_index) + 1;
	const u32 vertex_base  = upload.index_rebase
		? rsx::get_index_from_base(upload.min_index,
			rsx::method_registers.vertex_data_base_index())
		: upload.min_index;

	auto [pers_bytes, vol_bytes] = calculate_memory_requirements(
		m_vertex_layout, vertex_base, vertex_count);

	const usz pers_offset = pers_bytes ? m_attrib_ring.alloc(pers_bytes, 256) : umax;
	const usz vol_offset  = vol_bytes  ? m_attrib_ring.alloc(vol_bytes,  256) : umax;

	m_draw_processor.write_vertex_data_to_memory(
		m_vertex_layout, vertex_base, vertex_count,
		pers_bytes ? m_attrib_ring.ptr_at(pers_offset) : nullptr,
		vol_bytes  ? m_attrib_ring.ptr_at(vol_offset)  : nullptr);

	mtl_log.warning("MTL: emit_geometry checkpoint A — pre encoder");

	// --- Ensure we have an open render command encoder ---
	if (!ensure_render_encoder())
	{
		mtl_log.warning("MTL: emit_geometry bailed — no encoder");
		return;
	}

	// --- Bail if we don't have compiled programs yet ---
	if (!m_vertex_prog || !m_fragment_prog)
	{
		mtl_log.warning("MTL: emit_geometry bailed — vs=%p fs=%p",
			m_vertex_prog.get(), m_fragment_prog.get());
		return;
	}

	mtl_log.warning("MTL: emit_geometry checkpoint B — encoder + progs ok, color[0]=%p depth=%p",
		m_current_color[0], m_current_depth);

	@autoreleasepool
	{
		MTLRenderCommandEncoderRef enc = (__bridge MTLRenderCommandEncoderRef)m_encoder_handle;
		MTLBufferRef attrib_buf        = (__bridge MTLBufferRef)m_attrib_ring.buffer();

		// --- Viewport ---
		{
			const u16 vp_x = rsx::method_registers.viewport_origin_x();
			const u16 vp_y = rsx::method_registers.viewport_origin_y();
			const u16 vp_w = rsx::method_registers.viewport_width();
			const u16 vp_h = rsx::method_registers.viewport_height();
			MTLViewport vp{};
			vp.originX = vp_x;
			vp.originY = vp_y;
			vp.width   = vp_w;
			vp.height  = vp_h;
			vp.znear   = 0.0;
			vp.zfar    = 1.0;
			[enc setViewport:vp];
		}

		// --- Scissor ---
		{
			const u16 sc_x = rsx::method_registers.scissor_origin_x();
			const u16 sc_y = rsx::method_registers.scissor_origin_y();
			const u16 sc_w = rsx::method_registers.scissor_width();
			const u16 sc_h = rsx::method_registers.scissor_height();
			MTLScissorRect sc{};
			sc.x      = sc_x;
			sc.y      = sc_y;
			sc.width  = sc_w  ? sc_w  : 1;
			sc.height = sc_h  ? sc_h  : 1;
			[enc setScissorRect:sc];
		}

		// --- Pipeline state (includes blend baked in) ---
		{
			mtl::pipeline_raster_config raster{};
			// Use the first bound color surface's format, fall back to BGRA8.
			raster.color_format = m_current_color[0]
				? m_current_color[0]->pixel_format
				: MTLPixelFormat(80); // MTLPixelFormatBGRA8Unorm

			raster.depth_format = m_current_depth
				? m_current_depth->pixel_format
				: MTLPixelFormat(0);

			const bool blend_en = rsx::method_registers.blend_enabled();
			raster.blend.enabled = blend_en;
			if (blend_en)
			{
				raster.blend.rgb_op    = mtl::to_mtl_blend_op(rsx::method_registers.blend_equation_rgb());
				raster.blend.alpha_op  = mtl::to_mtl_blend_op(rsx::method_registers.blend_equation_a());
				raster.blend.src_rgb   = mtl::to_mtl_blend_factor(rsx::method_registers.blend_func_sfactor_rgb());
				raster.blend.dst_rgb   = mtl::to_mtl_blend_factor(rsx::method_registers.blend_func_dfactor_rgb());
				raster.blend.src_alpha = mtl::to_mtl_blend_factor(rsx::method_registers.blend_func_sfactor_a());
				raster.blend.dst_alpha = mtl::to_mtl_blend_factor(rsx::method_registers.blend_func_dfactor_a());
			}
			// Color write mask for attachment[0].
			raster.blend.write_mask = 0;
			if (rsx::method_registers.color_mask_r(0)) raster.blend.write_mask |= 0x8; // MTLColorWriteMaskRed
			if (rsx::method_registers.color_mask_g(0)) raster.blend.write_mask |= 0x4; // Green
			if (rsx::method_registers.color_mask_b(0)) raster.blend.write_mask |= 0x2; // Blue
			if (rsx::method_registers.color_mask_a(0)) raster.blend.write_mask |= 0x1; // Alpha

			mtl_log.warning("MTL: emit_geometry checkpoint C — pre get_pipeline raster.color=%llu depth=%llu blend=%d",
				(unsigned long long)raster.color_format, (unsigned long long)raster.depth_format, (int)raster.blend.enabled);
			mtl::program* pipeline = get_pipeline(*m_vertex_prog, *m_fragment_prog, raster);
			if (!pipeline)
			{
				mtl_log.warning("MTL: emit_geometry bailed — no pipeline");
				return;
			}
			mtl_log.warning("MTL: emit_geometry checkpoint D — pipeline ok");

			[enc setRenderPipelineState:(__bridge MTLRenderPipelineStateRef)pipeline->pipeline_state()];
		}

		// --- Depth/stencil state ---
		{
			const bool depth_test    = rsx::method_registers.depth_test_enabled();
			const bool depth_write   = rsx::method_registers.depth_write_enabled();
			const auto depth_cmp     = rsx::method_registers.depth_func();
			const bool stencil_test  = rsx::method_registers.stencil_test_enabled();
			const bool two_sided     = rsx::method_registers.two_sided_stencil_test_enabled();

			void* ds_state = m_ds_cache.get(
				depth_test, depth_write, mtl::to_mtl_compare(depth_cmp),
				stencil_test,
				mtl::to_mtl_compare(rsx::method_registers.stencil_func()),
				mtl::to_mtl_stencil_op(rsx::method_registers.stencil_op_fail()),
				mtl::to_mtl_stencil_op(rsx::method_registers.stencil_op_zfail()),
				mtl::to_mtl_stencil_op(rsx::method_registers.stencil_op_zpass()),
				rsx::method_registers.stencil_mask(),
				mtl::to_mtl_compare(two_sided ? rsx::method_registers.back_stencil_func() : rsx::method_registers.stencil_func()),
				mtl::to_mtl_stencil_op(two_sided ? rsx::method_registers.back_stencil_op_fail()  : rsx::method_registers.stencil_op_fail()),
				mtl::to_mtl_stencil_op(two_sided ? rsx::method_registers.back_stencil_op_zfail() : rsx::method_registers.stencil_op_zfail()),
				mtl::to_mtl_stencil_op(two_sided ? rsx::method_registers.back_stencil_op_zpass() : rsx::method_registers.stencil_op_zpass()),
				two_sided ? rsx::method_registers.back_stencil_mask() : rsx::method_registers.stencil_mask());

			[enc setDepthStencilState:(__bridge MTLDepthStencilStateRef)ds_state];
		}

		// --- Stencil reference value ---
		if (rsx::method_registers.stencil_test_enabled())
		{
			[enc setStencilFrontReferenceValue:rsx::method_registers.stencil_func_ref()
			              backReferenceValue:rsx::method_registers.back_stencil_func_ref()];
		}

		// --- Vertex transform constants (RSX register file → VertexConstantsBuffer) ---
		// 468 vec4 entries + padding = 8192 bytes; upload every draw for now.
		usz vs_constants_offset = umax;
		{
			constexpr usz vs_constants_size = 8192;
			vs_constants_offset = m_attrib_ring.alloc(vs_constants_size, 256);
			void* dst = m_attrib_ring.ptr_at(vs_constants_offset);
			// Empty reloc table → uploads full constant block.
			m_draw_processor.fill_vertex_program_constants_data(dst, std::span<const u16>{});
		}

		// --- Stub UBO buffers + real vertex constants ---
		MTLBufferRef stub = (__bridge MTLBufferRef)m_stub_buffer;
		const auto& vbt = m_vertex_prog->binding_table;
		const auto& fbt = m_fragment_prog->binding_table;

		// Vertex stage
		if (stub && vbt.context_buf != mtl::invalid_binding)
			[enc setVertexBuffer:stub offset:0 atIndex:vbt.context_buf];

		if (vbt.constants_buf != mtl::invalid_binding && vs_constants_offset != umax)
		{
			[enc setVertexBuffer:attrib_buf offset:vs_constants_offset atIndex:vbt.constants_buf];
		}
		else if (stub && vbt.constants_buf != mtl::invalid_binding)
		{
			[enc setVertexBuffer:stub offset:0 atIndex:vbt.constants_buf];
		}

		// Fragment stage — UBOs still stub-bound (state/tex_param real data is phase 8 continued)
		if (stub)
		{
			if (fbt.context_buf    != mtl::invalid_binding) [enc setFragmentBuffer:stub offset:0 atIndex:fbt.context_buf];
			if (fbt.constants_buf  != mtl::invalid_binding) [enc setFragmentBuffer:stub offset:0 atIndex:fbt.constants_buf];
			if (fbt.tex_param_buf  != mtl::invalid_binding) [enc setFragmentBuffer:stub offset:0 atIndex:fbt.tex_param_buf];
			if (fbt.rasterizer_heap != mtl::invalid_binding) [enc setFragmentBuffer:stub offset:0 atIndex:fbt.rasterizer_heap];
		}

		// --- Fragment textures ---
		{
			const auto& fbt = m_fragment_prog->binding_table;
			const u32 referenced_mask = current_fp_metadata.referenced_textures_mask;

			for (u32 textures_ref = referenced_mask, i = 0; textures_ref; textures_ref >>= 1, ++i)
			{
				if (!(textures_ref & 1))
					continue;

				const u32 slot = fbt.ftex_location[i];
				if (slot == mtl::invalid_binding)
					continue;

				void* tex_obj  = m_texture_cache.get(rsx::method_registers.fragment_textures[i]);
				void* samp_obj = nullptr;

				if (tex_obj)
				{
					const auto& t = rsx::method_registers.fragment_textures[i];
					samp_obj = m_sampler_cache.get(
						t.wrap_s(), t.wrap_t(),
						t.min_filter(), t.mag_filter(),
						0.f,                            // lod_bias — no RSX accessor exposed
						t.min_lod(), t.max_lod(),
						static_cast<u8>(static_cast<u16>(t.max_aniso())));
				}

				[enc setFragmentTexture:(__bridge MTLTextureRef)tex_obj atIndex:slot];
				[enc setFragmentSamplerState:(__bridge MTLSamplerStateRef)samp_obj atIndex:slot];
			}
		}

		// Bind vertex attribute buffers (texel-buffer bindings from SPIRV-Cross).
		// Persistent (cached) data and volatile (immediate) data are separate views.
		// Binding indices must match what the compiled vertex shader expects; these
		// will be confirmed once we can inspect compiled MSL output.
		if (pers_bytes && pers_offset != umax)
		{
			MTLTextureDescriptor* td = [MTLTextureDescriptor new];
			td.textureType = MTLTextureTypeTextureBuffer;
			td.pixelFormat = MTLPixelFormatR8Uint;
			td.width       = static_cast<NSUInteger>(pers_bytes);
			td.usage       = MTLTextureUsageShaderRead;
			id<MTLTexture> tv = [attrib_buf newTextureWithDescriptor:td
			                                                  offset:pers_offset
			                                             bytesPerRow:0];
			[enc setVertexTexture:tv atIndex:0];
		}

		if (vol_bytes && vol_offset != umax)
		{
			MTLTextureDescriptor* td = [MTLTextureDescriptor new];
			td.textureType = MTLTextureTypeTextureBuffer;
			td.pixelFormat = MTLPixelFormatR8Uint;
			td.width       = static_cast<NSUInteger>(vol_bytes);
			td.usage       = MTLTextureUsageShaderRead;
			id<MTLTexture> tv = [attrib_buf newTextureWithDescriptor:td
			                                                  offset:vol_offset
			                                             bytesPerRow:0];
			[enc setVertexTexture:tv atIndex:1];
		}

		// --- Issue draw call ---
		if (!upload.has_index_buffer)
		{
			if (draw_call.is_single_draw())
			{
				[enc drawPrimitives:upload.primitive
				        vertexStart:0
				        vertexCount:upload.vertex_draw_count];
			}
			else
			{
				u32 vertex_offset = 0;
				for (const auto& range : draw_call.get_subranges())
				{
					[enc drawPrimitives:upload.primitive
					        vertexStart:vertex_offset
					        vertexCount:range.count];
					vertex_offset += range.count;
				}
			}
		}
		else
		{
			if (draw_call.is_single_draw())
			{
				[enc drawIndexedPrimitives:upload.primitive
				               indexCount:upload.vertex_draw_count
				                indexType:upload.index_type
				              indexBuffer:attrib_buf
				        indexBufferOffset:upload.index_buffer_offset];
			}
			else
			{
				u32 index_offset = static_cast<u32>(upload.index_buffer_offset);
				for (const auto& range : draw_call.get_subranges())
				{
					const u32 count = get_index_count(draw_call.primitive, range.count);
					[enc drawIndexedPrimitives:upload.primitive
					               indexCount:count
					                indexType:upload.index_type
					              indexBuffer:attrib_buf
					        indexBufferOffset:index_offset];
					index_offset += count * get_index_type_size(
						upload.index_type == MTLIndexTypeUInt32
							? rsx::index_array_type::u32 : rsx::index_array_type::u16);
				}
			}
		}
	}
}

#pragma GCC diagnostic pop
