#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"

#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

#include "stdafx.h"
#include "MTLRasterState.h"
#include "Emu/RSX/gcm_enums.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_rs_log, "MTL");

// ---------------------------------------------------------------------------
// Enum conversions
// ---------------------------------------------------------------------------
unsigned int mtl::to_mtl_compare(rsx::comparison_function f)
{
	switch (f)
	{
	case rsx::comparison_function::never:            return MTLCompareFunctionNever;
	case rsx::comparison_function::less:             return MTLCompareFunctionLess;
	case rsx::comparison_function::equal:            return MTLCompareFunctionEqual;
	case rsx::comparison_function::less_or_equal:    return MTLCompareFunctionLessEqual;
	case rsx::comparison_function::greater:          return MTLCompareFunctionGreater;
	case rsx::comparison_function::not_equal:        return MTLCompareFunctionNotEqual;
	case rsx::comparison_function::greater_or_equal: return MTLCompareFunctionGreaterEqual;
	case rsx::comparison_function::always:           return MTLCompareFunctionAlways;
	default:                                         return MTLCompareFunctionAlways;
	}
}

unsigned int mtl::to_mtl_stencil_op(rsx::stencil_op op)
{
	switch (op)
	{
	case rsx::stencil_op::keep:      return MTLStencilOperationKeep;
	case rsx::stencil_op::zero:      return MTLStencilOperationZero;
	case rsx::stencil_op::replace:   return MTLStencilOperationReplace;
	case rsx::stencil_op::incr:      return MTLStencilOperationIncrementClamp;
	case rsx::stencil_op::decr:      return MTLStencilOperationDecrementClamp;
	case rsx::stencil_op::invert:    return MTLStencilOperationInvert;
	case rsx::stencil_op::incr_wrap: return MTLStencilOperationIncrementWrap;
	case rsx::stencil_op::decr_wrap: return MTLStencilOperationDecrementWrap;
	default:                         return MTLStencilOperationKeep;
	}
}

unsigned int mtl::to_mtl_blend_op(rsx::blend_equation eq)
{
	switch (eq)
	{
	case rsx::blend_equation::add:              return MTLBlendOperationAdd;
	case rsx::blend_equation::subtract:         return MTLBlendOperationSubtract;
	case rsx::blend_equation::reverse_subtract: return MTLBlendOperationReverseSubtract;
	case rsx::blend_equation::min:              return MTLBlendOperationMin;
	case rsx::blend_equation::max:              return MTLBlendOperationMax;
	// Signed variants not natively supported in Metal — approximate as Add.
	case rsx::blend_equation::add_signed:
	case rsx::blend_equation::reverse_add_signed:
	case rsx::blend_equation::reverse_subtract_signed:
	default:                                    return MTLBlendOperationAdd;
	}
}

unsigned int mtl::to_mtl_blend_factor(rsx::blend_factor f)
{
	switch (f)
	{
	case rsx::blend_factor::zero:                     return MTLBlendFactorZero;
	case rsx::blend_factor::one:                      return MTLBlendFactorOne;
	case rsx::blend_factor::src_color:                return MTLBlendFactorSourceColor;
	case rsx::blend_factor::one_minus_src_color:      return MTLBlendFactorOneMinusSourceColor;
	case rsx::blend_factor::dst_color:                return MTLBlendFactorDestinationColor;
	case rsx::blend_factor::one_minus_dst_color:      return MTLBlendFactorOneMinusDestinationColor;
	case rsx::blend_factor::src_alpha:                return MTLBlendFactorSourceAlpha;
	case rsx::blend_factor::one_minus_src_alpha:      return MTLBlendFactorOneMinusSourceAlpha;
	case rsx::blend_factor::dst_alpha:                return MTLBlendFactorDestinationAlpha;
	case rsx::blend_factor::one_minus_dst_alpha:      return MTLBlendFactorOneMinusDestinationAlpha;
	case rsx::blend_factor::src_alpha_saturate:       return MTLBlendFactorSourceAlphaSaturated;
	case rsx::blend_factor::constant_color:           return MTLBlendFactorBlendColor;
	case rsx::blend_factor::one_minus_constant_color: return MTLBlendFactorOneMinusBlendColor;
	case rsx::blend_factor::constant_alpha:           return MTLBlendFactorBlendAlpha;
	case rsx::blend_factor::one_minus_constant_alpha: return MTLBlendFactorOneMinusBlendAlpha;
	default:                                          return MTLBlendFactorOne;
	}
}

