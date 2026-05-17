#pragma once
#include <string>
#include <vector>
#include "util/types.hpp"

// Shared types used between MTLVertexProgram, MTLFragmentProgram, and MTLProgramPipeline.
// Kept Vulkan-free so this header can be included from .mm files without conflicts.

namespace mtl
{
	// Mirrors the VK binding slot record — filled by SPIRV-Cross reflection.
	struct program_input
	{
		enum class type : u8
		{
			uniform_buffer,
			texture,
			sampler,
		};

		type  input_type;
		u32   binding;     // Metal buffer/texture index
		std::string name;
	};

	// A fully compiled Metal shader stage ready for pipeline assembly.
	struct compiled_shader
	{
		std::string msl_source;          // MSL text (kept for logging / debug)
		std::vector<program_input> inputs;
	};
}
