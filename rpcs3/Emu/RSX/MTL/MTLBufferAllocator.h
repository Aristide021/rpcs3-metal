#pragma once
#include "util/types.hpp"
#include <atomic>
#include <cstddef>

// Opaque — MTLBuffer lives in the .mm implementation.
struct MTLBufferState;

namespace mtl
{
	// Lock-free ring allocator over a single MTLStorageModeShared buffer.
	//
	// On Apple Silicon UMA, shared buffers are coherent between CPU and GPU
	// with no map/unmap overhead.  This replaces the VK backend's
	// data_heap (which exists solely to manage staging buffer copies).
	class buffer_ring
	{
	public:
		static constexpr usz default_size = 128 * 1024 * 1024; // 128 MB

		// Defined out-of-line in MTLBufferAllocator.mm so unique_ptr<MTLBufferState>
		// destruction only needs to know about MTLBufferState's full definition there.
		buffer_ring();
		~buffer_ring();
		buffer_ring(const buffer_ring&) = delete;

		// device_handle: id<MTLDevice>* cast to void*
		bool init(void* device_handle, usz size = default_size);

		// Allocate `bytes` with `alignment` byte alignment.
		// Returns the byte offset into the buffer; umax on failure.
		usz alloc(usz bytes, usz alignment = 256);

		// Direct CPU-writable pointer at `offset`.
		void* ptr_at(usz offset) const;

		// The underlying MTLBuffer — caller casts to id<MTLBuffer>.
		void* buffer() const;

		// Reset head to zero at the start of each frame.
		// Caller is responsible for ensuring GPU is done with the old data
		// (insert a completed-handler or use a semaphore).
		void reset();

		usz size() const { return m_size; }
		usz used() const { return m_head.load(std::memory_order_relaxed); }

	private:
		std::unique_ptr<MTLBufferState> m_state;
		usz  m_size = 0;
		std::atomic<usz> m_head{0};
	};
}
