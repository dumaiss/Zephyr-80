// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: the IO controller's mouse and controller latches
// (zephyr80_ioc_hid, zephyr80_controller_latch) through the protocol core:
// HID_MOUSE and HID_STATUS frames out (tests/ioc_core/rig.h).  Every expected
// byte is the firmware's (Code/MCU/IOController src/ioc_hid.c
// tuh_hid_report_received_cb, hid_mouse_take, tuh_hid_mount_cb,
// tuh_hid_umount_cb, coleco_keypad_for_report, gamepad_unmount;
// src/controller_latch.c controller_latch_f310_report,
// controller_latch_keypad, controller_latch_release; src/handlers.c
// handler_hid_mouse, handler_hid_gamepad_page, handler_hid_other_page),
// cited per test.
#include "rig.h"
#include "memory_storage.h"

#include <algorithm>
#include <cstring>

namespace {

using rig = rig_t<memory_storage>;
using hid_t = zephyr80_ioc_hid;
using latch_t = zephyr80_controller_latch;

std::string show(bytes const &b)
{
	std::string out;
	char buffer[4];
	for (u8 v : b)
	{
		std::snprintf(buffer, sizeof buffer, "%02X ", v);
		out += buffer;
	}
	return out;
}

struct mouse_rig
{
	rig t;
	hid_t &hid() { return t.core.hid(); }
	mouse_rig()
	{
		hid().mount();
		hid().mount_mouse();
	}

	// The 7-byte report of the dongle's mouse: ID 02, buttons, X and Y as two
	// 12-bit signed fields (X low byte; X high nibble with Y low nibble above
	// it; Y high byte), wheel, horizontal scroll.
	void report(u8 buttons, int dx, int dy, int wheel = 0)
	{
		u16 const x = u16(dx) & 0x0fff, y = u16(dy) & 0x0fff;
		u8 const r[7] = { 0x02, buttons, u8(x), u8((x >> 8) | ((y & 0x0f) << 4)), u8(y >> 4), u8(wheel), 0 };
		hid().mouse_report(r, 7);
	}