// ---------------------------------------------------------------------------
// pipeline_raster_config::hash
// ---------------------------------------------------------------------------
u64 mtl::pipeline_raster_config::hash() const noexcept
{
	// Pack all blend fields into a single u64 for fast keying.
	u64 h = (static_cast<u64>(color_format) << 32) ^ (static_cast<u64>(depth_format) << 16);
	h ^= blend.enabled    ? 0x1ULL : 0;
	h ^= (static_cast<u64>(blend.rgb_op)    & 0xF) << 4;
	h ^= (static_cast<u64>(blend.alpha_op)  & 0xF) << 8;
	h ^= (static_cast<u64>(blend.src_rgb)   & 0xF) << 12;
	h ^= (static_cast<u64>(blend.dst_rgb)   & 0xF) << 16;
	h ^= (static_cast<u64>(blend.src_alpha) & 0xF) << 20;
	h ^= (static_cast<u64>(blend.dst_alpha) & 0xF) << 24;
	h ^= (static_cast<u64>(blend.write_mask)& 0xF) << 28;
	return h;
}

// ---------------------------------------------------------------------------
// MTLDepthStencilHandle — opaque wrapper
// ---------------------------------------------------------------------------
struct MTLDepthStencilHandle
{
	id<MTLDepthStencilState> state = nil;
};

// ---------------------------------------------------------------------------
// depth_stencil_cache
// ---------------------------------------------------------------------------
mtl::depth_stencil_cache::depth_stencil_cache()  = default;
mtl::depth_stencil_cache::~depth_stencil_cache() = default;

u64 mtl::depth_stencil_cache::make_key(
	bool depth_test, bool depth_write, unsigned int depth_compare,
	bool stencil_test,
	unsigned int front_compare, unsigned int front_fail, unsigned int front_zfail, unsigned int front_zpass, u8 front_write_mask,
	unsigned int back_compare,  unsigned int back_fail,  unsigned int back_zfail,  unsigned int back_zpass,  u8 back_write_mask) const noexcept
{
	u64 k = 0;
	k |= (depth_test   ? 1ULL : 0) << 0;
	k |= (depth_write  ? 1ULL : 0) << 1;
	k |= (static_cast<u64>(depth_compare)  & 0x7) << 2;
	k |= (stencil_test ? 1ULL : 0) << 5;
	k |= (static_cast<u64>(front_compare)  & 0x7) << 6;
	k |= (static_cast<u64>(front_fail)     & 0x7) << 9;
	k |= (static_cast<u64>(front_zfail)    & 0x7) << 12;
	k |= (static_cast<u64>(front_zpass)    & 0x7) << 15;
	k |= (static_cast<u64>(front_write_mask)    ) << 18;
	k |= (static_cast<u64>(back_compare)   & 0x7) << 26;
	k |= (static_cast<u64>(back_fail)      & 0x7) << 29;
	k |= (static_cast<u64>(back_zfail)     & 0x7) << 32;
	k |= (static_cast<u64>(back_zpass)     & 0x7) << 35;
	k |= (static_cast<u64>(back_write_mask)     ) << 38;
	return k;
}

void* mtl::depth_stencil_cache::get(
	bool depth_test, bool depth_write, unsigned int depth_compare,
	bool stencil_test,
	unsigned int front_compare, unsigned int front_fail, unsigned int front_zfail, unsigned int front_zpass, u8 front_write_mask,
	unsigned int back_compare,  unsigned int back_fail,  unsigned int back_zfail,  unsigned int back_zpass,  u8 back_write_mask)
{
	const u64 key = make_key(
		depth_test, depth_write, depth_compare,
		stencil_test,
		front_compare, front_fail, front_zfail, front_zpass, front_write_mask,
		back_compare,  back_fail,  back_zfail,  back_zpass,  back_write_mask);

	auto it = m_cache.find(key);
	if (it != m_cache.end())
		return (__bridge void*)it->second->state;

	id<MTLDevice> device = (__bridge id<MTLDevice>)m_device;

	MTLDepthStencilDescriptor* desc = [MTLDepthStencilDescriptor new];
	desc.depthCompareFunction = depth_test
		? (MTLCompareFunction)depth_compare
		: MTLCompareFunctionAlways;
	desc.depthWriteEnabled = depth_write;

	if (stencil_test)
	{
		auto fill_face = [](MTLStencilDescriptor* s,
		                    unsigned int cmp, unsigned int fail,
		                    unsigned int zfail, unsigned int zpass, u8 wmask)
		{
			s.stencilCompareFunction      = (MTLCompareFunction)cmp;
			s.stencilFailureOperation     = (MTLStencilOperation)fail;
			s.depthFailureOperation       = (MTLStencilOperation)zfail;
			s.depthStencilPassOperation   = (MTLStencilOperation)zpass;
			s.writeMask                   = wmask;
			s.readMask                    = 0xFF;
		};
		fill_face(desc.frontFaceStencil, front_compare, front_fail, front_zfail, front_zpass, front_write_mask);
		fill_face(desc.backFaceStencil,  back_compare,  back_fail,  back_zfail,  back_zpass,  back_write_mask);
	}

	auto handle        = std::make_unique<MTLDepthStencilHandle>();
	handle->state      = [device newDepthStencilStateWithDescriptor:desc];

	void* raw = (__bridge void*)handle->state;
	m_cache.emplace(key, std::move(handle));
	return raw;
}

void mtl::depth_stencil_cache::clear()
{
	m_cache.clear();
}

#pragma GCC diagnostic pop
