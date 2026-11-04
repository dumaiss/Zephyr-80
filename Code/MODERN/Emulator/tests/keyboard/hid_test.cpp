// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: the IO controller's keyboard input (zephyr80_ioc_hid) through
// the protocol core: boot reports in, HID_INPUT and HID_STATUS frames out
// (tests/ioc_core/rig.h).  Every expected byte, count and time is the
// firmware's (Code/MCU/IOController src/ioc_hid.c translate_key,
// tuh_hid_report_received_cb, hid_host_task, input_reserve; src/handlers.c
// handler_hid_input, handler_hid_status), cited per test.
#include "rig.h"
#include "memory_storage.h"

#include <algorithm>
#include <cstring>

namespace {

using rig = rig_t<memory_storage>;

// HID usages (TinyUSB class/hid/hid.h) and modifier bits.
enum : u8
{
	A = 0x04, B = 0x05, C = 0x06, L = 0x0f, X = 0x1b, Z = 0x1d,
	N1 = 0x1e, N2 = 0x1f, N3 = 0x20, N6 = 0x23, N0 = 0x27,
	ENTER = 0x28, ESC = 0x29, BKSP = 0x2a, TAB = 0x2b, SPACE = 0x2c, MINUS = 0x2d, EQUAL = 0x2e,
	LBRACKET = 0x2f, RBRACKET = 0x30, BACKSLASH = 0x31, EUROPE1 = 0x32, SEMICOLON = 0x33, QUOTE = 0x34,
	GRAVE = 0x35, COMMA = 0x36, PERIOD = 0x37, SLASH = 0x38, CAPS = 0x39,
	F1 = 0x3a, F4 = 0x3d, F5 = 0x3e, F6 = 0x3f, F10 = 0x43, F11 = 0x44, F12 = 0x45,
	PRINT = 0x46, SCROLL = 0x47, PAUSE = 0x48, INSERT = 0x49, HOME = 0x4a, PGUP = 0x4b, DEL = 0x4c, END = 0x4d,
	PGDN = 0x4e, RIGHT = 0x4f, LEFT = 0x50, DOWN = 0x51, UP = 0x52, NUMLOCK = 0x53,
	KP_DIV = 0x54, KP_MUL = 0x55, KP_SUB = 0x56, KP_ADD = 0x57, KP_ENTER = 0x58,
	KP1 = 0x59, KP2 = 0x5a, KP3 = 0x5b, KP4 = 0x5c, KP5 = 0x5d, KP6 = 0x5e, KP7 = 0x5f, KP8 = 0x60, KP9 = 0x61,
	KP0 = 0x62, KP_DOT = 0x63, EUROPE2 = 0x64, APP = 0x65, KP_EQUAL = 0x67,
};
enum : u8 { LCTRL = 0x01, LSHIFT = 0x02, LALT = 0x04, LGUI = 0x08, RCTRL = 0x10, RSHIFT = 0x20, RALT = 0x40 };

using hid_t = zephyr80_ioc_hid;

struct kbd
{
	rig t;
	u32 now = 0;
	kbd() { t.core.hid().mount(); }
	hid_t &hid() { return t.core.hid(); }

