#pragma once

#include "Emu/RSX/GSRender.h"
#include "MTLBufferAllocator.h"
#include "MTLProgramPipeline.h"
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
	void flip(const rsx::display_flip_info_t& info) override;
	void clear_surface(u32 mask) override;
	void do_local_task(rsx::FIFO::state state) override;
	void emit_geometry(u32 sub_index) override;
	u64  get_cycles() final;

private:
	// ------------------------------------------------------------------
	// Metal Obj-C objects (device, layer, etc.)
	// ------------------------------------------------------------------
	std::unique_ptr<MTLState> m_mtl;

	// ------------------------------------------------------------------
	// Frame-level encoder state
	// ------------------------------------------------------------------

	// Current render command encoder cast to void* for C++ visibility.
	// The real id<MTLRenderCommandEncoder> lives in MTLDraw.mm scope.
	void* m_encoder_handle = nullptr;

	// Ensure a render encoder targeting the current drawable is open.
	// Returns false if the drawable or device is not ready.
	bool ensure_render_encoder();

	// End the current render encoder (if open).
	void end_render_encoder();

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
		bool operator==(const pipeline_key& o) const
		{
			return vs_hash == o.vs_hash && fs_hash == o.fs_hash;
		}
	};
	struct pipeline_key_hash
	{
		std::size_t operator()(const pipeline_key& k) const noexcept
		{
			return k.vs_hash ^ (k.fs_hash * 0x9e3779b97f4a7c15ULL);
		}
	};

	std::unordered_map<pipeline_key, std::unique_ptr<mtl::program>, pipeline_key_hash>
		m_pipeline_cache;

	MTLVertexProgram*   m_vertex_prog   = nullptr;
	MTLFragmentProgram* m_fragment_prog = nullptr;
	mtl::program*       m_current_pipeline = nullptr;

	// Compile or retrieve the pipeline state for the current VS/FS pair.
	mtl::program* get_pipeline(MTLVertexProgram& vs, MTLFragmentProgram& fs);
};
