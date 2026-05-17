#pragma once
#include "MTLShaderTypes.h"
#include "Emu/RSX/Program/VertexProgramDecompiler.h"

struct RSXVertexProgram;

class MTLVertexProgram : public rsx::VertexProgramBase
{
public:
	MTLVertexProgram() = default;
	~MTLVertexProgram() = default;

	ParamArray parr;
	mtl::compiled_shader compiled;

	// Decompiles RSX microcode → GLSL → SPIR-V → MSL.
	// Does not touch any Vulkan or Metal API — safe to call from any thread.
	void Decompile(const RSXVertexProgram& prog);

	u64 get_compiled_hash() const { return static_cast<u64>(std::hash<std::string>{}(compiled.msl_source)); }
};
