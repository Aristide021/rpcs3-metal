#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"

#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

#include "stdafx.h"
#include "MTLRenderTargets.h"
#include "MTLFormats.h"
#include "Emu/RSX/gcm_enums.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_rt_log, "MTL");

// ---------------------------------------------------------------------------
// MTLSurfaceState — opaque Obj-C wrapper
// ---------------------------------------------------------------------------
struct MTLSurfaceState
{
	id<MTLTexture> texture = nil;
};

// ---------------------------------------------------------------------------
// mtl::surface
// ---------------------------------------------------------------------------
void* mtl::surface::texture() const
{
	return state ? (__bridge void*)state->texture : nullptr;
}

mtl::render_target_cache::render_target_cache()  = default;
mtl::render_target_cache::~render_target_cache() = default;

// ---------------------------------------------------------------------------
// mtl::render_target_cache — internal allocation helper
// ---------------------------------------------------------------------------
mtl::surface* mtl::render_target_cache::alloc(
	std::unordered_map<u32, std::unique_ptr<surface>>& map,
	u32 address, MTLPixelFormat fmt,
	u16 w, u16 h, u32 pitch, bool is_depth)
{
	id<MTLDevice> device = (__bridge id<MTLDevice>)m_device;

	MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)fmt
	                                                                                 width:w
	                                                                                height:h
	                                                                             mipmapped:NO];
	desc.storageMode    = MTLStorageModePrivate;
	desc.usage          = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

	id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
	if (!tex)
	{
		mtl_rt_log.error("alloc: newTextureWithDescriptor returned nil (fmt=%u, %ux%u)", (u32)fmt, w, h);
		return nullptr;
	}

	auto surf        = std::make_unique<surface>();
	surf->state      = std::make_unique<MTLSurfaceState>();
	surf->state->texture = tex;
	surf->rsx_address    = address;
	surf->width          = w;
	surf->height         = h;
	surf->rsx_pitch      = pitch;
	surf->is_depth       = is_depth;
	surf->pixel_format   = fmt;

	auto* raw = surf.get();
	map[address] = std::move(surf);
	return raw;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
mtl::surface* mtl::render_target_cache::get_color(
	u32 address, rsx::surface_color_format fmt,
	u16 w, u16 h, u32 pitch)
{
	auto it = m_color.find(address);
	if (it != m_color.end())
	{
		surface* s = it->second.get();
		const MTLPixelFormat pfmt = mtl::surface_color(fmt);
		if (s->matches(w, h, pfmt))
			return s;
		// Dimensions or format changed — reallocate.
	}

	return alloc(m_color, address, mtl::surface_color(fmt), w, h, pitch, false);
}

mtl::surface* mtl::render_target_cache::get_depth(
	u32 address, rsx::surface_depth_format2 fmt,
	u16 w, u16 h, u32 pitch)
{
	auto it = m_depth.find(address);
	if (it != m_depth.end())
	{
		surface* s = it->second.get();
		const MTLPixelFormat pfmt = mtl::surface_depth(fmt);
		if (s->matches(w, h, pfmt))
			return s;
	}

	return alloc(m_depth, address, mtl::surface_depth(fmt), w, h, pitch, true);
}

mtl::surface* mtl::render_target_cache::find(u32 address) const
{
	{
		auto it = m_color.find(address);
		if (it != m_color.end())
			return it->second.get();
	}
	{
		auto it = m_depth.find(address);
		if (it != m_depth.end())
			return it->second.get();
	}
	return nullptr;
}

void mtl::render_target_cache::clear()
{
	m_color.clear();
	m_depth.clear();
}

#pragma GCC diagnostic pop
