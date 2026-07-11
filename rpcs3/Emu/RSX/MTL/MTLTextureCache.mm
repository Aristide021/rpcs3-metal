#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

// See MTLGSRender.mm for why this rename is needed.
#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

#include "stdafx.h"
#include "MTLTextureCache.h"
#include "MTLFormats.h"
#include "Emu/Memory/vm.h"
#include "Emu/RSX/RSXTexture.h"
#include "Emu/RSX/RSXThread.h"
#include "Emu/RSX/rsx_utils.h"
#include "Emu/RSX/gcm_enums.h"
#include "Emu/RSX/Common/TextureUtils.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_tex_log, "MTL");

// ---------------------------------------------------------------------------
// Opaque Obj-C wrappers
// ---------------------------------------------------------------------------
struct MTLCachedTexture
{
	id<MTLTexture> texture = nil;
};

struct MTLCachedSampler
{
	id<MTLSamplerState> state = nil;
};

// ---------------------------------------------------------------------------
// cached_texture_entry::texture()
// ---------------------------------------------------------------------------
void* mtl::cached_texture_entry::texture() const
{
	return handle ? (__bridge void*)handle->texture : nullptr;
}

// Out-of-line cache class ctors/dtors so the map's incomplete types can be
// destroyed safely.
mtl::texture_cache::texture_cache()  = default;
mtl::texture_cache::~texture_cache() = default;
mtl::sampler_cache::sampler_cache()  = default;
mtl::sampler_cache::~sampler_cache() = default;

// ---------------------------------------------------------------------------
// Sampler wrap/filter → Metal
// ---------------------------------------------------------------------------
static MTLSamplerAddressMode to_mtl_wrap(rsx::texture_wrap_mode m)
{
	switch (m)
	{
	case rsx::texture_wrap_mode::wrap:                     return MTLSamplerAddressModeRepeat;
	case rsx::texture_wrap_mode::mirror:                   return MTLSamplerAddressModeMirrorRepeat;
	case rsx::texture_wrap_mode::clamp_to_edge:            return MTLSamplerAddressModeClampToEdge;
	case rsx::texture_wrap_mode::border:                   return MTLSamplerAddressModeClampToBorderColor;
	case rsx::texture_wrap_mode::clamp:                    return MTLSamplerAddressModeClampToEdge;
	case rsx::texture_wrap_mode::mirror_once_clamp_to_edge:return MTLSamplerAddressModeMirrorClampToEdge;
	case rsx::texture_wrap_mode::mirror_once_border:       return MTLSamplerAddressModeMirrorClampToEdge;
	case rsx::texture_wrap_mode::mirror_once_clamp:        return MTLSamplerAddressModeMirrorClampToEdge;
	default:                                               return MTLSamplerAddressModeClampToEdge;
	}
}

static MTLSamplerMipFilter to_mtl_mip_filter(rsx::texture_minify_filter f)
{
	switch (f)
	{
	case rsx::texture_minify_filter::nearest:
	case rsx::texture_minify_filter::linear:          return MTLSamplerMipFilterNotMipmapped;
	case rsx::texture_minify_filter::nearest_nearest:
	case rsx::texture_minify_filter::linear_nearest:  return MTLSamplerMipFilterNearest;
	case rsx::texture_minify_filter::nearest_linear:
	case rsx::texture_minify_filter::linear_linear:
	case rsx::texture_minify_filter::convolution_min: return MTLSamplerMipFilterLinear;
	default:                                          return MTLSamplerMipFilterLinear;
	}
}

static MTLSamplerMinMagFilter to_mtl_min_filter(rsx::texture_minify_filter f)
{
	switch (f)
	{
	case rsx::texture_minify_filter::nearest:
	case rsx::texture_minify_filter::nearest_nearest:
	case rsx::texture_minify_filter::nearest_linear:  return MTLSamplerMinMagFilterNearest;
	default:                                          return MTLSamplerMinMagFilterLinear;
	}
}

static MTLSamplerMinMagFilter to_mtl_mag_filter(rsx::texture_magnify_filter f)
{
	switch (f)
	{
	case rsx::texture_magnify_filter::nearest: return MTLSamplerMinMagFilterNearest;
	default:                                   return MTLSamplerMinMagFilterLinear;
	}
}

