#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

#include "stdafx.h"
#include "MTLFormats.h"

namespace mtl
{

MTLPixelFormat surface_color(rsx::surface_color_format fmt)
{
	using F = rsx::surface_color_format;
	switch (fmt)
	{
	// 16-bit packed — macOS Metal has no R5G6B5; promote to BGRA8.
	case F::r5g6b5:
	case F::x1r5g5b5_o1r5g5b5:
	case F::x1r5g5b5_z1r5g5b5:
		return MTLPixelFormatBGRA8Unorm;

	// 32-bit BGRA / RGBA families
	case F::x8r8g8b8_z8r8g8b8:
	case F::x8r8g8b8_o8r8g8b8:
	case F::a8r8g8b8:
		return MTLPixelFormatBGRA8Unorm;

	case F::x8b8g8r8_z8b8g8r8:
	case F::x8b8g8r8_o8b8g8r8:
	case F::a8b8g8r8:
		return MTLPixelFormatRGBA8Unorm;

	// Single / dual channel
	case F::b8:
		return MTLPixelFormatR8Unorm;
	case F::g8b8:
		return MTLPixelFormatRG8Unorm;

	// Float formats
	case F::w16z16y16x16:
		return MTLPixelFormatRGBA16Float;
	case F::w32z32y32x32:
		return MTLPixelFormatRGBA32Float;
	case F::x32:
		return MTLPixelFormatR32Float;

	default:
		return MTLPixelFormatBGRA8Unorm; // safe fallback
	}
}

MTLPixelFormat surface_depth(rsx::surface_depth_format2 fmt)
{
	using F = rsx::surface_depth_format2;
	switch (fmt)
	{
	case F::z16_uint:
	case F::z16_float:
		return MTLPixelFormatDepth16Unorm;

	case F::z24s8_uint:
	case F::z24s8_float:
		// Prefer packed D24S8 where available; fall back to D32F+S8.
		// At runtime MTLGSRender should check device support and use this
		// value only as a hint — the actual format may be adjusted.
		return MTLPixelFormatDepth32Float_Stencil8;

	default:
		return MTLPixelFormatDepth32Float_Stencil8;
	}
}

MTLPixelFormat texture(u32 gcm_format, bool /*is_signed*/)
{
	// GCM texture format constants (CELL_GCM_TEXTURE_*)
	// Values from cellGcmEnum.h — most common subset.
	switch (gcm_format & 0xFF)
	{
	case 0x81: return MTLPixelFormatR8Unorm;         // CELL_GCM_TEXTURE_B8
	case 0x85: return MTLPixelFormatRGBA8Unorm;      // CELL_GCM_TEXTURE_A8R8G8B8
	case 0x86: return MTLPixelFormatBGRA8Unorm;      // CELL_GCM_TEXTURE_A8B8G8R8 (swizzled)
	case 0x94: return MTLPixelFormatRGBA16Float;     // CELL_GCM_TEXTURE_W16_Z16_Y16_X16_FLOAT
	case 0x96: return MTLPixelFormatRGBA32Float;     // CELL_GCM_TEXTURE_W32_Z32_Y32_X32_FLOAT
	case 0x9E: return MTLPixelFormatR32Float;        // CELL_GCM_TEXTURE_X32_FLOAT
	case 0x82: return MTLPixelFormatRG8Unorm;        // CELL_GCM_TEXTURE_G8B8
	case 0x8B: return MTLPixelFormatRG16Unorm;       // CELL_GCM_TEXTURE_Y16_X16
	case 0x8F: return MTLPixelFormatR16Unorm;        // CELL_GCM_TEXTURE_X16
	case 0x90: return MTLPixelFormatRGBA8Unorm_sRGB; // CELL_GCM_TEXTURE_A8R8G8B8 sRGB

	// Compressed formats
	case 0x86 + 0x20: return MTLPixelFormatBC1_RGBA;  // DXT1
	case 0x87 + 0x20: return MTLPixelFormatBC2_RGBA;  // DXT3
	case 0x88 + 0x20: return MTLPixelFormatBC3_RGBA;  // DXT5

	default:
		return MTLPixelFormatRGBA8Unorm;
	}
}

bool needs_bgr_swizzle(rsx::surface_color_format fmt)
{
	using F = rsx::surface_color_format;
	switch (fmt)
	{
	// RSX stores these as BGRA in memory; Metal reads them as RGBA.
	case F::x8b8g8r8_z8b8g8r8:
	case F::x8b8g8r8_o8b8g8r8:
	case F::a8b8g8r8:
		return true;
	default:
		return false;
	}
}

} // namespace mtl
