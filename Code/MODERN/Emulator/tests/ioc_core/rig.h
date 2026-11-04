// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: the IOC protocol core driven as its transport drives it, for
// the host tests (ioc_core_test.cpp, ../card/card_test.cpp).  Each request is
// a complete A5 5A ... CRC packet inside a 36-byte command window; each
// reply is encoded, CRC-checked and decoded again; bulk transfers run as the
// transport runs them (the packet to the Z80 byte for byte, the window from
// the Z80 as the KonaOS write path fills it).
#ifndef ZEPHYR80_TESTS_IOC_CORE_RIG_H
#define ZEPHYR80_TESTS_IOC_CORE_RIG_H

#include "emu.h"
#include "zephyr80_ioc_core.h"

#include <cstdarg>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace {

using bytes = std::vector<u8>;
using core_t = zephyr80_ioc_core;
using bulk_dir = core_t::bulk_dir;

unsigned g_checks, g_failed, g_test_failed;

void check(bool ok, char const *format, ...)
{
	g_checks++;
	if (ok)
		return;
	g_failed++;
	g_test_failed++;
	va_list args;
	va_start(args, format);
	std::printf("  FAIL ");
	std::vprintf(format, args);
	std::printf("\n");
	va_end(args);
}

struct fake_link : core_t::link
{
	unsigned resyncs = 0;
	unsigned resets = 0;
	bool synced = true;
	bool doorbell = false;
	virtual void resync_lanes() override { resyncs++; }
	virtual bool command_lane_synced() const override { return synced; }
	virtual void hid_doorbell(bool asserted) override { doorbell = asserted; }
	virtual void host_reset() override { resets++; }
};

struct reply_t
{
	bool answered = false;
	u8 cls = 0, seq = 0, status = 0;
	bytes data;
	u32 u32_at(unsigned i) const { return data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (u32(data[i + 3]) << 24); }
	u16 u16_at(unsigned i) const { return data[i] | (data[i + 1] << 8); }
};

bytes packet(u8 type, u8 seq, bytes const &data, u8 status = 0)
{
	bytes p{ 0xa5, 0x5a, u8(3 + data.size()), u8((3 + data.size()) >> 8), type, seq, status };
	p.insert(p.end(), data.begin(), data.end());
	u16 crc = 0;
	for (size_t i = 2; i < p.size(); i++)
		crc = core_t::crc16(crc, p[i]);
	p.push_back(u8(crc >> 8));
	p.push_back(u8(crc));
	return p;
}

bytes name11(std::string const &base, std::string const &ext = "")
{
	bytes n(11, ' ');
	for (size_t i = 0; i < base.size() && i < 8; i++)
		n[i] = u8(base[i]);
	for (size_t i = 0; i < ext.size() && i < 3; i++)
		n[8 + i] = u8(ext[i]);
	return n;
}

bytes le16(u16 v) { return { u8(v), u8(v >> 8) }; }
bytes le32(u32 v) { return { u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }; }
bytes cat(std::initializer_list<bytes> parts)
{
	bytes out;
	for (auto const &p : parts)
		out.insert(out.end(), p.begin(), p.end());
	return out;
}
bytes pattern(size_t n, u8 seed)
{
	bytes b(n);
	for (size_t i = 0; i < n; i++)
		b[i] = u8(seed + i * 7 + (i >> 8));
	return b;
}

// The controller and its media, driven as the transport drives them.
template <typename Media>
struct rig_t
{
	fake_link link;
	Media media;
	core_t core{ link };
	u8 seq = 0;
	u8 last_type = 0;

	rig_t()
	{
		core.set_storage(media);
		core.reset();
	}

	// One service of a window: decode, dispatch, encode, and the reply
	// decoded back off the wire.
	reply_t serve(bytes window)
	{
		window.resize(36, 0xff);
		reply_t r;
		core.begin();
		core_t::frame request, reply;
		if (!core.decode(window.data(), unsigned(window.size()), request))
		{
			core.abort();
			end();
			return r;
		}
		if (!core.dispatch(request, reply))
			return r;
		u8 wire[core_t::MAX_WIRE];
		unsigned const n = core_t::encode(reply, wire);
		u16 crc = 0;
		for (unsigned i = 2; i < n - 2; i++)
			crc = core_t::crc16(crc, wire[i]);
		unsigned const length = wire[2] | (wire[3] << 8);
		check(wire[0] == 0xa5 && wire[1] == 0x5a && n == 2 + 2 + length + 2 && length >= 3 && length <= 29 &&
				crc == ((wire[n - 2] << 8) | wire[n - 1]), "reply wire form (%u bytes)", n);
		r.answered = true;
		r.cls = wire[4];
		r.seq = wire[5];
		r.status = wire[6];
		r.data.assign(wire + 7, wire + n - 2);
		if (core.bulk_armed() == bulk_dir::NONE)
			end();
		return r;
	}

