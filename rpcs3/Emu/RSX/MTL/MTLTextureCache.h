#pragma once
#include "MTLFormats.h"
#include "util/types.hpp"
#include <memory>
#include <unordered_map>

namespace rsx
{
	class fragment_texture;
	class vertex_texture;
	enum class texture_wrap_mode   : u8;
	enum class texture_minify_filter  : u8;
	enum class texture_magnify_filter : u8;
}

// Opaque Obj-C wrappers — defined in MTLTextureCache.mm
struct MTLCachedTexture;
struct MTLCachedSampler;

namespace mtl
{
	// ---------------------------------------------------------------------------
	// Texture cache: RSX address → id<MTLTexture>
	// ---------------------------------------------------------------------------
	struct cached_texture_entry
	{
		std::unique_ptr<MTLCachedTexture> handle;
		u32  rsx_address  = 0;
		u16  width        = 0;
		u16  height       = 0;
		u8   gcm_format   = 0;
		u16  mipmap_count = 0;

		// id<MTLTexture> cast to void*
		void* texture() const;
	};

	class texture_cache
	{
	public:
		// Out-of-line so the unordered_map<u32, cached_texture_entry> destruction
		// sees MTLCachedTexture as a complete type.
		texture_cache();
		~texture_cache();

		void init(void* device_handle) { m_device = device_handle; }

		// Upload (or reuse) the RSX fragment texture, returning its id<MTLTexture>*.
		void* get(const rsx::fragment_texture& tex);
		void* get(const rsx::vertex_texture& tex);

		void clear();

	private:
		void* m_device = nullptr;
		std::unordered_map<u32, cached_texture_entry> m_cache;

		void* upload(u32 rsx_address, u16 w, u16 h, u8 gcm_format,
		             u16 mipmap, bool is_cubemap, bool is_swizzled,
		             u8 location);
	};

	// ---------------------------------------------------------------------------
	// Sampler state cache: packed key → id<MTLSamplerState>
	// ---------------------------------------------------------------------------
	class sampler_cache
	{
	public:
		// Out-of-line so the map<u64, unique_ptr<MTLCachedSampler>> destruction
		// sees the complete type.
		sampler_cache();
		~sampler_cache();

		void init(void* device_handle) { m_device = device_handle; }

		// Returns id<MTLSamplerState>* cast to void*.
		void* get(rsx::texture_wrap_mode wrap_s, rsx::texture_wrap_mode wrap_t,
		          rsx::texture_minify_filter min_filter,
		          rsx::texture_magnify_filter mag_filter,
		          float lod_bias, float min_lod, float max_lod,
		          u8 max_aniso);

		void clear();

	private:
		void* m_device = nullptr;
		std::unordered_map<u64, std::unique_ptr<MTLCachedSampler>> m_cache;

		u64 make_key(rsx::texture_wrap_mode wrap_s, rsx::texture_wrap_mode wrap_t,
		             rsx::texture_minify_filter min_filter,
		             rsx::texture_magnify_filter mag_filter,
		             float lod_bias, float min_lod, float max_lod,
		             u8 max_aniso) const noexcept;
	};
}
