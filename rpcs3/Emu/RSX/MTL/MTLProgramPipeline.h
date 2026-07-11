#pragma once
#include "MTLShaderTypes.h"
#include "MTLRasterState.h"
#include <memory>

// Opaque handle — MTLRenderPipelineState lives in the .mm implementation.
struct MTLPipelineHandle;

namespace mtl
{
	// Owns a compiled MTLRenderPipelineState and the MTLLibrary objects that
	// back the vertex and fragment functions.
	class program
	{
	public:
		// Defined out-of-line so unique_ptr<MTLPipelineHandle> sees the complete
		// type at instantiation sites.
		program();
		~program();

		program(const program&) = delete;
		program& operator=(const program&) = delete;

		// Build the pipeline state from pre-compiled MSL source strings.
		// device_handle must be an id<MTLDevice>* cast to void*.
		// raster supplies color/depth pixel formats and blend state —
		// all three are baked into MTLRenderPipelineState by Metal.
		bool build(
			void*                        device_handle,
			const compiled_shader&       vs,
			const compiled_shader&       fs,
			const pipeline_raster_config& raster);

		// The underlying MTLRenderPipelineState, cast to void* for C++ callers.
		void* pipeline_state() const;

		bool is_valid() const { return m_handle != nullptr; }

	private:
		std::unique_ptr<MTLPipelineHandle> m_handle;
	};
}
