#pragma once

// Forward-declare MTLPixelFormat as an NSUInteger alias so this header
// stays includable from plain C++ without pulling in Metal.framework.
#include <cstdint>
using MTLPixelFormat = std::uint64_t;

#include "Emu/RSX/gcm_enums.h"

namespace mtl::formats
{
	// Color surface → MTLPixelFormat
	MTLPixelFormat surface_color(rsx::surface_color_format fmt);

	// Depth/stencil surface → MTLPixelFormat
	MTLPixelFormat surface_depth(rsx::surface_depth_format2 fmt);

	// RSX texture format → MTLPixelFormat (common subset)
	MTLPixelFormat texture(u32 gcm_format, bool is_signed = false);

	// True when the RSX format requires a BGRA↔RGBA component swizzle.
	bool needs_bgr_swizzle(rsx::surface_color_format fmt);
}
