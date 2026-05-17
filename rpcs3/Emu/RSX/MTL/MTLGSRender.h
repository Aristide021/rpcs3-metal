#pragma once

#include "Emu/RSX/GSRender.h"
#include <memory>

// Opaque handle to Metal objects — defined only in MTLGSRender.mm so this
// header stays plain C++ and can be included from non-.mm translation units.
struct MTLState;

class MTLGSRender : public GSRender
{
public:
	MTLGSRender(utils::serial* ar);
	~MTLGSRender() override;

	void on_init_thread() override;
	void on_exit() override;
	void flip(const rsx::display_flip_info_t& info) override;
	void clear_surface(u32 mask) override;
	void do_local_task(rsx::FIFO::state state) override;
	u64  get_cycles() final;

private:
	std::unique_ptr<MTLState> m_mtl;
};
