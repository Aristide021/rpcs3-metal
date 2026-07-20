#include "stdafx.h"
#include "MTLFragmentProgram.h"

#include "Emu/RSX/VK/VKFragmentProgram.h"
#include "Emu/RSX/Program/SPIRVCommon.h"
#include "Emu/RSX/Program/GLSLTypes.h"

#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wold-style-cast"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
#include "spirv_cross/spirv_msl.hpp"
#ifdef __clang__
#pragma clang diagnostic pop
#endif

#include "util/logs.hpp"

LOG_CHANNEL(mtl_log, "MTL");

static void reflect_resources(
	const spirv_cross::Compiler&                               cc,
	const spirv_cross::SmallVector<spirv_cross::Resource>&     resources,
	mtl::program_input::type                                   input_type,
	std::vector<mtl::program_input>&                           out)
{
	for (const auto& res : resources)
	{
		mtl::program_input pi;
		pi.input_type = input_type;
		pi.binding    = cc.get_decoration(res.id, spv::DecorationBinding);
		pi.name       = cc.get_name(res.id);
		out.push_back(std::move(pi));
	}
}

static bool spirv_to_msl(const std::vector<u32>& spirv, mtl::compiled_shader& out)
{
	try
	{
		// (ptr, size) ctor — see MTLVertexProgram.cpp.
		spirv_cross::CompilerMSL compiler(spirv.data(), spirv.size());

		spirv_cross::CompilerMSL::Options opts;
		opts.platform         = spirv_cross::CompilerMSL::Options::macOS;
		opts.msl_version      = spirv_cross::CompilerMSL::Options::make_msl_version(3, 0);
		opts.argument_buffers = true; // see MTLVertexProgram.cpp for rationale
		compiler.set_msl_options(opts);

		const auto& resources = compiler.get_shader_resources();
		reflect_resources(compiler, resources.uniform_buffers,   mtl::program_input::type::uniform_buffer, out.inputs);
		reflect_resources(compiler, resources.separate_images,   mtl::program_input::type::texture,        out.inputs);
		reflect_resources(compiler, resources.separate_samplers, mtl::program_input::type::sampler,        out.inputs);

		out.msl_source = compiler.compile();
		return true;
	}
	catch (const spirv_cross::CompilerError& e)
	{
		mtl_log.error("SPIRV-Cross (fragment) failed: %s", e.what());
		return false;
	}
}

void MTLFragmentProgram::Decompile(const RSXFragmentProgram& prog)
{
	// Step 1: RSX microcode → Vulkan GLSL
	VKFragmentProgram vk_prog;
	vk_prog.Decompile(prog);
	output_color_masks = vk_prog.output_color_masks;

	std::string glsl = vk_prog.shader.get_source();

	// See MTLVertexProgram.cpp: SPIRV-Cross MSL backend corrupts the heap when fed
	// `uniform` blocks containing std430 unsized runtime arrays. Promote them to
	// SSBOs (`readonly buffer`) for our MTL path only — MSL output is equivalent.
	auto promote = [&](const std::string& needle)
	{
		const std::string with_uniform = "uniform " + needle;
		const std::string with_buffer  = "readonly restrict buffer " + needle;
		size_t pos = 0;
		while ((pos = glsl.find(with_uniform, pos)) != std::string::npos)
		{
			glsl.replace(pos, with_uniform.size(), with_buffer);
			pos += with_buffer.size();
		}
	};
	promote("FragmentConstantsBuffer");
	promote("FragmentStateBuffer");
	promote("TextureParametersBuffer");

	if (g_cfg.video.log_programs)
	{
		const auto path = fs::get_cache_dir() + "shaderlog/MTL_FragmentProgram" + std::to_string(vk_prog.id) + ".glsl";
		fs::write_file(path, fs::rewrite, glsl);
	}

	// Step 2: Vulkan GLSL → SPIR-V
	std::vector<u32> spirv;
	if (!spirv::compile_glsl_to_spv(spirv, glsl,
		::glsl::program_domain::glsl_fragment_program,
		::glsl::glsl_rules_vulkan))
	{
		mtl_log.error("MTLFragmentProgram: GLSL→SPIR-V failed.\n%s", glsl);
		return;
	}

	// Step 3: SPIR-V → MSL
	if (!spirv_to_msl(spirv, compiled))
	{
		mtl_log.error("MTLFragmentProgram: SPIR-V→MSL failed.");
		return;
	}

	// Capture binding locations from the VK decompiler's binding table.
	const auto& bt = vk_prog.binding_table;
	binding_table.context_buf    = bt.context_buffer_location;
	binding_table.constants_buf  = bt.cbuf_location;
	binding_table.tex_param_buf  = bt.tex_param_location;
	binding_table.rasterizer_heap = bt.polygon_stipple_params_location;
	for (int i = 0; i < 16; ++i)
		binding_table.ftex_location[i] = bt.ftex_location[i];

	if (g_cfg.video.log_programs)
	{
		const auto path = fs::get_cache_dir() + "shaderlog/MTL_FragmentProgram" + std::to_string(vk_prog.id) + ".metal";
		fs::write_file(path, fs::rewrite, compiled.msl_source);
	}
}
