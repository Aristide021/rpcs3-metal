#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#import <Metal/Metal.h>
#include "stdafx.h"
#include "MTLProgramPipeline.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_log, "MTL");

// ---------------------------------------------------------------------------
// MTLPipelineHandle — owns the ObjC objects
// ---------------------------------------------------------------------------
struct MTLPipelineHandle
{
	id<MTLLibrary>              vs_lib   = nil;
	id<MTLLibrary>              fs_lib   = nil;
	id<MTLRenderPipelineState>  state    = nil;
};

// ---------------------------------------------------------------------------
// mtl::program
// ---------------------------------------------------------------------------
mtl::program::~program() = default;

static id<MTLLibrary> compile_msl(id<MTLDevice> device, const std::string& source, const char* label)
{
	@autoreleasepool
	{
		NSError* error   = nil;
		NSString* ns_src = [NSString stringWithUTF8String:source.c_str()];

		MTLCompileOptions* opts = [MTLCompileOptions new];
		opts.languageVersion = MTLLanguageVersion3_0;
		opts.fastMathEnabled = YES;

		id<MTLLibrary> lib = [device newLibraryWithSource:ns_src options:opts error:&error];
		if (!lib)
		{
			mtl_log.error("MTL: failed to compile %s shader library: %s",
				label, [[error localizedDescription] UTF8String]);
		}
		else if (error)
		{
			// Warnings are non-fatal.
			mtl_log.warning("MTL: %s shader warnings: %s",
				label, [[error localizedDescription] UTF8String]);
		}
		return lib;
	}
}

bool mtl::program::build(
	void*                  device_handle,
	const compiled_shader& vs,
	const compiled_shader& fs)
{
	@autoreleasepool
	{
		id<MTLDevice> device = (__bridge id<MTLDevice>)device_handle;

		auto handle     = std::make_unique<MTLPipelineHandle>();
		handle->vs_lib  = compile_msl(device, vs.msl_source, "vertex");
		handle->fs_lib  = compile_msl(device, fs.msl_source, "fragment");

		if (!handle->vs_lib || !handle->fs_lib)
			return false;

		// SPIRV-Cross names the entry point "main0" when the source used "main".
		id<MTLFunction> vs_fn = [handle->vs_lib newFunctionWithName:@"main0"];
		id<MTLFunction> fs_fn = [handle->fs_lib newFunctionWithName:@"main0"];

		if (!vs_fn || !fs_fn)
		{
			mtl_log.error("MTL: could not find entry point 'main0' in compiled library.");
			return false;
		}

		MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
		desc.vertexFunction                         = vs_fn;
		desc.fragmentFunction                       = fs_fn;
		desc.colorAttachments[0].pixelFormat        = MTLPixelFormatBGRA8Unorm;

		NSError* error = nil;
		handle->state  = [device newRenderPipelineStateWithDescriptor:desc error:&error];
		if (!handle->state)
		{
			mtl_log.error("MTL: pipeline state compilation failed: %s",
				[[error localizedDescription] UTF8String]);
			return false;
		}

		m_handle = std::move(handle);
		return true;
	}
}

void* mtl::program::pipeline_state() const
{
	if (!m_handle) return nullptr;
	return (__bridge void*)m_handle->state;
}

#pragma GCC diagnostic pop