	struct taken
	{
		u8 flags, buttons, pressed;
		int dx, dy, wheel;
	};
	// CMD_HID_MOUSE as handler_hid_mouse answers it.
	taken take()
	{
		reply_t r = t.cmd(0x12);
		check(r.cls == 0x92 && r.status == 0 && r.data.size() == 9, "HID_MOUSE: 9 DATA bytes (%zu)", r.data.size());
		return { r.data[0], r.data[1], r.data[2], s16(r.u16_at(3)), s16(r.u16_at(5)), s16(r.u16_at(7)) };
	}
};

bool is(mouse_rig::taken const &m, u8 flags, u8 buttons, u8 pressed, int dx, int dy, int wheel)
{
	return m.flags == flags && m.buttons == buttons && m.pressed == pressed && m.dx == dx && m.dy == dy && m.wheel == wheel;
}

std::string show(mouse_rig::taken const &m)
{
	char buffer[96];
	std::snprintf(buffer, sizeof buffer, "flags %02X buttons %02X pressed %02X dx %d dy %d wheel %d", m.flags, m.buttons, m.pressed, m.dx, m.dy, m.wheel);
	return buffer;
}

//**************************************************************************
//  The mouse (hid_mouse_take, tuh_hid_report_received_cb)
//**************************************************************************

// No mouse mounted, then mounted and silent, then the first report: the flags
// are MOUNTED (a second interface), then DECODED (a report parsed as the mouse).
void mouse_flags()
{
	rig bare;
	bare.core.hid().mount();
	reply_t r = bare.cmd(0x12);
	check(r.cls == 0x92 && r.data.size() == 9 && std::all_of(r.data.begin(), r.data.end(), [] (u8 b) { return b == 0; }),
			"no mouse: flags 0 and an all-zero report (%s)", show(r.data).c_str());

	mouse_rig m;
	check(is(m.take(), hid_t::HID_MOUSE_MOUNTED, 0, 0, 0, 0, 0), "mounted and silent: MOUNTED only");
	m.report(0, 0, 0);
	check(is(m.take(), 3, 0, 0, 0, 0, 0), "after the first report: MOUNTED | DECODED");

	// A report that is not ID 02 with 7 bytes is counted and kept raw, not decoded.
	mouse_rig raw;
	u8 const other[8] = { 0x01, 0x01, 0x10, 0, 0, 0, 0, 0 };
	raw.hid().mouse_report(other, 8);
	u8 const wrong_id[7] = { 0x03, 0x01, 0x10, 0, 0, 0, 0 };
	raw.hid().mouse_report(wrong_id, 7);
	u8 const short_report[6] = { 0x02, 0x01, 0x10, 0, 0, 0 };
	raw.hid().mouse_report(short_report, 6);
	check(is(raw.take(), 1, 0, 0, 0, 0, 0), "an 8-byte report, ID 03 and a 6-byte report are not the mouse (MOUNTED only)");
	reply_t page = raw.t.cmd(0x0d, { 7 });
	check(page.data.size() == 21 && page.data[0] == 7 && page.u16_at(3) == 3 && page.data[5] == 6 &&
			page.data[6] == 0x02 && page.data[7] == 0x01 && page.data[8] == 0x10,
			"page 7 counts the three reports and keeps the last raw (%s)", show(page.data).c_str());

	// A boot mouse (protocol 2) is ignored at mount; with no keyboard first the
	// interface would be taken as the keyboard, so nothing mounts.
	rig boot;
	boot.core.hid().mount();
	check(!boot.core.hid().mount_mouse(2) && !boot.core.hid().mouse_mounted(), "a protocol-2 interface is not the mouse");
	reply_t g = boot.cmd(0x0d, { 6 });
	check(g.data.size() == 26 && g.data[9] == 2 && g.data[10] == 1 && g.data[25] == 2,
			"page 6: two HID mounts (keyboard, the ignored mouse), last address 1, last protocol 2 (%s)", show(g.data).c_str());
	rig nokbd;
	check(!nokbd.core.hid().mount_mouse(), "no keyboard mounted: the interface does not become the mouse");
}

// hid_mouse_take: dx, dy and wheel add up between takes; a take clears them
// and the presses, not the buttons held.
void mouse_accumulation()
{
	mouse_rig m;
	m.report(0, 5, -3, 0);
	m.report(0, 7, 10, 1);
	m.report(0, -2, 0, -1);
	mouse_rig::taken t = m.take();
	check(is(t, 3, 0, 0, 10, 7, 0), "three reports add up: dx 10, dy 7, wheel 0 (%s)", show(t).c_str());
	t = m.take();
	check(is(t, 3, 0, 0, 0, 0, 0), "a take clears the motion (%s)", show(t).c_str());

	// 12-bit signed fields: the extremes and the sign extension.
	m.report(0, 2047, -2048, 127);
	t = m.take();
	check(is(t, 3, 0, 0, 2047, -2048, 127), "extremes 2047, -2048, wheel 127 (%s)", show(t).c_str());
	m.report(0, -1, -1, -128);
	t = m.take();
	check(is(t, 3, 0, 0, -1, -1, -128), "-1, -1, wheel -128 (%s)", show(t).c_str());

	// Pressed edges: a press and a release between two takes still show, the
	// held buttons are the latest report's.
	m.report(0x01, 0, 0);
	m.report(0x00, 0, 0);
	t = m.take();
	check(is(t, 3, 0x00, 0x01, 0, 0, 0), "press and release between takes: held 0, pressed 1 (%s)", show(t).c_str());
	check(is(m.take(), 3, 0, 0, 0, 0, 0), "the edge is consumed by the take");
	m.report(0x01, 0, 0);
	m.report(0x03, 0, 0);
	t = m.take();
	check(is(t, 3, 0x03, 0x03, 0, 0, 0), "left then right added: held 3, pressed 3 (%s)", show(t).c_str());
	t = m.take();
	check(is(t, 3, 0x03, 0x00, 0, 0, 0), "held buttons persist across takes, pressed does not (%s)", show(t).c_str());
	m.report(0x03, 1, 1);
	t = m.take();
	check(is(t, 3, 0x03, 0x00, 1, 1, 0), "a report with the buttons unchanged presses nothing (%s)", show(t).c_str());
	m.report(0x04, 0, 0);
	t = m.take();
	check(is(t, 3, 0x04, 0x04, 0, 0, 0), "middle pressed, left and right released (%s)", show(t).c_str());
	m.report(0x00, 0, 0);
	check(is(m.take(), 3, 0, 0, 0, 0, 0), "released: held 0, nothing pressed");

	// The mouse and the keyboard are independent: motion queues no byte, a key
	// does not touch the mouse.
	check(m.hid().queued() == 0 && !m.t.link.doorbell, "mouse reports queue nothing for the keyboard");
	u8 const key_a[8] = { 0, 0, 0x04, 0, 0, 0, 0, 0 };
	m.hid().report(key_a, 8, 0);
	m.report(0x01, 4, 4);
	check(m.hid().queued() == 1 && m.t.link.doorbell, "a key still queues its byte");
	check(is(m.take(), 3, 0x01, 0x01, 4, 4, 0), "and the keyboard report did not disturb the mouse");
}

// Saturation: +/-32767, never wrapped, never -32768 (the capped add).
void mouse_saturation()
{
	mouse_rig m;
	for (int i = 0; i < 20; i++)
		m.report(0, 2047, -2047, 127);
	mouse_rig::taken t = m.take();
	check(is(t, 3, 0, 0, 32767, -32767, 2540), "20 x (2047, -2047, 127): dx 32767 and dy -32767 (capped, wheel 2540) (%s)", show(t).c_str());
	for (int i = 0; i < 300; i++)
		m.report(0, 0, 0, 127);
	t = m.take();
	check(t.wheel == 32767, "300 notches of 127: wheel capped at 32767 (%s)", show(t).c_str());
	for (int i = 0; i < 300; i++)
		m.report(0, 0, 0, -128);
	t = m.take();
	check(t.wheel == -32767, "300 x -128: wheel floored at -32767 (%s)", show(t).c_str());
	// The boundary: exactly 32767 is kept, one more is still 32767 (and the
	// mirror: -32767 is kept, -32768 is never produced).
	m.take();
	for (int i = 0; i < 16; i++)
		m.report(0, 2047, -2047);
	m.report(0, 15, -15);
	t = m.take();
	check(t.dx == 32767 && t.dy == -32767, "16 x 2047 + 15 = 32767 exactly (%s)", show(t).c_str());
	for (int i = 0; i < 16; i++)
		m.report(0, 2047, -2047);
	m.report(0, 15, -15);
	m.report(0, 1, -1);
	t = m.take();
	check(t.dx == 32767 && t.dy == -32767, "one more is still 32767, and -32768 is never produced (%s)", show(t).c_str());
	// A long throw then the opposite stays clipped: the sum, not a reversal.
	for (int i = 0; i < 20; i++)
		m.report(0, 2047, 0);
	m.report(0, -2000, 0);
	t = m.take();
	check(t.dx == 32767 - 2000, "capped, then -2000: 30767 (%s)", show(t).c_str());
	for (int i = 0; i < 17; i++)
		m.report(0, -2048, 0);
	t = m.take();
	check(t.dx == -32767, "17 x -2048 = -34816: floored at -32767 (%s)", show(t).c_str());
}

// HID_STATUS page 7 (handler_hid_other_page): the running totals wrap and are
// not cleared by a take; the buttons are the latest report's.
void mouse_totals()
{
	mouse_rig m;
	m.report(0x05, 100, -50, 3);
	m.take();
	reply_t r = m.t.cmd(0x0d, { 7 });
	check(r.data.size() == 21 && r.data[0] == 7 && r.data[1] == hid_t::KEYBOARD_ADDRESS && r.data[2] == hid_t::MOUSE_INSTANCE &&
			r.u16_at(3) == 1 && r.data[5] == 7 && r.data[14] == 0x05 && r.u16_at(15) == 100 && r.u16_at(17) == u16(-50) && r.u16_at(19) == 3,
			"page 7 after one report: address, instance 1, 1 report of 7 bytes, buttons 5, totals 100, -50, 3 (%s)", show(r.data).c_str());
	check(r.data[6] == 0x02 && r.data[7] == 0x05 && r.data[8] == 0x64 && r.data[9] == 0xe0 && r.data[10] == 0xfc && r.data[11] == 0x03 && r.data[12] == 0,
			"the raw report (X 064h; Y -50 = FCEh: low nibble E above X's high nibble, high byte FCh): 02 05 64 E0 FC 03 00 (%s)", show(r.data).c_str());
	for (int i = 0; i < 400; i++)
		m.report(0, 2047, 0);
	r = m.t.cmd(0x0d, { 7 });
	check(r.u16_at(15) == u16(100 + 400 * 2047) && r.u16_at(3) == 401, "totals wrap in 16 bits: %u (%u reports)", r.u16_at(15), r.u16_at(3));
	mouse_rig::taken t = m.take();
	check(t.dx == 32767, "while the take is capped");
	r = m.t.cmd(0x0d, { 7 });
	check(r.u16_at(15) == u16(100 + 400 * 2047), "a take does not clear the totals");
}

// tuh_hid_umount_cb: the buttons, the decode flag and the pending motion clear;
// the totals stay.  A controller reset clears everything.
void mouse_lifecycle()
{
	mouse_rig m;
	m.report(0x01, 30, 40, 2);
	m.hid().unmount_mouse();
	mouse_rig::taken t = m.take();
	check(is(t, 0, 0, 0, 0, 0, 0), "removed: flags 0, no buttons, no pressed, no motion (%s)", show(t).c_str());
	reply_t r = m.t.cmd(0x0d, { 7 });
	check(r.data[1] == 0 && r.data[14] == 0 && r.u16_at(15) == 30 && r.u16_at(17) == 40, "page 7: no interface, buttons 0, totals kept (%s)", show(r.data).c_str());
	m.report(0x01, 9, 9);
	check(is(m.take(), 0, 0, 0, 0, 0, 0), "a report from a removed mouse is ignored");
	check(m.hid().mount_mouse(), "mounted again");
	t = m.take();
	check(is(t, 1, 0, 0, 0, 0, 0), "mounted again: MOUNTED, not decoded until its first report (%s)", show(t).c_str());

	m.report(0x02, 5, 5);
	m.t.core.reset();
	r = m.t.cmd(0x0d, { 7 });
	check(r.data[1] == 0 && r.u16_at(15) == 0 && r.u16_at(17) == 0 && r.data[14] == 0, "a controller reset clears the interface, totals and buttons");
	check(is(m.take(), 0, 0, 0, 0, 0, 0), "and the pending motion");
}

//**************************************************************************
//  The controller latch (controller_latch_f310_report)
//**************************************************************************

struct pads
{
	rig t;
	hid_t &hid() { return t.core.hid(); }
	pads() { hid().mount(); }

