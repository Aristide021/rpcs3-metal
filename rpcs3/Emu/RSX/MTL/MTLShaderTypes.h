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
		u32   binding;     // Metal buffer/texture index (= GLSL binding with arg_buffers=false)
		std::string name;
	};

	// A fully compiled Metal shader stage ready for pipeline assembly.
	struct compiled_shader
	{
		std::string msl_source;          // MSL text (kept for logging / debug)
		std::vector<program_input> inputs;
	};

	// Binding indices extracted from the VK decompiler binding_table.
	// Tells emit_geometry() where to plug in UBOs, textures, etc.
	static constexpr u32 invalid_binding = 0xFFFFFFFFu;

	struct vertex_binding_table
	{
		u32 persistent_stream  = 0;  // usamplerBuffer at set=0, binding=0
		u32 volatile_stream    = 1;  // usamplerBuffer at set=0, binding=1
		u32 context_buf        = invalid_binding;  // VertexContextBuffer
		u32 constants_buf      = invalid_binding;  // VertexConstantsBuffer
		u32 vtex_location[4]   = { invalid_binding, invalid_binding, invalid_binding, invalid_binding };
	};

	struct fragment_binding_table
	{
		u32 context_buf        = invalid_binding;  // FragmentStateBuffer
		u32 constants_buf      = invalid_binding;  // FragmentConstantsBuffer
		u32 tex_param_buf      = invalid_binding;  // TextureParametersBuffer
		u32 rasterizer_heap    = invalid_binding;  // RasterizerHeap
		u32 ftex_location[16]  = {};  // per fragment texture slot → Metal binding index
	};
}
