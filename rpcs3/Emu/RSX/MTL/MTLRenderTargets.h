#pragma once
#include "MTLFormats.h"
#include "util/types.hpp"
#include <unordered_map>
#include <memory>

// Opaque Metal texture handle — defined in MTLRenderTargets.mm
struct MTLSurfaceState;

namespace rsx
{
	enum class surface_color_format : u8;
	enum class surface_depth_format2 : u8;
}

namespace mtl
{
	// A single render target surface — color or depth/stencil.
	struct surface
	{
		std::unique_ptr<MTLSurfaceState> state;

		u32  rsx_address  = 0;
		u16  width        = 0;
		u16  height       = 0;
		u32  rsx_pitch    = 0;
		bool is_depth     = false;

		MTLPixelFormat pixel_format = MTLPixelFormat(0); // MTLPixelFormatInvalid = 0

		// The underlying id<MTLTexture> cast to void* for C++ callers.
		void* texture() const;

		bool matches(u16 w, u16 h, MTLPixelFormat fmt) const
		{
			return width == w && height == h && pixel_format == fmt;
		}
	};

	// Lightweight cache: RSX address → MTLTexture.
	// Manages allocation and reuse of render target textures.
	class render_target_cache
	{
	public:
		// Out-of-line so the map<u64, unique_ptr<surface>> destruction sees
		// MTLSurfaceState as a complete type.
		render_target_cache();
		~render_target_cache();

		// device_handle: id<MTLDevice>* cast to void*
		void init(void* device_handle) { m_device = device_handle; }

		// Retrieve or allocate a color surface.
		surface* get_color(u32 address, rsx::surface_color_format fmt, u16 w, u16 h, u32 pitch);

		// Retrieve or allocate a depth/stencil surface.
		surface* get_depth(u32 address, rsx::surface_depth_format2 fmt, u16 w, u16 h, u32 pitch);

		// Resolve RSX local address → surface (color or depth). Returns nullptr if not found.
		surface* find(u32 address) const;

		void clear();

	private:
		void* m_device = nullptr;

		std::unordered_map<u32, std::unique_ptr<surface>> m_color;
		std::unordered_map<u32, std::unique_ptr<surface>> m_depth;

		surface* alloc(
			std::unordered_map<u32, std::unique_ptr<surface>>& map,
			u32 address, MTLPixelFormat fmt,
			u16 w, u16 h, u32 pitch, bool is_depth);
	};
}
