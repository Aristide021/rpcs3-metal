#pragma once
#include "MTLShaderTypes.h"
#include "Emu/RSX/Program/FragmentProgramDecompiler.h"

struct RSXFragmentProgram;

class MTLFragmentProgram
{
public:
	MTLFragmentProgram() = default;
	~MTLFragmentProgram() = default;

	ParamArray parr;
	u32 decompiled_size = 0;
	mtl::compiled_shader compiled;

	std::array<u32, 4> output_color_masks{};

	// Decompiles RSX microcode → GLSL → SPIR-V → MSL.
	void Decompile(const RSXFragmentProgram& prog);
};