	void report(u8 mods, std::initializer_list<u8> keys)
	{
		u8 r[8] = { mods, 0 };
		unsigned i = 2;
		for (u8 k : keys)
			r[i++] = k;
		hid().report(r, 8, now);
		hid().task(now);
	}
	// Press and release one key with `mods` held throughout.
	void tap(u8 mods, u8 key)
	{
		report(mods, { key });
		report(mods, {});
	}
	// Everything queued, through HID_INPUT as handler_hid_input answers it.
	bytes drain()
	{
		bytes all;
		for (;;)
		{
			reply_t r = t.cmd(0x0e, { 24 });
			check(r.cls == 0x8e && r.status == 0 && r.data.size() >= 2, "HID_INPUT reply");
			all.insert(all.end(), r.data.begin() + 2, r.data.end());
			if (r.data[0] == 0)
				return all;
		}
	}
	// Advance the controller's clock to `ms` in 10 ms ticks, running the
	// idle pass's repeat at each.
	void run_to(u32 ms)
	{
		while (now < ms)
		{
			now += hid_t::TICK_MS;
			hid().task(now);
		}
	}
};

std::string show(bytes const &b)
{
	std::string s;
	char hex[4];
	for (u8 v : b)
	{
		std::snprintf(hex, sizeof hex, "%02X ", v);
		s += hex;
	}
	return s;
}

bytes str(char const *s) { return bytes(s, s + std::strlen(s)); }

//**************************************************************************
//  translate_key
//**************************************************************************

struct vector_t
{
	u8 mods;
	u8 key;
	bytes want;
};

void translation()
{
	// HID_KEYCODE_TO_ASCII: letters, digits and punctuation, plain and with
	// either Shift (Alt and GUI change nothing).
	std::vector<vector_t> vectors;
	for (u8 k = A; k <= Z; k++)
	{
		vectors.push_back({ 0, k, { u8('a' + k - A) } });
		vectors.push_back({ LSHIFT, k, { u8('A' + k - A) } });
		vectors.push_back({ RSHIFT, k, { u8('A' + k - A) } });
		vectors.push_back({ LALT, k, { u8('a' + k - A) } });
		vectors.push_back({ LGUI, k, { u8('a' + k - A) } });
	}
	char const *digits = "1234567890", *shifted = "!@#$%^&*()";
	for (unsigned i = 0; i < 10; i++)
	{
		vectors.push_back({ 0, u8(N1 + i), { u8(digits[i]) } });
		vectors.push_back({ LSHIFT, u8(N1 + i), { u8(shifted[i]) } });
	}
	struct { u8 key; char plain, shift; } const punct[] = {
		{ MINUS, '-', '_' }, { EQUAL, '=', '+' }, { LBRACKET, '[', '{' }, { RBRACKET, ']', '}' },
		{ BACKSLASH, '\\', '|' }, { EUROPE1, '#', '~' }, { SEMICOLON, ';', ':' }, { QUOTE, '\'', '"' },
		{ GRAVE, '`', '~' }, { COMMA, ',', '<' }, { PERIOD, '.', '>' }, { SLASH, '/', '?' },
	};
	for (auto const &p : punct)
	{
		vectors.push_back({ 0, p.key, { u8(p.plain) } });
		vectors.push_back({ LSHIFT, p.key, { u8(p.shift) } });
	}
	// Control and editing keys of the table, unchanged by Shift.
	for (u8 m : { u8(0), u8(LSHIFT) })
	{
		vectors.push_back({ m, ENTER, { 0x0d } });
		vectors.push_back({ m, ESC, { 0x1b } });
		vectors.push_back({ m, BKSP, { 0x08 } });
		vectors.push_back({ m, TAB, { 0x09 } });
		vectors.push_back({ m, SPACE, { 0x20 } });
	}
	// Ctrl (either): letters to 01h-1Ah, [ \ ] 6 - to 1Bh-1Fh, 2 and Space to
	// NUL; any other key falls through to the table.
	for (u8 k = A; k <= Z; k++)
	{
		vectors.push_back({ LCTRL, k, { u8(k - A + 1) } });
		vectors.push_back({ u8(RCTRL | LSHIFT), k, { u8(k - A + 1) } });
	}
	vectors.push_back({ LCTRL, LBRACKET, { 0x1b } });
	vectors.push_back({ LCTRL, BACKSLASH, { 0x1c } });
	vectors.push_back({ LCTRL, RBRACKET, { 0x1d } });
	vectors.push_back({ LCTRL, N6, { 0x1e } });
	vectors.push_back({ LCTRL, MINUS, { 0x1f } });
	vectors.push_back({ LCTRL, N2, { 0x00 } });
	vectors.push_back({ RCTRL, SPACE, { 0x00 } });
	vectors.push_back({ LCTRL, N1, { '1' } });
	vectors.push_back({ LCTRL, ENTER, { 0x0d } });
	vectors.push_back({ LCTRL, ESC, { 0x1b } });
	vectors.push_back({ LCTRL, UP, str("\x1b[A") });
	// Navigation: CSI letters, CSI n ~; function keys SS3 P-S and CSI n ~.
	vectors.push_back({ 0, UP, str("\x1b[A") });
	vectors.push_back({ 0, DOWN, str("\x1b[B") });
	vectors.push_back({ 0, RIGHT, str("\x1b[C") });
	vectors.push_back({ 0, LEFT, str("\x1b[D") });
	vectors.push_back({ LSHIFT, LEFT, str("\x1b[D") });
	vectors.push_back({ 0, HOME, str("\x1b[H") });
	vectors.push_back({ 0, END, str("\x1b[F") });
	vectors.push_back({ 0, INSERT, str("\x1b[2~") });
	vectors.push_back({ 0, DEL, str("\x1b[3~") });
	vectors.push_back({ 0, PGUP, str("\x1b[5~") });
	vectors.push_back({ 0, PGDN, str("\x1b[6~") });
	char const *ss3 = "PQRS";
	for (unsigned i = 0; i < 4; i++)
		vectors.push_back({ 0, u8(F1 + i), { 0x1b, 'O', u8(ss3[i]) } });
	char const *fn[] = { "15", "17", "18", "19", "20", "21", "23", "24" };
	for (unsigned i = 0; i < 8; i++)
		vectors.push_back({ 0, u8(F5 + i), cat({ str("\x1b["), str(fn[i]), str("~") }) });
	// The keypad with NumLock on (the power-on state): the table's digits,
	// Shift giving a zero entry, so the switch's digit; operators and Enter.
	char const *kp = "1234567890.";
	for (unsigned i = 0; i < 11; i++)
	{
		vectors.push_back({ 0, u8(KP1 + i), { u8(kp[i]) } });
		vectors.push_back({ LSHIFT, u8(KP1 + i), { u8(kp[i]) } });
	}
	vectors.push_back({ 0, KP_DIV, { '/' } });
	vectors.push_back({ 0, KP_MUL, { '*' } });
	vectors.push_back({ 0, KP_SUB, { '-' } });
	vectors.push_back({ 0, KP_ADD, { '+' } });
	vectors.push_back({ 0, KP_ENTER, { 0x0d } });
	vectors.push_back({ 0, KP_EQUAL, { '=' } });
	// Keys the firmware does not translate.
	for (u8 k : { PRINT, SCROLL, PAUSE, EUROPE2, APP })
		vectors.push_back({ 0, k, {} });

	unsigned failed = 0;
	for (auto const &v : vectors)
	{
		kbd k;
		k.tap(v.mods, v.key);
		bytes const got = k.drain();
		if (got != v.want)
		{
			failed++;
			check(false, "mods %02X usage %02X: got %s want %s", v.mods, v.key, show(got).c_str(), show(v.want).c_str());
		}
	}
	check(failed == 0, "%zu translation vectors", vectors.size());
	std::printf("  %zu translation vectors, %u failed\n", vectors.size(), failed);

	// NumLock off: the keypad's navigation layer first, 5 from the table.
	kbd k;
	k.tap(0, NUMLOCK);
	check(!k.hid().num_lock() && k.drain().empty(), "NumLock toggles off and queues nothing");
	struct { u8 key; char const *want; } const nav[] = {
		{ KP7, "\x1b[H" }, { KP8, "\x1b[A" }, { KP9, "\x1b[5~" }, { KP4, "\x1b[D" }, { KP6, "\x1b[C" },
		{ KP1, "\x1b[F" }, { KP2, "\x1b[B" }, { KP3, "\x1b[6~" }, { KP0, "\x1b[2~" }, { KP_DOT, "\x1b[3~" },
		{ KP5, "5" },
	};
	for (auto const &n : nav)
	{
		k.tap(0, n.key);
		bytes const got = k.drain();
		check(got == str(n.want), "NumLock off, usage %02X: %s", n.key, show(got).c_str());
	}
	k.tap(0, NUMLOCK);
	k.tap(0, KP8);
	check(k.hid().num_lock() && k.drain() == str("8"), "NumLock on again: the digit");

	// CapsLock: letters only, inverted by Shift; digits unaffected.
	kbd c;
	c.tap(0, CAPS);
	c.tap(0, A);
	c.tap(LSHIFT, A);
	c.tap(0, N1);
	check(c.hid().caps_lock() && c.drain() == str("Aa1"), "CapsLock: A, Shift a, 1");
	c.tap(0, CAPS);
	c.tap(0, A);
	check(!c.hid().caps_lock() && c.drain() == str("a"), "CapsLock off again");
}

//**************************************************************************
//  Report edges (tuh_hid_report_received_cb)
//**************************************************************************

void report_edges()
{
	kbd k;
	k.report(0, { A });
	k.report(0, { A });            // a repeated report: nothing new
	k.report(0, { A, B });         // B new, A held
	k.report(0, { B });            // A released
	k.report(0, { B, C, X });      // two new, in slot order
	check(k.drain() == str("abcx"), "only newly pressed usages translate, in slot order");
	k.report(0, {});
	k.report(0, { 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 }); // ErrorRollOver
	k.report(0, { 0x02, 0x03 });
	u32 due;
	check(k.drain().empty() && !k.hid().repeat_due(due), "usages 01h-03h never translate nor repeat");
	k.report(0, { A, B });
	k.report(0, { 0x01, 0x01, 0x01, 0x01, 0x01, 0x01 });
	k.report(0, { A, B });
	check(k.drain() == str("abab"), "keys reported again after a rollover are new presses");
	// A modifier change alone translates nothing.
	k.report(0, {});
	k.report(LSHIFT, {});
	k.report(0, {});
	check(k.drain().empty(), "modifier-only reports queue nothing");
	// Shift applies per report: the modifier byte of the report the key is new in.
	k.report(LSHIFT, { A });
	k.report(0, { A, B });
	check(k.drain() == str("Ab"), "each new key takes its report's modifiers");
	// Not mounted: reports are not the keyboard's.
	kbd u;
	u.hid().unmount();
	u.report(0, { A });
	check(u.drain().empty() && u.hid().report_count() == 0, "no keyboard mounted: reports ignored");
}

//**************************************************************************
//  Lock keys and the LED report
//**************************************************************************

void locks()
{
	kbd k;
	check(!k.hid().caps_lock() && k.hid().num_lock() && k.hid().leds() == hid_t::LED_NUM_LOCK,
			"mount: CapsLock off, NumLock on, LED report NumLock (tuh_hid_mount_cb)");
	k.report(0, { CAPS });
	check(k.hid().caps_lock() && k.hid().leds() == (hid_t::LED_NUM_LOCK | hid_t::LED_CAPS_LOCK), "CapsLock on: both LEDs");
	k.report(0, { CAPS });         // still held: no second toggle
	k.run_to(3000);                // a held lock key never repeats
	check(k.hid().caps_lock(), "a held CapsLock toggles once and does not repeat");
	k.report(0, {});
	k.report(0, { NUMLOCK });
	k.report(0, {});
	check(!k.hid().num_lock() && k.hid().leds() == hid_t::LED_CAPS_LOCK, "NumLock off: CapsLock LED only");
	k.report(0, { SCROLL });
	k.run_to(6000);
	check(k.drain().empty(), "Scroll Lock: nothing, no repeat");
	k.hid().mount();
	check(!k.hid().caps_lock() && k.hid().num_lock() && k.hid().leds() == hid_t::LED_NUM_LOCK, "a new mount resets the locks");
}

//**************************************************************************
//  Repeat (hid_host_task)
//**************************************************************************

void repeat()
{
	// Pressed at 1000 ms: due at 1500, then every 60 ms after the tick it
	// fired at.
	kbd k;
	k.now = 1000;
	k.report(0, { X });
	k.run_to(1490);
	check(k.drain() == str("x"), "the press, nothing before REPEAT_DELAY_MS");
	k.run_to(1500);
	check(k.drain() == str("x"), "first repeat at press + 500 ms");
	k.run_to(1550);
	check(k.drain().empty(), "nothing 50 ms later");
	k.run_to(1560);
	check(k.drain() == str("x"), "second repeat 60 ms after the first");
	k.run_to(1560 + 60 * 10);
	check(k.drain() == bytes(10, 'x'), "ten more at 60 ms");
	// A late idle pass (a service held the controller 30 ms past the due
	// tick 2220): the next period counts from the tick it ran at.
	u32 const late = 2220 + 30;
	k.now = late;
	k.hid().task(k.now);
	check(k.drain() == str("x"), "a late pass repeats once");
	u32 due = 0;
	check(k.hid().repeat_due(due) && due == late + 60, "re-armed 60 ms after the late tick (%u, want %u)", due, late + 60);
	// Release ends it.
	k.report(0, {});
	k.run_to(late + 2000);
	check(k.drain().empty() && !k.hid().repeat_due(due), "release: no repeat");

	// A newly pressed key takes over and restarts the delay; releasing the
	// older key does not stop the newer one.
	kbd n;
	n.report(0, { A });
	n.run_to(700);                 // a: press, 500, 560, 620, 680
	n.report(0, { A, B });         // at 700: b, due 1200
	n.run_to(1190);
	n.report(0, { B });            // A released: B keeps repeating
	n.run_to(1260);
	bytes const takeover = n.drain();
	check(takeover == str("aaaaabbb"), "takeover: a's press and 4 repeats, b's press and 2 (%s)", show(takeover).c_str());
	// Shift pressed during the repeat: the modifiers are re-sampled.
	n.report(LSHIFT, { B });
	n.run_to(1320);
	n.report(0, { B });
	n.run_to(1380);
	check(n.drain() == str("Bb"), "Shift re-sampled mid-repeat");

	// Never more than half the queue: a held key with nothing draining stops
	// at 64 bytes and counts no drop; a 3-byte key may pass 64 once.
	kbd h;
	h.report(0, { X });
	h.run_to(20000);
	check(h.hid().queued() == 64 && h.hid().dropped() == 0, "held x, no drain: 64 queued, 0 dropped (%u, %u)",
			h.hid().queued(), h.hid().dropped());
	kbd a;
	a.report(0, { UP });
	a.run_to(20000);
	check(a.hid().queued() == 66 && a.hid().dropped() == 0, "held Up: 66 queued (63 < 64 admits one more), 0 dropped (%u)",
			a.hid().queued());
	// Draining lets it continue.
	bytes got = a.drain();
	check(got.size() == 66 && got[63] == 0x1b && got[65] == 'A', "the 22 sequences whole");
	a.run_to(20060);
	check(a.drain() == str("\x1b[A"), "drained: the repeat continues");
}

//**************************************************************************
//  The queue, the doorbell and HID_INPUT (handler_hid_input)
//**************************************************************************

void queue()
{
	kbd k;
	check(!k.t.link.doorbell, "empty: /CTSB released");
	k.tap(0, UP);
	check(k.t.link.doorbell && k.hid().queued() == 3, "a key: /CTSB asserted, 3 queued");
	k.tap(0, A);
	k.tap(LSHIFT, B);
	reply_t r = k.t.cmd(0x0e, { 2 });
	check(r.data.size() == 4 && r.data[0] == 3 && r.data[1] == 0 && r.data[2] == 0x1b && r.data[3] == '[',
			"partial dequeue of 2: ESC [, 3 left (%s)", show(r.data).c_str());
	check(k.t.link.doorbell, "/CTSB stays asserted after a partial dequeue");
	r = k.t.cmd(0x0e, { 0 });
	check(r.data.size() == 2 && r.data[0] == 3 && k.t.link.doorbell, "status-only query: 3 queued, nothing taken");
	r = k.t.cmd(0x0e, { 1 });
	check(r.data.size() == 3 && r.data[2] == 'A' && r.data[0] == 2, "one byte: the sequence's final");
	r = k.t.cmd(0x0e, { 200 });
	check(r.data.size() == 4 && r.data[0] == 0 && r.data[2] == 'a' && r.data[3] == 'B' && !k.t.link.doorbell,
			"drain (a request above 24 is capped): /CTSB released");
	k.tap(0, C);
	check(k.t.link.doorbell, "/CTSB asserted again by the next key");
	k.drain();

	// Overflow: a translation is admitted whole or refused with one drop.
	kbd f;
	for (unsigned i = 0; i < 42; i++)
		f.tap(0, DOWN);            // 126 bytes
	check(f.hid().queued() == 126, "42 arrows: 126 queued");
	f.tap(0, RIGHT);
	check(f.hid().queued() == 126 && f.hid().dropped() == 1, "a 3-byte key with 2 free: refused whole, 1 drop");
	f.tap(0, A);
	f.tap(0, B);
	check(f.hid().queued() == 128 && f.hid().dropped() == 1, "two letters fill the queue");
	f.tap(0, C);
	f.tap(0, F5);
	check(f.hid().queued() == 128 && f.hid().dropped() == 3, "full: a letter and F5 dropped");
	r = f.t.cmd(0x0e, { 24 });
	check(r.data.size() == 26 && r.data[0] == 104 && r.data[1] == 3 && r.data[2] == 0x1b, "24 per reply; queued 104, dropped 3");
	bytes rest = f.drain();
	check(rest.size() == 104 && rest[102] == 'a' && rest[103] == 'b', "the queue holds every admitted byte in order");
	for (unsigned i = 0; i < 300; i++)
		f.hid().put(bytes(129, 0).data(), 129);
	check(f.hid().dropped() == 0xff, "the drop count saturates at FFh");
	// Queue reset: the controller restarts with the board.
	f.tap(0, A);
	f.t.core.reset();
	r = f.t.cmd(0x0e, { 24 });
	check(r.data.size() == 2 && r.data[0] == 0 && r.data[1] == 0 && !f.t.link.doorbell, "reset: empty, no drops, /CTSB released");
}

//**************************************************************************
//  Ctrl+Alt+Esc (keyboard_reset_combo)
//**************************************************************************

void reset_combo()
{
	kbd k;
	k.report(LCTRL | LALT, { ESC });
	check(k.hid().reset_requested() && k.drain().empty(), "Ctrl+Alt+Esc: reset requested, no Escape queued");
	kbd r;
	r.report(RCTRL | RALT | LSHIFT, { A, ESC });
	check(r.hid().reset_requested() && r.drain().empty(), "right Ctrl + right Alt, Shift and another key: reset, nothing queued");
	check(r.hid().last_report()[2] == 0 && r.hid().report_count() == 0, "the combo's report is not taken (held state unchanged)");
	kbd e;
	e.report(LCTRL, { ESC });
	e.report(LALT, { ESC });
	check(!e.hid().reset_requested() && e.drain() == str("\x1b"), "Ctrl+Esc then Alt (Esc held): Escape once, no reset");
	r.t.core.reset();
	check(!r.hid().reset_requested(), "the controller's reset clears the request");
}

//**************************************************************************
//  HID_STATUS page 0 (handler_hid_status, hid_host_usb_state)
//**************************************************************************

void status()
{
	kbd k;
	reply_t r = k.t.cmd(0x0d, { 0 });
	check(r.data.size() == 26 && r.data[0] == 0 && r.data[1] == 0 && r.data[2] == 1,
			"bring-up fields: NOT_STARTED, revision 0, /USB_INT idle (no USB host controller modelled)");
	check(r.data[13] == 1 && r.data[14] == hid_t::KEYBOARD_ADDRESS && r.u16_at(15) == 0 && r.data[25] == 0x00,
			"keyboard mounted: 1 device, its address, 0 reports, full speed");
	k.report(LSHIFT, { A, B });
	k.report(0, {});
	r = k.t.cmd(0x0d, { 0 });
	check(r.u16_at(15) == 2 && std::all_of(r.data.begin() + 17, r.data.begin() + 25, [] (u8 b) { return b == 0; }),
			"2 reports; the last one (all released)");
	k.report(LCTRL, { C });
	r = k.t.cmd(0x0d, { 0 });
	check(r.u16_at(15) == 3 && r.data[17] == LCTRL && r.data[18] == 0 && r.data[19] == C, "the last report: Ctrl, 0, C");
	k.hid().unmount();
	r = k.t.cmd(0x0d, { 0 });
	check(r.data[13] == 0 && r.data[14] == 0 && r.u16_at(15) == 0 && r.data[25] == 0xff, "unmounted: none, speed FFh");
}

void save_registration()
{
	fake_link link;
	hid_t hid(link);
	unsigned items = 0;
	hid.save_state([&items] (auto &&...) { items++; });
	check(items == 16, "queue, held report, locks, repeat key/modifiers/due and reset request registered (%u items)", items);
}

} // anonymous namespace

int main()
{
	std::vector<test> const tests = {
		{ "translation", translation },
		{ "report-edges", report_edges },
		{ "locks", locks },
		{ "repeat", repeat },
		{ "queue", queue },
		{ "reset-combo", reset_combo },
		{ "status", status },
		{ "save-state", save_registration },
	};
	return run_tests(tests);
}
