#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"

#define Vector128 _AppleCarbonVector128
#import <Metal/Metal.h>
#undef Vector128

#include "stdafx.h"
#include "MTLBufferAllocator.h"
#include "util/logs.hpp"
#include "util/asm.hpp"

LOG_CHANNEL(mtl_log, "MTL");

struct MTLBufferState
{
	id<MTLBuffer> buffer = nil;
	uint8_t*      base   = nullptr;
};

mtl::buffer_ring::buffer_ring() = default;
mtl::buffer_ring::~buffer_ring() = default;

bool mtl::buffer_ring::init(void* device_handle, usz size)
{
	@autoreleasepool
	{
		id<MTLDevice> device = (__bridge id<MTLDevice>)device_handle;

		auto state    = std::make_unique<MTLBufferState>();
		state->buffer = [device newBufferWithLength:size
		                                    options:MTLResourceStorageModeShared
		                                           | MTLResourceCPUCacheModeDefaultCache];
		if (!state->buffer)
		{
			mtl_log.error("buffer_ring::init: failed to allocate %zu MB shared buffer.", size >> 20);
			return false;
		}

		state->buffer.label = @"RPCS3 attribute ring";
		state->base = static_cast<uint8_t*>(state->buffer.contents);

		m_size  = size;
		m_head  = 0;
		m_state = std::move(state);

		mtl_log.notice("buffer_ring: allocated %zu MB shared buffer.", size >> 20);
		return true;
	}
}

usz mtl::buffer_ring::alloc(usz bytes, usz alignment)
{
	if (!bytes) return 0;

	// Align up then claim atomically.
	usz current = m_head.load(std::memory_order_relaxed);
	usz aligned, next;
	do
	{
		aligned = utils::align(current, alignment);
		next    = aligned + bytes;
		if (next > m_size)
		{
			// Wrap around — simple linear allocator, callers handle frame sync.
			aligned = 0;
			next    = bytes;
		}
	}
	while (!m_head.compare_exchange_weak(current, next,
		std::memory_order_acquire, std::memory_order_relaxed));

	return aligned;
}

void* mtl::buffer_ring::ptr_at(usz offset) const
{
	return m_state ? m_state->base + offset : nullptr;
}

void* mtl::buffer_ring::buffer() const
{
	return m_state ? (__bridge void*)m_state->buffer : nullptr;
}

void mtl::buffer_ring::reset()
{
	m_head.store(0, std::memory_order_release);
}

#pragma GCC diagnostic pop