	u8 value(unsigned port) { return hid().latch().value(port); }
	// An F310 DirectInput report: left stick, right stick, hat | X A B Y, shoulder/system.
	void send(unsigned slot, u8 hat_buttons, u8 system, u8 lx = 0x80, u8 ly = 0x80, u32 now = 0)
	{
		u8 const r[8] = { lx, ly, 0x80, 0x80, hat_buttons, system, 0, 0 };
		hid().gamepad_report(slot, r, 8, now);
	}
};

constexpr u8 NEUTRAL = 0x08; // no hat direction
constexpr u8 BTN_X = 0x10, BTN_A = 0x20, BTN_B = 0x40, BTN_Y = 0x80;
constexpr u8 SYS_BACK = 0x10, SYS_START = 0x20;

// The hat's eight directions and the left stick: the bits that go low.
void latch_directions()
{
	pads p;
	u8 address;
	check(p.hid().mount_pad(address) == 0, "the first pad takes slot 0");
	check(p.value(0) == 0x7f && p.value(1) == 0x7f, "mounted and idle: 7Fh (D7 low, D6:D4 high, no direction)");
	// controller_latch_f310_report: 0 up, 1 up+right, 2 right, 3 right+down, 4 down, 5 down+left, 6 left, 7 left+up.
	struct { u8 hat; u8 want; } const hat[] = {
		{ 0, 0x7e }, { 1, 0x7c }, { 2, 0x7d }, { 3, 0x79 }, { 4, 0x7b }, { 5, 0x73 }, { 6, 0x77 }, { 7, 0x76 }, { 8, 0x7f }, { 15, 0x7f },
	};
	for (auto const &h : hat)
	{
		p.send(0, h.hat, 0);
		check(p.value(0) == h.want, "hat %u: %02X, want %02X", h.hat, p.value(0), h.want);
	}
	// The stick (hat neutral): below 40h or above C0h is a direction; the dead zone is exclusive.
	struct { u8 lx, ly, want; } const stick[] = {
		{ 0x3f, 0x80, 0x77 }, { 0x40, 0x80, 0x7f }, { 0xc0, 0x80, 0x7f }, { 0xc1, 0x80, 0x7d },
		{ 0x80, 0x3f, 0x7e }, { 0x80, 0x40, 0x7f }, { 0x80, 0xc0, 0x7f }, { 0x80, 0xc1, 0x7b },
		{ 0x00, 0x00, 0x76 }, { 0xff, 0xff, 0x79 }, { 0xff, 0x00, 0x7c }, { 0x00, 0xff, 0x73 }, { 0x80, 0x80, 0x7f },
	};
	for (auto const &s : stick)
	{
		p.send(0, NEUTRAL, 0, s.lx, s.ly);
		check(p.value(0) == s.want, "stick %02X,%02X: %02X, want %02X", s.lx, s.ly, p.value(0), s.want);
	}
	// A hat direction outranks the stick.
	p.send(0, 4, 0, 0x00, 0x00);
	check(p.value(0) == 0x7b, "hat down with the stick up-left: down only (%02X)", p.value(0));
	// Fire: A or B (D6 low), either, both.
	p.send(0, NEUTRAL | BTN_A, 0);
	check(p.value(0) == 0x3f, "A: fire (%02X)", p.value(0));
	p.send(0, NEUTRAL | BTN_B, 0);
	check(p.value(0) == 0x3f, "B: fire (%02X)", p.value(0));
	p.send(0, 0 | BTN_A | BTN_B, 0);
	check(p.value(0) == 0x3e, "A and B with the hat up: fire and up (%02X)", p.value(0));
	// L3, R3, bumpers, triggers and the right stick change nothing.
	u8 const other[8] = { 0x80, 0x80, 0x00, 0xff, NEUTRAL, 0xcf, 0, 0 };
	p.hid().gamepad_report(0, other, 8, 0);
	check(p.value(0) == 0x7f, "LB RB LT RT L3 R3 and the right stick: idle (%02X)", p.value(0));
	// Short and bad reports.
	p.send(0, NEUTRAL | BTN_A, 0);
	u8 const six[6] = { 0x80, 0x80, 0x80, 0x80, NEUTRAL, 0 };
	p.hid().gamepad_report(0, six, 6, 0);
	check(p.value(0) == 0x7f, "a six-byte report is decoded (back to idle, %02X)", p.value(0));
	p.send(0, NEUTRAL | BTN_A, 0);
	p.hid().gamepad_report(0, six, 5, 0);
	check(p.value(0) == 0x3f, "a five-byte report is refused: the latch is unchanged (%02X)", p.value(0));
}

// The keypad substitutes outrank the hat and the stick, in the firmware's
// order; fire stays on D6.
void latch_keypad_pad()
{
	pads p;
	u8 address;
	p.hid().mount_pad(address);
	struct { u8 hat_buttons, system, want; char const *what; } const rows[] = {
		{ NEUTRAL | BTN_X, 0, 0x7d, "X: keypad 1" },
		{ NEUTRAL | BTN_Y, 0, 0x77, "Y: keypad 2" },
		{ NEUTRAL, SYS_BACK, 0x79, "Back: star" },
		{ NEUTRAL, SYS_START, 0x76, "Start: pound" },
		{ NEUTRAL | BTN_X | BTN_Y, 0, 0x7d, "X over Y" },
		{ NEUTRAL | BTN_X, SYS_START, 0x76, "Start over X" },
		{ NEUTRAL | BTN_X, SYS_BACK | SYS_START, 0x79, "Back over Start and X" },
		{ 0 | BTN_X, 0, 0x7d, "X over a hat up" },
		{ NEUTRAL | BTN_X | BTN_A, 0, 0x3d, "X with A: keypad 1 and the second fire" },
		{ NEUTRAL | BTN_Y | BTN_B, 0, 0x37, "Y with B: keypad 2 and fire" },
		{ NEUTRAL, SYS_BACK | 0x4f, 0x79, "Back with the other buttons" },
	};
	for (auto const &r : rows)
	{
		p.send(0, r.hat_buttons, r.system);
		check(p.value(0) == r.want, "%s: %02X, want %02X", r.what, p.value(0), r.want);
	}
	p.send(0, NEUTRAL | BTN_X, 0, 0x00, 0x00);
	check(p.value(0) == 0x7d, "X over the stick: keypad 1 (%02X)", p.value(0));
	// D7 is low in every value.
	for (unsigned hat = 0; hat < 16; hat++)
		for (unsigned buttons = 0; buttons < 16; buttons++)
		{
			p.send(0, u8(hat | (buttons << 4)), u8(buttons << 4), 0x00, 0xff);
			if (p.value(0) & 0x80)
				check(false, "D7 high at hat %u buttons %u (%02X)", hat, buttons, p.value(0));
		}
	check(true, "D7 low for every hat and button combination");
}

//**************************************************************************
//  The keyboard's number keys on port 0 (coleco_keypad_for_report)
//**************************************************************************

void keypad_keyboard()
{
	pads p;
	auto key = [&p] (u8 mods, std::initializer_list<u8> keys)
	{
		u8 r[8] = { mods, 0 };
		unsigned i = 2;
		for (u8 k : keys)
			r[i++] = k;
		p.hid().report(r, 8, 0);
	};
	// coleco_keypad_nibble, indexed 0-9 then * and #; number row 1e-27h, keypad 59-62h.
	static constexpr u8 NIB[12] = { 0x0a, 0x0d, 0x07, 0x0c, 0x02, 0x03, 0x0e, 0x05, 0x01, 0x0b, 0x09, 0x06 };
	for (unsigned d = 0; d < 10; d++)
	{
		u8 const row = d == 0 ? 0x27 : u8(0x1e + d - 1), pad = d == 0 ? 0x62 : u8(0x59 + d - 1);
		key(0, { row });
		check(p.value(0) == u8(0x70 | NIB[d]), "number row %u: %02X, want %02X", d, p.value(0), 0x70 | NIB[d]);
		key(0, {});
		check(p.value(0) == 0x7f, "released: the directions park idle (%02X)", p.value(0));
		key(0, { pad });
		check(p.value(0) == u8(0x70 | NIB[d]), "keypad %u: %02X", d, p.value(0));
		key(0, {});
	}
	key(0, { 0x55 });
	check(p.value(0) == 0x79, "keypad *: star (%02X)", p.value(0));
	key(0, {});
	key(0x02, { 0x25 });
	check(p.value(0) == 0x79, "Shift+8: star (%02X)", p.value(0));
	key(0, {});
	key(0x02, { 0x20 });
	check(p.value(0) == 0x76, "Shift+3: pound (%02X)", p.value(0));
	key(0, {});
	key(0x02, { 0x1e });
	check(p.value(0) == 0x7f, "Shift+1 (a shifted digit that is not * or #): no keypad key (%02X)", p.value(0));
	key(0, {});
	key(0x02, { 0x59 });
	check(p.value(0) == 0x7f, "Shift + keypad 1: no key (%02X)", p.value(0));
	key(0, {});
	key(0, { 0x04, 0x1f });
	check(p.value(0) == 0x77, "a letter then 2: the first matching slot (keypad 2) (%02X)", p.value(0));
	key(0, { 0x1e, 0x1f });
	check(p.value(0) == 0x7d, "1 and 2 together: the first slot wins (%02X)", p.value(0));
	key(0, {});
	check(p.value(1) == 0x7f, "port 1 never takes the keyboard's keys (%02X)", p.value(1));
	// The digits still reach the console queue: the mirror consumes nothing.
	check(p.hid().queued() > 0, "the digits were also translated for the console (%u queued)", p.hid().queued());
	// The reset combination returns before the mirror.
	key(0, {});
	key(0x01 | 0x04, { 0x1e, 0x29 });
	check(p.value(0) == 0x7f && p.hid().reset_requested(), "Ctrl+Alt+Esc with a digit: the report is not taken (%02X)", p.value(0));
}

// A keypad key held on the keyboard outranks the stick on every pad report;
// releasing it parks the directions idle until the next pad report.
void keypad_overlap()
{
	pads p;
	u8 address;
	p.hid().mount_pad(address);
	u8 const key5[8] = { 0, 0, 0x22, 0, 0, 0, 0, 0 };
	u8 const none[8] = { 0 };
	// Keyboard digit on a port with a pad holding fire and a direction: the nibble
	// is the key's, the high bits are the pad's.
	p.send(0, 1 | BTN_A, 0);
	check(p.value(0) == 0x3c, "pad: up-right with A");
	p.hid().report(key5, 8, 0);
	check(p.value(0) == 0x33, "key 5 held: keypad nibble 3, the pad's fire kept (%02X)", p.value(0));
	p.send(0, 1 | BTN_A, 0);
	check(p.value(0) == 0x33, "the next pad report does not wipe the code (%02X)", p.value(0));
	p.send(0, 4, 0, 0x00, 0x00);
	check(p.value(0) == 0x73, "a different pad direction: still the key's nibble (%02X)", p.value(0));
	p.hid().report(none, 8, 0);
	check(p.value(0) == 0x7f, "key released: the directions park idle, fire gone with the pad's last value (%02X)", p.value(0));
	p.send(0, 4, 0);
	check(p.value(0) == 0x7b, "the next pad report restores the pad (%02X)", p.value(0));
	// A keypad key from the keyboard works with no pad attached.
	pads q;
	q.hid().report(key5, 8, 0);
	check(q.value(0) == 0x73 && q.value(1) == 0x7f, "no pad: the keyboard digit alone (%02X, port 1 %02X)", q.value(0), q.value(1));
}

//**************************************************************************
//  Pad slots, mount order and removal (tuh_hid_mount_cb, gamepad_unmount)
//**************************************************************************

void pad_slots()
{
	pads p;
	u8 a0, a1, a2;
	check(p.hid().mount_pad(a0) == 0 && a0 == 2, "first pad: slot 0, address 2");
	check(p.hid().mount_pad(a1) == 1 && a1 == 3, "second pad: slot 1, address 3");
	check(p.hid().mount_pad(a2) == hid_t::GAMEPAD_NONE, "a third F310 finds no slot");
	p.send(0, 2, 0);
	p.send(1, 6 | BTN_A, 0);
	check(p.value(0) == 0x7d && p.value(1) == 0x37, "two pads are independent: right on 0 (%02X), left+fire on 1 (%02X)", p.value(0), p.value(1));
	p.send(1, NEUTRAL, 0);
	check(p.value(0) == 0x7d && p.value(1) == 0x7f, "releasing pad 1 leaves pad 0");
	p.hid().unmount_pad(0);
	check(p.value(0) == 0x7f && !p.hid().pad_mounted(0) && p.hid().pad_mounted(1), "pad 0 removed: its latch parks at 7Fh, pad 1 stays slot 1");
	p.send(1, 4, 0);
	check(p.value(1) == 0x7b, "the remaining pad is still slot 1");
	u8 again;
	check(p.hid().mount_pad(again) == 0 && again == 2, "a pad plugged in later takes the free slot 0 (address 2)");
	// A report for an unmounted slot does nothing.
	p.hid().unmount_pad(0);
	p.send(0, 0, 0);
	check(p.value(0) == 0x7f, "a report for an empty slot is ignored");
	// Removal leaves a held keypad code (the firmware only parks the value).
	pads k;
	u8 addr;
	k.hid().mount_pad(addr);
	u8 const key7[8] = { 0, 0, 0x24, 0, 0, 0, 0, 0 };
	k.hid().report(key7, 8, 0);
	check(k.value(0) == 0x75, "key 7 on port 0");
	k.hid().unmount_pad(0);
	check(k.value(0) == 0x7f, "the pad leaving parks the port at 7Fh (%02X) while the key is held", k.value(0));
	u8 const none[8] = { 0 };
	k.hid().report(none, 8, 0);
	check(k.value(0) == 0x7f, "and the release finds nothing to change");
	// A controller reset: idle latches, no pads, no keypad key.
	pads r;
	r.hid().mount_pad(addr);
	r.send(0, 0 | BTN_A, 0);
	r.hid().report(key7, 8, 0);
	r.t.core.reset();
	check(r.value(0) == 0x7f && r.value(1) == 0x7f && !r.hid().pad_mounted(0), "reset: latches idle, pads gone");
	r.hid().mount();
	r.hid().report(none, 8, 0);
	check(r.value(0) == 0x7f, "and no keypad code survives");
}

// The pad poll cadence (hid_host_task): due at once after a mount, then
// GAMEPAD_POLL_MS after each report.
void pad_polls()
{
	pads p;
	u32 due = 0;
	check(!p.hid().gamepad_next_due(due), "no pad: no poll");
	u8 address;
	p.hid().mount_pad(address);
	check(p.hid().gamepad_due(0, 0) && p.hid().gamepad_next_due(due) && due == 0, "mounted: polled at once");
	p.send(0, NEUTRAL, 0, 0x80, 0x80, 1230);
	check(!p.hid().gamepad_due(0, 1239) && p.hid().gamepad_due(0, 1240) && p.hid().gamepad_next_due(due) && due == 1240,
			"the next poll is 10 ms after the report's clock");
	check(p.hid().gamepad_due(0, 5000), "and stays due while the controller was busy");
	u8 second;
	p.hid().mount_pad(second);
	p.send(1, NEUTRAL, 0, 0x80, 0x80, 1235);
	check(p.hid().gamepad_next_due(due) && due == 1240, "the earliest of the two pads");
	p.send(0, NEUTRAL, 0, 0x80, 0x80, 1240);
	check(p.hid().gamepad_next_due(due) && due == 1245, "then the other pad's");
}

// HID_STATUS page 6 (handler_hid_gamepad_page): the live devices and each
// slot's address, report count, length and latch.
void pad_status()
{
	pads p;
	reply_t r = p.t.cmd(0x0d, { 6 });
	check(r.data.size() == 26 && r.data[0] == 6 && r.data[1] == 1 && r.data[2] == 1 && r.data[3] == 0 && r.data[4] == 1 &&
			r.u16_at(5) == 0xffff && r.u16_at(7) == 0xffff && r.data[9] == 1 && r.data[10] == 1 && r.data[25] == 1,
			"keyboard only: 1 device (address 1, VID/PID unknown), 1 mount, 1 HID mount of protocol 1 (%s)", show(r.data).c_str());
	check(r.data[11] == 0 && r.data[13] == 0xff && r.data[17] == 0x7f && r.data[18] == 0 && r.data[20] == 0xff && r.data[24] == 0x7f,
			"both slots empty: address 0, first arm FFh, latch 7Fh");
	u8 a;
	p.hid().mount_pad(a);
	p.send(0, 2 | BTN_A, 0);
	p.send(0, NEUTRAL, 0);
	r = p.t.cmd(0x0d, { 6 });
	check(r.data[1] == 2 && r.data[2] == 2 && r.data[4] == 2 && r.u16_at(5) == 0x046d && r.u16_at(7) == 0xc216 && r.data[9] == 2 && r.data[10] == 2 && r.data[25] == 0,
			"one pad: 2 devices, last address 2, VID 046D PID C216, protocol 0 (%s)", show(r.data).c_str());
	check(r.data[11] == 2 && r.data[12] == 0 && r.data[13] == 1 && r.u16_at(14) == 2 && r.data[16] == 8 && r.data[17] == 0x7f &&
			r.data[18] == 0 && r.data[20] == 0xff,
			"slot 0: address 2, instance 0, first arm 1, 2 reports of 8 bytes, latch 7F; slot 1 empty (%s)", show(r.data).c_str());
	u8 b;
	p.hid().mount_pad(b);
	p.send(1, 4, 0);
	p.hid().unmount_pad(0);
	r = p.t.cmd(0x0d, { 6 });
	check(r.data[1] == 1 && r.data[2] == 3 && r.data[3] == 1 && r.data[4] == 1,
			"pad 0 removed: 1 live device in the stack's two addresses (the dongle; address 3 is past them), 3 mounts, 1 unmount (%s)", show(r.data).c_str());
	check(r.data[11] == 0 && r.data[13] == 0xff && r.data[18] == 3 && r.data[20] == 1 && r.data[24] == 0x7b,
			"slot 0 empty again, slot 1 address 3 with its latch 7B");
}

//**************************************************************************
//  Save registration (the HID module's items)
//**************************************************************************

void save_registration()
{
	fake_link link;
	hid_t hid(link);
	unsigned items = 0;
	hid.save_state([&items] (auto &&...) { items++; });
	// The 16 keyboard items, 9 device counters, 5 pad arrays, the latch's 2,
	// the second interface's 4, the mouse's totals and decode 5 and pending 4.
	check(items == 45, "keyboard, device counters, pad slots, latch, second interface and mouse registered (%u items)", items);
	latch_t latch;
	unsigned latch_items = 0;
	latch.save_state([&latch_items] (auto &&...) { latch_items++; });
	check(latch_items == 2, "the latch registers its values and keypad codes (%u)", latch_items);
}

} // anonymous namespace

int main()
{
	std::vector<test> const tests = {
		{ "mouse-flags", mouse_flags },
		{ "mouse-accumulation", mouse_accumulation },
		{ "mouse-saturation", mouse_saturation },
		{ "mouse-totals", mouse_totals },
		{ "mouse-lifecycle", mouse_lifecycle },
		{ "latch-directions", latch_directions },
		{ "latch-keypad-pad", latch_keypad_pad },
		{ "keypad-keyboard", keypad_keyboard },
		{ "keypad-overlap", keypad_overlap },
		{ "pad-slots", pad_slots },
		{ "pad-polls", pad_polls },
		{ "pad-status", pad_status },
		{ "save-state", save_registration },
	};
	return run_tests(tests);
}
