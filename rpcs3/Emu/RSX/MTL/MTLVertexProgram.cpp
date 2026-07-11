#include "stdafx.h"
#include "MTLVertexProgram.h"

// Reuse the VK decompiler to get Vulkan-GLSL from RSX microcode.
// We call Decompile() only (never Compile()) so no Vulkan device is needed.
#include "Emu/RSX/VK/VKVertexProgram.h"
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

// ---------------------------------------------------------------------------
// SPIRV-Cross resource → mtl::program_input conversion
// ---------------------------------------------------------------------------
static void reflect_resources(
	const spirv_cross::Compiler&               cc,
	const spirv_cross::SmallVector<spirv_cross::Resource>& resources,
	mtl::program_input::type                   input_type,
	std::vector<mtl::program_input>&           out)
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

// ---------------------------------------------------------------------------
// SPIR-V → MSL via SPIRV-Cross
// ---------------------------------------------------------------------------
static bool spirv_to_msl(
	const std::vector<u32>&    spirv,
	mtl::compiled_shader&      out)
{
	try
	{
		spirv_cross::CompilerMSL compiler(spirv);

		spirv_cross::CompilerMSL::Options opts;
		opts.platform         = spirv_cross::CompilerMSL::Options::macOS;
		opts.msl_version      = spirv_cross::CompilerMSL::Options::make_msl_version(3, 0);
		// argument_buffers=false triggers a heap-corruption bug in SPIRV-Cross 0.x's
		// MSL interface-block path on our vertex inputs. Switch back to argument
		// buffers; binding code in MTLDraw.mm needs to walk the argbuf descriptor
		// rather than calling setVertexBuffer:atIndex: directly.
		opts.argument_buffers = true;
		compiler.set_msl_options(opts);

		// Reflect uniform buffers and textures so we can build the binding table.
		const auto& resources = compiler.get_shader_resources();
		reflect_resources(compiler, resources.uniform_buffers,   mtl::program_input::type::uniform_buffer, out.inputs);
		reflect_resources(compiler, resources.separate_images,   mtl::program_input::type::texture,        out.inputs);
		reflect_resources(compiler, resources.separate_samplers, mtl::program_input::type::sampler,        out.inputs);

		out.msl_source = compiler.compile();
		return true;
	}
	catch (const spirv_cross::CompilerError& e)
	{
		mtl_log.error("SPIRV-Cross compilation failed: %s", e.what());
		return false;
	}
}

// ---------------------------------------------------------------------------
// MTLVertexProgram
// ---------------------------------------------------------------------------
void MTLVertexProgram::Decompile(const RSXVertexProgram& prog)
{
	mtl_log.warning("MTL: VS Decompile V1 — prog.data.size=%zu jump_table.size=%zu base_addr=0x%x output_mask=0x%x",
		prog.data.size(), prog.jump_table.size(), prog.base_address, prog.output_mask);
	// Step 1: RSX microcode → Vulkan GLSL (no Vulkan device needed)
	VKVertexProgram vk_prog;
	mtl_log.warning("MTL: VS Decompile V2 — about to vk_prog.Decompile (vk_prog at %p)", &vk_prog);
	vk_prog.Decompile(prog);
	mtl_log.warning("MTL: VS Decompile V3 — about to get GLSL source");

	std::string glsl = vk_prog.shader.get_source();
	mtl_log.warning("MTL: VS Decompile V4 — glsl len=%zu", glsl.size());

	// SPIRV-Cross MSL backend's interface-block builder corrupts the heap when fed
	// a `uniform` block whose body is a std430 unsized runtime array (the
	// GL_EXT_uniform_buffer_unsized_array pattern). The same shape works fine when
	// declared as an SSBO (`readonly buffer`) because MSL ends up with `device const T*`
	// for both anyway. The VK decompiler emits two such UBOs — promote them to SSBO
	// for our MTL path only.
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
	promote("VertexContextBuffer");
	promote("VertexConstantsBuffer");

	// Always dump VS GLSL so we have it for postmortem if SPIRV-Cross blows up.
	fs::write_file("/tmp/rpcs3-last-vs.glsl", fs::rewrite, glsl);

	if (g_cfg.video.log_programs)
	{
		const auto path = fs::get_cache_dir() + "shaderlog/MTL_VertexProgram" + std::to_string(id) + ".glsl";
		fs::write_file(path, fs::rewrite, glsl);
	}

	mtl_log.warning("MTL: VS Decompile V5 — about to glsl→spv");
	// Step 2: Vulkan GLSL → SPIR-V (reuse the existing glslang compiler)
	std::vector<u32> spirv;
	if (!spirv::compile_glsl_to_spv(spirv, glsl,
		::glsl::program_domain::glsl_vertex_program,
		::glsl::glsl_rules_vulkan))
	{
		mtl_log.error("MTLVertexProgram: GLSL→SPIR-V compilation failed.\n%s", glsl);
		return;
	}
	mtl_log.warning("MTL: VS Decompile V6 — spv words=%zu, about to spirv→msl", spirv.size());
	// Dump SPIR-V too in case glslang produced something unusual.
	fs::write_file("/tmp/rpcs3-last-vs.spv", fs::rewrite,
		std::string_view(reinterpret_cast<const char*>(spirv.data()), spirv.size() * sizeof(u32)));

	// Step 3: SPIR-V → MSL (SPIRV-Cross)
	if (!spirv_to_msl(spirv, compiled))
	{
		mtl_log.error("MTLVertexProgram: SPIR-V→MSL compilation failed.");
		return;
	}
	mtl_log.warning("MTL: VS Decompile V7 — msl_source len=%zu", compiled.msl_source.size());

	// Capture binding locations from the VK decompiler's binding table.
	binding_table.persistent_stream = vk_prog.binding_table.vertex_buffers_location + 0;
	binding_table.volatile_stream   = vk_prog.binding_table.vertex_buffers_location + 1;
	binding_table.context_buf       = vk_prog.binding_table.context_buffer_location;
	binding_table.constants_buf     = vk_prog.binding_table.cbuf_location;
	for (int i = 0; i < 4; ++i)
		binding_table.vtex_location[i] = vk_prog.binding_table.vtex_location[i];

	if (g_cfg.video.log_programs)
	{
		const auto path = fs::get_cache_dir() + "shaderlog/MTL_VertexProgram" + std::to_string(id) + ".metal";
		fs::write_file(path, fs::rewrite, compiled.msl_source);
	}
}