// ---------------------------------------------------------------------------
// mtl::sampler_cache
// ---------------------------------------------------------------------------
u64 mtl::sampler_cache::make_key(
	rsx::texture_wrap_mode wrap_s, rsx::texture_wrap_mode wrap_t,
	rsx::texture_minify_filter min_filter, rsx::texture_magnify_filter mag_filter,
	float lod_bias, float min_lod, float max_lod, u8 max_aniso) const noexcept
{
	u64 k = (static_cast<u64>(wrap_s)     & 0xF) << 0
	      | (static_cast<u64>(wrap_t)     & 0xF) << 4
	      | (static_cast<u64>(min_filter) & 0xF) << 8
	      | (static_cast<u64>(mag_filter) & 0xF) << 12
	      | (static_cast<u64>(max_aniso)  & 0xF) << 16;
	// Pack LOD values as fixed-point halves.
	k ^= (static_cast<u64>(static_cast<u16>(lod_bias  * 256.f))) << 20;
	k ^= (static_cast<u64>(static_cast<u16>(min_lod   * 256.f))) << 36;
	k ^= (static_cast<u64>(static_cast<u16>(max_lod   * 256.f))) << 52;
	return k;
}

void* mtl::sampler_cache::get(
	rsx::texture_wrap_mode wrap_s, rsx::texture_wrap_mode wrap_t,
	rsx::texture_minify_filter min_filter, rsx::texture_magnify_filter mag_filter,
	float lod_bias, float min_lod, float max_lod, u8 max_aniso)
{
	const u64 key = make_key(wrap_s, wrap_t, min_filter, mag_filter, lod_bias, min_lod, max_lod, max_aniso);
	auto it = m_cache.find(key);
	if (it != m_cache.end())
		return (__bridge void*)it->second->state;

	id<MTLDevice> device = (__bridge id<MTLDevice>)m_device;
	MTLSamplerDescriptor* desc = [MTLSamplerDescriptor new];

	desc.sAddressMode     = to_mtl_wrap(wrap_s);
	desc.tAddressMode     = to_mtl_wrap(wrap_t);
	desc.rAddressMode     = MTLSamplerAddressModeClampToEdge;
	desc.minFilter        = to_mtl_min_filter(min_filter);
	desc.magFilter        = to_mtl_mag_filter(mag_filter);
	desc.mipFilter        = to_mtl_mip_filter(min_filter);
	desc.lodMinClamp      = min_lod;
	desc.lodMaxClamp      = max_lod < 0.f ? 1000.f : max_lod;
	// max_aniso is GCM enum value 0-7 mapping to 1,2,4,6,8,10,12,16.
	static constexpr NSUInteger aniso_table[8] = { 1, 2, 4, 6, 8, 10, 12, 16 };
	desc.maxAnisotropy    = aniso_table[max_aniso < 8 ? max_aniso : 0];
	desc.normalizedCoordinates = YES;

	auto entry   = std::make_unique<MTLCachedSampler>();
	entry->state = [device newSamplerStateWithDescriptor:desc];

	void* raw = (__bridge void*)entry->state;
	m_cache.emplace(key, std::move(entry));
	return raw;
}

void mtl::sampler_cache::clear() { m_cache.clear(); }

