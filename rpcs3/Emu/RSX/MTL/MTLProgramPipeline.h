#pragma once
#include "MTLShaderTypes.h"
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
		program() = default;
		~program();

		program(const program&) = delete;
		program& operator=(const program&) = delete;

		// Build the pipeline state from pre-compiled MSL source strings.
		// device_handle must be an id<MTLDevice>* cast to void*.
		bool build(
			void*                      device_handle,
			const compiled_shader&     vs,
			const compiled_shader&     fs);

		// The underlying MTLRenderPipelineState, cast to void* for C++ callers.
		void* pipeline_state() const;

		bool is_valid() const { return m_handle != nullptr; }

	private:
		std::unique_ptr<MTLPipelineHandle> m_handle;
	};
}
