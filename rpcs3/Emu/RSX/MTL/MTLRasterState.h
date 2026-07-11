#pragma once
#include "MTLFormats.h"   // MTLPixelFormat alias
#include "util/types.hpp"
#include <memory>
#include <unordered_map>

namespace rsx
{
	enum class comparison_function : u16;
	enum class stencil_op          : u16;
	enum class blend_equation      : u16;
	enum class blend_factor        : u16;
}

// Opaque handle for id<MTLDepthStencilState>.
struct MTLDepthStencilHandle;

namespace mtl
{
	// ------------------------------------------------------------------
	// RSX → Metal enum conversions (implemented in MTLRasterState.mm)
	// ------------------------------------------------------------------
	unsigned int to_mtl_compare(rsx::comparison_function f);   // MTLCompareFunction
	unsigned int to_mtl_stencil_op(rsx::stencil_op op);       // MTLStencilOperation
	unsigned int to_mtl_blend_op(rsx::blend_equation eq);     // MTLBlendOperation
	unsigned int to_mtl_blend_factor(rsx::blend_factor f);    // MTLBlendFactor

	// ------------------------------------------------------------------
	// Blend configuration baked into MTLRenderPipelineState.
	// One entry per color attachment; Metal supports up to 8 but RSX
	// uses at most 4.
	// ------------------------------------------------------------------
	struct attachment_blend
	{
		bool         enabled       = false;
		unsigned int rgb_op        = 0; // MTLBlendOperationAdd
		unsigned int alpha_op      = 0;
		unsigned int src_rgb       = 1; // MTLBlendFactorOne
		unsigned int dst_rgb       = 0; // MTLBlendFactorZero
		unsigned int src_alpha     = 1;
		unsigned int dst_alpha     = 0;
		unsigned int write_mask    = 0xF; // MTLColorWriteMaskAll

		bool operator==(const attachment_blend& o) const = default;
	};

	// Per-draw pipeline raster config (includes everything that Metal bakes
	// into MTLRenderPipelineState beyond the shader functions).
	struct pipeline_raster_config
	{
		MTLPixelFormat   color_format = MTLPixelFormat(0);  // format of attachment[0]
		MTLPixelFormat   depth_format = MTLPixelFormat(0);  // 0 = no depth attachment
		attachment_blend blend;             // attachment[0] blend state

		u64 hash() const noexcept;
	};

	// ------------------------------------------------------------------
	// Depth/stencil state cache — keyed by a packed u64 of DS registers.
	// ------------------------------------------------------------------
	class depth_stencil_cache
	{
	public:
		// Out-of-line so the map<u64, unique_ptr<MTLDepthStencilHandle>>
		// destruction sees the complete type.
		depth_stencil_cache();
		~depth_stencil_cache();

		void init(void* device_handle) { m_device = device_handle; }

		// Returns an id<MTLDepthStencilState>* cast to void*.
		void* get(
			bool depth_test, bool depth_write, unsigned int depth_compare,
			bool stencil_test,
			unsigned int front_compare, unsigned int front_fail, unsigned int front_zfail, unsigned int front_zpass, u8 front_write_mask,
			unsigned int back_compare,  unsigned int back_fail,  unsigned int back_zfail,  unsigned int back_zpass,  u8 back_write_mask);

		void clear();

	private:
		void*  m_device = nullptr;
		std::unordered_map<u64, std::unique_ptr<MTLDepthStencilHandle>> m_cache;

		u64 make_key(
			bool depth_test, bool depth_write, unsigned int depth_compare,
			bool stencil_test,
			unsigned int front_compare, unsigned int front_fail, unsigned int front_zfail, unsigned int front_zpass, u8 front_write_mask,
			unsigned int back_compare,  unsigned int back_fail,  unsigned int back_zfail,  unsigned int back_zpass,  u8 back_write_mask) const noexcept;
	};
}