// ---------------------------------------------------------------------------
// mtl::texture_cache — upload helpers
// ---------------------------------------------------------------------------
void* mtl::texture_cache::upload(
	u32 rsx_address, u16 w, u16 h, u8 gcm_format,
	u16 mipmap, bool is_cubemap, bool is_swizzled,
	u8 location)
{
	const MTLPixelFormat fmt = (MTLPixelFormat)mtl::texture(gcm_format);
	if (fmt == 0)
	{
		mtl_tex_log.warning("texture_cache: unsupported GCM format 0x%02X at 0x%08X", gcm_format, rsx_address);
		return nullptr;
	}

	id<MTLDevice> device = (__bridge id<MTLDevice>)m_device;

	MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
	                                                                                width:w
	                                                                               height:h
	                                                                            mipmapped:mipmap > 1 ? YES : NO];
	desc.mipmapLevelCount = mipmap;
	desc.storageMode      = MTLStorageModeShared; // UMA: CPU can write directly

	if (is_cubemap)
	{
		desc.textureType = MTLTextureTypeCube;
		desc.arrayLength = 1;
	}

	id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
	if (!tex)
	{
		mtl_tex_log.error("texture_cache: newTextureWithDescriptor failed.");
		return nullptr;
	}

	// Get a pointer to RSX local/main memory.
	const u8* src_ptr = vm::_ptr<u8>(rsx_address);
	if (!src_ptr)
	{
		mtl_tex_log.warning("texture_cache: null RSX ptr at 0x%08X", rsx_address);
		return nullptr;
	}

	// Upload each mipmap level using raw RSX memory + format-derived pitch.
	// For swizzled textures we'd need deswizzle; Phase 6 uploads them as-is
	// (may produce incorrect output but won't crash). Deswizzle is Phase 7.
	const bool is_dxt = (gcm_format >= CELL_GCM_TEXTURE_COMPRESSED_DXT1 &&
	                     gcm_format <= CELL_GCM_TEXTURE_COMPRESSED_DXT45);
	const u32  bpp    = is_dxt ? 0 : rsx::get_format_block_size_in_bytes(gcm_format);

	u32 mip_w = w, mip_h = h;
	u32 src_offset = 0;

	for (u16 mip = 0; mip < mipmap && mip_w && mip_h; ++mip)
	{
		NSUInteger bytes_per_row;
		u32 mip_bytes;

		if (is_dxt)
		{
			const u32 block_size = (gcm_format == CELL_GCM_TEXTURE_COMPRESSED_DXT1) ? 8 : 16;
			const u32 blocks_w   = (mip_w + 3) / 4;
			const u32 blocks_h   = (mip_h + 3) / 4;
			bytes_per_row = blocks_w * block_size;
			mip_bytes     = static_cast<u32>(bytes_per_row) * blocks_h;
		}
		else
		{
			bytes_per_row = mip_w * bpp;
			mip_bytes     = mip_h * static_cast<u32>(bytes_per_row);
		}

		[tex replaceRegion:MTLRegionMake2D(0, 0, mip_w, mip_h)
		       mipmapLevel:mip
		         withBytes:src_ptr + src_offset
		       bytesPerRow:bytes_per_row];

		src_offset += mip_bytes;
		mip_w = std::max<u32>(mip_w / 2, 1);
		mip_h = std::max<u32>(mip_h / 2, 1);
	}

	auto& entry           = m_cache[rsx_address];
	entry.handle          = std::make_unique<MTLCachedTexture>();
	entry.handle->texture = tex;
	entry.rsx_address     = rsx_address;
	entry.width           = w;
	entry.height          = h;
	entry.gcm_format      = gcm_format;
	entry.mipmap_count    = mipmap;

	return (__bridge void*)tex;
}

void* mtl::texture_cache::get(const rsx::fragment_texture& tex)
{
	if (!tex.enabled() || !tex.width() || !tex.height())
		return nullptr;

	const u32 address = rsx::get_address(tex.offset(), tex.location());
	if (!address)
		return nullptr;

	auto it = m_cache.find(address);
	if (it != m_cache.end())
	{
		// Reuse if dimensions/format match.
		auto& e = it->second;
		if (e.width == tex.width() && e.height == tex.height()
			&& e.gcm_format == (tex.format() & ~CELL_GCM_TEXTURE_LN)
			&& e.mipmap_count == tex.mipmap())
		{
			return e.texture();
		}
		m_cache.erase(it);
	}

	const bool is_swizzled = !(tex.format() & CELL_GCM_TEXTURE_LN);
	const u8   gcm_fmt     = tex.format() & ~CELL_GCM_TEXTURE_LN;

	return upload(address, tex.width(), tex.height(), gcm_fmt,
	              tex.mipmap(), tex.cubemap(), is_swizzled, tex.location());
}

void* mtl::texture_cache::get(const rsx::vertex_texture& tex)
{
	if (!tex.enabled() || !tex.width() || !tex.height())
		return nullptr;

	const u32 address = rsx::get_address(tex.offset(), tex.location());
	if (!address)
		return nullptr;

	auto it = m_cache.find(address);
	if (it != m_cache.end())
	{
		auto& e = it->second;
		if (e.width == tex.width() && e.height == tex.height()
			&& e.gcm_format == (tex.format() & ~CELL_GCM_TEXTURE_LN)
			&& e.mipmap_count == tex.mipmap())
		{
			return e.texture();
		}
		m_cache.erase(it);
	}

	const bool is_swizzled = !(tex.format() & CELL_GCM_TEXTURE_LN);
	const u8   gcm_fmt     = tex.format() & ~CELL_GCM_TEXTURE_LN;

	return upload(address, tex.width(), tex.height(), gcm_fmt,
	              tex.mipmap(), false, is_swizzled, tex.location());
}

void mtl::texture_cache::clear() { m_cache.clear(); }

#pragma GCC diagnostic pop
