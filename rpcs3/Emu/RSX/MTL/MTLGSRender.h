#pragma once

#include "Emu/RSX/GSRender.h"
#include "MTLBufferAllocator.h"
#include "MTLProgramPipeline.h"
#include "MTLRasterState.h"
#include "MTLRenderTargets.h"
#include "MTLTextureCache.h"
#include "MTLVertexProgram.h"
#include "MTLFragmentProgram.h"
#include <memory>
#include <unordered_map>

// Opaque handle to Obj-C Metal objects (MTLDevice, CAMetalLayer, etc.)
// Defined only in MTLGSRender.mm.
struct MTLState;

class MTLGSRender : public GSRender
{
public:
	MTLGSRender(utils::serial* ar);
	~MTLGSRender() override;

	void on_init_thread() override;
	void on_exit() override;
	void begin() override;
	void end() override;
	void flip(const rsx::display_flip_info_t& info) override;
	void clear_surface(u32 mask) override;
	void do_local_task(rsx::FIFO::state state) override;
	void emit_geometry(u32 sub_index) override;
	u64  get_cycles() final;

	// Called by begin() / clear_surface to (re)allocate RSX render surfaces.
	void prepare_rtts(rsx::framebuffer_creation_context context);

private:
	// ------------------------------------------------------------------
	// Metal Obj-C objects (device, layer, etc.)
	// ------------------------------------------------------------------
	std::unique_ptr<MTLState> m_mtl;

	// ------------------------------------------------------------------
	// Frame-level encoder state
	// ------------------------------------------------------------------

	// Current render command encoder cast to void* for C++ visibility.
	void* m_encoder_handle = nullptr;

	// Active RSX render targets (set by prepare_rtts).
	mtl::surface* m_current_color[4] = {};
	mtl::surface* m_current_depth    = nullptr;
	u8            m_color_count       = 0;

	// Ensure a render encoder targeting the current RSX surfaces is open.
	// Falls back to the CAMetalLayer drawable if no RSX surface is bound.
	bool ensure_render_encoder();

	// End the current render encoder (if open).
	void end_render_encoder();

	// ------------------------------------------------------------------
	// ------------------------------------------------------------------
	// Render target cache + depth/stencil state cache
	// ------------------------------------------------------------------
	mtl::render_target_cache   m_rtts;
	mtl::depth_stencil_cache   m_ds_cache;

	// ------------------------------------------------------------------
	// Texture and sampler caches
	// ------------------------------------------------------------------
	mtl::texture_cache         m_texture_cache;
	mtl::sampler_cache         m_sampler_cache;

	// Persistent zeroed buffer used as stub for UBO slots we don't yet fill.
	// Prevents GPU faults when the shader reads from a null buffer pointer.
	void* m_stub_buffer        = nullptr; // id<MTLBuffer>*
	static constexpr usz k_stub_buffer_size = 32 * 1024; // 32 KB

	// ------------------------------------------------------------------
	// Vertex / index shared ring buffer (UMA, no staging)
	// ------------------------------------------------------------------
	mtl::buffer_ring m_attrib_ring;

	// Vertex layout for the current draw batch (mirrors VKGSRender::m_vertex_layout)
	rsx::vertex_input_layout m_vertex_layout;

	// ------------------------------------------------------------------
	// Shader / pipeline cache
	// ------------------------------------------------------------------
	struct pipeline_key
	{
		u64 vs_hash;
		u64 fs_hash;
		u64 raster_hash;
		bool operator==(const pipeline_key& o) const
		{
			return vs_hash == o.vs_hash && fs_hash == o.fs_hash && raster_hash == o.raster_hash;
		}
	};
	struct pipeline_key_hash
	{
		std::size_t operator()(const pipeline_key& k) const noexcept
		{
			return k.vs_hash ^ (k.fs_hash * 0x9e3779b97f4a7c15ULL) ^ (k.raster_hash * 0x517cc1b727220a95ULL);
		}
	};

	std::unordered_map<pipeline_key, std::unique_ptr<mtl::program>, pipeline_key_hash>
		m_pipeline_cache;

	// Per-draw decompiled programs (re-used until RSX marks them dirty).
	std::unique_ptr<MTLVertexProgram>   m_vertex_prog;
	std::unique_ptr<MTLFragmentProgram> m_fragment_prog;
	mtl::program*                       m_current_pipeline = nullptr;

	// Compile or retrieve the pipeline for the current VS/FS and raster state.
	mtl::program* get_pipeline(MTLVertexProgram& vs, MTLFragmentProgram& fs,
	                           const mtl::pipeline_raster_config& raster);
};
