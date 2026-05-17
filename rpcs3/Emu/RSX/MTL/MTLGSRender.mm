#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wold-style-cast"
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

#include "MTLGSRender.h"
#include "Emu/RSX/RSXThread.h"
#include "util/logs.hpp"

LOG_CHANNEL(mtl_log, "MTL");

// ---------------------------------------------------------------------------
// MTLState — all Obj-C objects live here, invisible to C++ translation units
// ---------------------------------------------------------------------------
struct MTLState
{
	id<MTLDevice>       device        = nil;
	id<MTLCommandQueue> command_queue = nil;
	CAMetalLayer*       layer         = nil;
};

// ---------------------------------------------------------------------------
// MTLGSRender
// ---------------------------------------------------------------------------

MTLGSRender::MTLGSRender(utils::serial* ar)
	: GSRender(ar)
	, m_mtl(std::make_unique<MTLState>())
{
}

MTLGSRender::~MTLGSRender() = default;

void MTLGSRender::on_init_thread()
{
	// GSRender::on_init_thread creates m_frame and the OS window.
	GSRender::on_init_thread();

	@autoreleasepool
	{
		m_mtl->device = MTLCreateSystemDefaultDevice();
		if (!m_mtl->device)
		{
			mtl_log.fatal("MTLCreateSystemDefaultDevice() returned nil — Metal is not supported on this system.");
			return;
		}

		mtl_log.notice("Metal device: %s", [[m_mtl->device name] UTF8String]);

		m_mtl->command_queue = [m_mtl->device newCommandQueue];

		// m_frame->handle() is the NSView* on macOS (see display.h).
		NSView* view = static_cast<NSView*>(m_frame->handle());

		// The Qt gs_frame sets up a CAMetalLayer-backed view on Apple.
		// Retrieve the layer and stamp our device onto it.
		m_mtl->layer = static_cast<CAMetalLayer*>(view.layer);
		if (!m_mtl->layer || ![m_mtl->layer isKindOfClass:[CAMetalLayer class]])
		{
			// Fallback: create and attach a fresh CAMetalLayer.
			m_mtl->layer = [CAMetalLayer layer];
			view.layer   = m_mtl->layer;
			view.wantsLayer = YES;
		}

		m_mtl->layer.device          = m_mtl->device;
		m_mtl->layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
		m_mtl->layer.framebufferOnly = NO; // allow readback for screenshots
		m_mtl->layer.drawableSize    = view.bounds.size;

		mtl_log.success("Metal renderer initialised (device=%s, layer=%p)",
			[[m_mtl->device name] UTF8String], (void*)m_mtl->layer);
	}
}

void MTLGSRender::on_exit()
{
	@autoreleasepool
	{
		m_mtl->command_queue = nil;
		m_mtl->device        = nil;
		m_mtl->layer         = nil;
	}

	GSRender::on_exit();
}

void MTLGSRender::flip(const rsx::display_flip_info_t& /*info*/)
{
	if (!m_mtl->layer)
		return;

	@autoreleasepool
	{
		id<CAMetalDrawable> drawable = [m_mtl->layer nextDrawable];
		if (!drawable)
		{
			mtl_log.warning("flip: nextDrawable returned nil, skipping frame.");
			return;
		}

		MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture     = drawable.texture;
		pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		pass.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

		id<MTLCommandBuffer>        cmd      = [m_mtl->command_queue commandBuffer];
		id<MTLRenderCommandEncoder> encoder  = [cmd renderCommandEncoderWithDescriptor:pass];
		[encoder endEncoding];

		[cmd presentDrawable:drawable];
		[cmd commit];
	}

	// Let the base class handle flip-throttling and frame-counter bookkeeping.
	GSRender::flip(info);
}

void MTLGSRender::clear_surface(u32 /*mask*/)
{
	// Stubbed — will encode a Metal clear pass once the render target
	// system is in place.
}

void MTLGSRender::do_local_task(rsx::FIFO::state state)
{
	rsx::thread::do_local_task(state);
}

u64 MTLGSRender::get_cycles()
{
	return 0;
}

#pragma GCC diagnostic pop
