#pragma once
#include "MTLShaderTypes.h"
#include "Emu/RSX/Program/FragmentProgramDecompiler.h"

struct RSXFragmentProgram;

class MTLFragmentProgram
{
public:
	MTLFragmentProgram() = default;
	~MTLFragmentProgram() = default;

	mtl::compiled_shader compiled;
	mtl::fragment_binding_table binding_table;

	std::array<u32, 4> output_color_masks{};

	// Decompiles RSX microcode → GLSL → SPIR-V → MSL.
	void Decompile(const RSXFragmentProgram& prog);

	u64 get_compiled_hash() const { return static_cast<u64>(std::hash<std::string>{}(compiled.msl_source)); }
};
