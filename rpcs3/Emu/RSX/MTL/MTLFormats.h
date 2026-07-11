#pragma once

// In Objective-C++ TUs (.mm), pull in the real MTLPixelFormat from Metal.framework.
// In plain C++ TUs alias it to an NSUInteger-compatible integer so the function
// signatures still compile.
#ifdef __OBJC__
#  import <Metal/MTLPixelFormat.h>
#else
#  include <cstdint>
using MTLPixelFormat = std::uint64_t;
#endif

#include "Emu/RSX/gcm_enums.h"

namespace mtl
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