	reply_t cmd(u8 type, bytes const &data = {})
	{
		++seq;
		last_type = type;
		reply_t r = serve(cat({ { 0xff }, packet(type, seq, data) }));
		check(r.answered && r.seq == seq, "class %02X: answered with its sequence", type);
		return r;
	}

	// The end of a service: main.c fs2_run_end, then the idle pass.
	void end()
	{
		core.run_end();
		core.idle();
	}

	// Transport, to the Z80: every packet of the armed transfer (a run's
	// packets in order), each checked as bulk_run_send builds it.
	std::vector<bytes> take(u8 type, u8 sequence)
	{
		std::vector<bytes> packets;
		while (core.bulk_armed() == bulk_dir::TO_Z80)
		{
			u8 wire[core_t::BULK_WIRE_MAX];
			unsigned const n = core.bulk_packet(wire);
			unsigned const length = wire[2] | (wire[3] << 8);
			check(n >= 9 && wire[0] == 0xa5 && wire[1] == 0x5a && length + 6 == n && wire[4] == type && wire[5] == sequence &&
					wire[6] == 0 && wire[n - 2] == 0 && wire[n - 1] == 0, "bulk packet header/trailer (%u bytes)", n);
			packets.emplace_back(wire + 7, wire + n - 2);
			core.bulk_sent();
			if (!core.run_more() || !core.run_next())
				break;
		}
		end();
		return packets;
	}

	bytes take_all(u8 type, u8 sequence)
	{
		bytes all;
		for (auto const &p : take(type, sequence))
			all.insert(all.end(), p.begin(), p.end());
		return all;
	}

	// Transport, from the Z80: the capture window as the KonaOS bulk write
	// fills it: the lead-in, the packet, its two trailer bytes, then fill.
	// `cut` stops the host after that many packet bytes (an underrun: WR7
	// fill follows); `late` delays its start.
	void give(bytes const &payload, u8 type, u8 sequence, int cut = -1, unsigned late = 0, u8 status = 0)
	{
		check(core.bulk_armed() == bulk_dir::FROM_Z80, "a receive is armed");
		unsigned const window = core.bulk_window();
		bytes w(late, 0xff);
		w.push_back(0x00); // lead-in
		bytes p = { 0xa5, 0x5a, u8(3 + payload.size()), u8((3 + payload.size()) >> 8), type, sequence, status };
		p.insert(p.end(), payload.begin(), payload.end());
		p.push_back(0x12); // the SIO's CRC bytes, not checked under the bypass
		p.push_back(0x34);
		if (cut >= 0 && size_t(cut) < p.size())
			p.resize(cut);
		w.insert(w.end(), p.begin(), p.end());
		w.resize(window, 0xaa);
		core.bulk_received(w.data(), unsigned(w.size()));
		end();
	}

	void no_host()
	{
		core.bulk_no_host();
		end();
	}

	reply_t done()
	{
		reply_t r = cmd(0x06);
		check(r.cls == 0x86 && r.status == 0 && r.data.size() == 20, "XFER_STATUS: DONE record, 20 DATA bytes");
		return r;
	}
};

struct test
{
	char const *name;
	std::function<void()> body;
};

// Every test in order; the RESULT line the runner reads; the exit status.
int run_tests(std::vector<test> const &tests)
{
	unsigned passed = 0;
	for (auto const &t : tests)
	{
		g_test_failed = 0;
		t.body();
		std::printf("%s %s\n", g_test_failed ? "FAIL" : "PASS", t.name);
		passed += !g_test_failed;
	}
	std::printf("RESULT %u passed, %u failed, 0 skipped (%u checks, %u failed)\n", passed, unsigned(tests.size()) - passed, g_checks, g_failed);
	return passed == tests.size() ? 0 : 1;
}

} // anonymous namespace

#endif
