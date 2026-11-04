// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: the IOC protocol core against real wire frames (rig.h).
// Expected values come from the firmware source, cited per check.  Media:
// tests/ioc_core/memory_storage.h.
#include "rig.h"
#include "memory_storage.h"

namespace {

using rig = rig_t<memory_storage>;

//**************************************************************************
//  Framing and the transport-level classes
//**************************************************************************

void framing()
{
	rig t;
	bytes const ping_data = pattern(16, 0x10);
	// A valid PING at a late position after full-duplex garbage.
	reply_t r = t.serve(cat({ { 0xff, 0x00, 0x13, 0xa5 }, packet(0x01, 7, ping_data) }));
	check(r.answered && r.cls == 0x81 && r.seq == 7 && r.status == 0 && r.data.size() == 26, "PING after leading bytes");
	check(bytes(r.data.begin(), r.data.begin() + 16) == ping_data, "PING echoes DATA 0-15");
	check(r.data[16] == 75 && r.data[17] == 0x6f, "PING level 75, power 6Fh (handler_ping)");
	check(r.u16_at(18) == 1 && r.u16_at(20) == 0, "PING counters calls 1 aborts 0 (svc_calls/svc_aborts)");

	// Malformed windows are dropped without a reply and counted as aborts.
	bytes bad_crc = packet(0x01, 8, {});
	bad_crc.back() ^= 1;
	check(!t.serve(bad_crc).answered, "bad CRC: no reply");
	bytes long_len = packet(0x01, 9, {});
	long_len[2] = 30; // LEN beyond 3..29
	check(!t.serve(long_len).answered, "LEN 30: no reply");
	bytes short_len = packet(0x01, 9, {});
	short_len[2] = 2;
	check(!t.serve(short_len).answered, "LEN 2: no reply");
	bytes truncated = packet(0x01, 10, pattern(20, 1));
	check(!t.serve(cat({ bytes(10, 0xff), bytes(truncated.begin(), truncated.end()) })).answered,
			"packet running past the 36-byte window: no reply");
	check(!t.serve(packet(0x13, 11, {})).answered, "class 13h (not admitted): no reply");
	check(!t.serve(packet(0x29, 11, {})).answered, "class 29h (not admitted): no reply");
	check(!t.serve(packet(0x46, 11, {})).answered, "class 46h (not admitted): no reply");
	check(!t.serve(packet(0x01, 11, {}, 0x01)).answered, "request STATUS 01h: no reply");
	check(!t.serve(bytes(36, 0xff)).answered, "idle window: no reply");

	// A broken frame does not consume the valid request after it.
	bytes broken = packet(0x01, 12, {});
	broken[7] ^= 0xff; // CRC
	r = t.serve(cat({ broken, packet(0x01, 13, {}) }));
	check(r.answered && r.seq == 13, "valid request after a broken one is served (seq %02X)", r.seq);

	r = t.cmd(0x01);
	check(r.u16_at(18) == 12 && r.u16_at(20) == 9, "counters after 12 services, 9 dropped windows: calls %u aborts %u",
			r.u16_at(18), r.u16_at(20));
	t.link.synced = false;
	r = t.cmd(0x01);
	check(r.data[17] == 0x2f, "PING power without IOC_PING_LINK_SYNCED: %02X", r.data[17]);
	// Stale bytes: a short request's reply carries nothing from a longer one.
	r = t.cmd(0x01, { 0x55 });
	check(r.data[0] == 0x55 && std::all_of(r.data.begin() + 1, r.data.begin() + 16, [] (u8 b) { return b == 0; }),
			"PING echo is the request's own DATA, zero-filled");
}

void classes()
{
	rig t;
	for (u8 cls : { 0x04, 0x05, 0x07, 0x0b })
	{
		reply_t r = t.cmd(cls, { 0, 0, 0, 0 });
		check(r.cls == 0xfe && r.status == 0x02 && r.data.empty(), "diagnostic class %02X: FEh, status 02h", cls);
		check(t.core.bulk_armed() == bulk_dir::NONE, "class %02X arms nothing", cls);
	}
	reply_t r = t.cmd(0x0c);
	check(r.cls == 0x8c && r.status == 0 && r.data.empty() && t.link.resyncs == 1, "LINK_SYNC resynchronises both lanes");
	t.seq++;
	r = t.serve(packet(0x02, t.seq, {}));
	check(!r.answered && t.link.resets == 1, "RESET: no reply, host reset requested");
	r = t.cmd(0x06);
	check(r.cls == 0x86 && r.data.size() == 20 && r.data[0] == 0 && r.data[1] == 0, "XFER_STATUS before any transfer: id 0");
}

//**************************************************************************
//  An empty socket (production until media are supplied)
//**************************************************************************

void empty_socket()
{
	rig t;
	t.media.present = false;
	reply_t r = t.cmd(0x03);
	check(r.cls == 0x83 && r.status == 0x15 && r.data == bytes(8, 0), "SD_READ: SD_NO_CARD, 8 trace bytes (zero)");
	r = t.cmd(0x08, le32(5));
	check(r.cls == 0x88 && r.status == 0x15 && r.data == bytes(8, 0), "SD_READ_REC: SD_NO_CARD, READY shape with no id");
	r = t.cmd(0x0f, le32(0));
	check(r.cls == 0x8f && r.status == 0x15, "SD_READ_BLOCK: SD_NO_CARD");
	r = t.cmd(0x09, le32(3));
	check(r.cls == 0x89 && r.status == 0 && r.data[0] == 1 && r.data[1] == 1 && r.u16_at(2) == 128 && r.u32_at(4) == 3,
			"SD_WRITE_REC: READY id 1, Z80->MCU, 128 bytes, record echo");
	t.give(pattern(128, 1), 0x09, t.seq);
	r = t.done();
	check(r.data[0] == 1 && r.data[1] == 0x15, "SD_WRITE_REC DONE: id 1, SD_NO_CARD from the commit");
	r = t.cmd(0x0a);
	check(r.cls == 0x8a && r.status == 0 && r.data.empty(), "SD_FLUSH: nothing dirty, OK");
	r = t.cmd(0x11, { 0 });
	check(r.cls == 0x91 && r.status == 0 && r.data.size() == 25 && r.data[1] == 0 && bytes(r.data.begin() + 11, r.data.begin() + 22) == bytes(11, ' '),
			"VOL_INFO: unit 0 unmounted, blank name");
	r = t.cmd(0x10, cat({ { 1 }, name11("CPM_2", "DRV") }));
	check(r.cls == 0x90 && r.status == 0x15 && r.data[0] == 1, "VOL_MOUNT: SD_NO_CARD");
	r = t.cmd(0x10, cat({ { 2 }, name11("CPM_2", "DRV") }));
	check(r.status == 0x30 && r.data[0] == 2, "VOL_MOUNT unit 2: VOL_UNMOUNTED");

	r = t.cmd(0x30);
	check(r.cls == 0xb0 && r.status == 0 && r.data.size() == 14 && r.data[0] == 1 && r.data[1] == 1 && r.u16_at(2) == 0x1ffe &&
			r.u32_at(4) == 1 && r.u16_at(8) == 512 && r.data[10] == 2 && r.data[11] == 1 && r.data[12] == 16 && r.data[13] == 2,
			"FS2_CAPS: version 1, flags 1FFEh, generation 1, chunk 512, 2 files, 1 dir, 16 components, 2-byte tokens");
	r = t.cmd(0x31);
	check(r.cls == 0xb1 && r.u32_at(0) == 1, "FS2_GENERATION 1");
	r = t.cmd(0x32);
	check(r.cls == 0xb2 && r.status == 0 && r.u32_at(0) == 2, "FS2_RESET: generation 2");
	r = t.cmd(0x33);
	check(r.cls == 0xb3 && r.status == 0 && r.data.empty(), "FS2_ROOT: OK without media");
	for (u8 cls : { 0x34, 0x35, 0x3b, 0x41, 0x43, 0x44 })
	{
		r = t.cmd(cls, name11("FILE", "TXT"));
		check(r.cls == (cls | 0x80) && r.status == 0x4b && r.data.empty(), "FS2 %02X: NO_MEDIA", cls);
	}
	r = t.cmd(0x38);
	check(r.status == 0x4b, "FS2_OPENDIR: NO_MEDIA");
	r = t.cmd(0x3c);
	check(r.status == 0x4b, "FS2_SPACE: NO_MEDIA");
	r = t.cmd(0x3d, cat({ { 2 }, name11("NEW", "TXT") }));
	check(r.status == 0x4b, "FS2_OPEN_RW: NO_MEDIA");
	r = t.cmd(0x42, cat({ name11("A"), name11("B") }));
	check(r.status == 0x4b, "FS2_RENAME: NO_MEDIA");
	for (u8 cls : { 0x36, 0x37, 0x3e, 0x3f, 0x40, 0x45 })
	{
		r = t.cmd(cls, cat({ le16(0x0201), le32(0), le16(16) }));
		check(r.status == 0x48, "FS2 %02X with a token never issued: NO_HANDLE", cls);
	}
	r = t.cmd(0x39, le16(0x0201));
	check(r.status == 0x48, "FS2_READDIR without a directory: NO_HANDLE");

	r = t.cmd(0x20);
	check(r.cls == 0xa0 && r.status == 0x13, "FS_OPENDIR: SD_READ_FAIL (need_fs)");
	r = t.cmd(0x21);
	check(r.cls == 0xa1 && r.status == 0x36, "FS_READDIR: FS_NO_HANDLE");
	r = t.cmd(0x22, cat({ { 0 }, name11("A", "TXT") }));
	check(r.cls == 0xa2 && r.status == 0x13, "FS_OPEN: SD_READ_FAIL");
	r = t.cmd(0x23, cat({ { 1 }, le32(0), le16(16) }));
	check(r.status == 0x36, "FS_READ: FS_NO_HANDLE");
	r = t.cmd(0x28);
	check(r.cls == 0xa8 && r.status == 0x13 && r.data == bytes(17, 0), "FS_SELFTEST: SD_READ_FAIL, zero fields");

	r = t.cmd(0x0d, { 0 });
	check(r.cls == 0x8d && r.data.size() == 26 && r.data[0] == 0 && r.data[1] == 0 && r.data[2] == 1 && r.data[13] == 0 &&
			r.data[14] == 0 && r.data[25] == 0xff, "HID_STATUS page 0: NOT_STARTED, revision 0, /USB_INT idle, nothing mounted, speed FFh");
	r = t.cmd(0x0d, { 6 });
	check(r.data.size() == 26 && r.data[0] == 6 && r.data[1] == 0 && r.data[4] == 0xff && r.u16_at(5) == 0xffff && r.data[10] == 0xff &&
			r.data[13] == 0xff && r.data[17] == 0x7f && r.data[24] == 0x7f && r.data[25] == 0xff, "HID_STATUS page 6: no gamepad, latches idle 7Fh");
	r = t.cmd(0x0d, { 7 });
	check(r.data.size() == 21 && r.data[0] == 7 && r.data[1] == 0, "HID_STATUS page 7: no second interface");
	r = t.cmd(0x0d, { 3 });
	check(r.data.size() == 26 && r.data[0] == 0, "HID_STATUS page 3 answers page 0 (normal profile)");
	r = t.cmd(0x0e, { 24 });
	check(r.cls == 0x8e && r.data.size() == 2 && r.data[0] == 0 && r.data[1] == 0, "HID_INPUT: empty queue");
	r = t.cmd(0x12);
	check(r.cls == 0x92 && r.data == bytes(9, 0), "HID_MOUSE: not mounted, no motion");
}

//**************************************************************************
//  FS2
//**************************************************************************

void fs2_read()
{
	rig t;
	bytes const text = pattern(1500, 3);
	t.media.add_dir("/DOCS");
	t.media.add_file("/DOCS/READ.TXT", text);
	t.cmd(0x32);
	reply_t r = t.cmd(0x34, name11("DOCS"));
	check(r.cls == 0xb4 && r.status == 0, "FS2_PUSH DOCS");
	r = t.cmd(0x35, name11("read", "txt"));
	check(r.cls == 0xb5 && r.status == 0 && r.data.size() == 7 && r.u32_at(2) == 1500 && r.data[6] == 0,
			"FS2_OPEN_RO lower-case name: size 1500");
	u16 const token = r.u16_at(0);
	check(token == 0x0201, "first token: slot 1, cookie 2 (fs2_init cookie 1, +1): %04X", token);

	r = t.cmd(0x36, cat({ le16(token), le32(0), le16(512) }));
	check(r.cls == 0xb6 && r.status == 0 && r.data.size() == 8 && r.data[1] == 0 && r.u16_at(2) == 512 && r.u32_at(4) == 0,
			"FS2_READ 512 at 0: READY to the Z80");
	u8 const id = r.data[0];
	bytes got = t.take_all(0xb6, t.seq);
	check(got == bytes(text.begin(), text.begin() + 512), "FS2_READ bulk DATA");
	r = t.done();
	check(r.data[0] == id && r.data[1] == 0, "DONE after a read: its id, OK");

	r = t.cmd(0x36, cat({ le16(token), le32(1400), le16(512) }));
	check(r.status == 0 && r.u16_at(2) == 100, "FS2_READ at 1400: 100 bytes (EOF)");
	got = t.take_all(0xb6, t.seq);
	check(got == bytes(text.begin() + 1400, text.end()), "short read DATA");
	r = t.cmd(0x36, cat({ le16(token), le32(1500), le16(512) }));
	check(r.status == 0 && r.data == bytes(8, 0) && t.core.bulk_armed() == bulk_dir::NONE, "FS2_READ at EOF: READY with id 0, nothing armed");
	r = t.cmd(0x36, cat({ le16(token), le32(4000), le16(16) }));
	check(r.status == 0 && r.data == bytes(8, 0), "FS2_READ past EOF: f_lseek clips, nothing read");

	for (auto const &[off, len, what] : std::vector<std::tuple<u32, u16, char const *>>{
			{ 0, 0, "length 0" }, { 0, 513, "length 513" } })
	{
		r = t.cmd(0x36, cat({ le16(token), le32(off), le16(len) }));
		check(r.status == 0x4a && r.data.empty(), "FS2_READ %s: RANGE", what);
	}
	r = t.cmd(0x45, cat({ le16(token), le32(100), le16(512) }));
	check(r.status == 0x4a, "FS2_READ_RUN unaligned offset: RANGE");
	r = t.cmd(0x45, cat({ le16(token), le32(0), le16(2049) }));
	check(r.status == 0x4a, "FS2_READ_RUN 2049 bytes: RANGE (IOC_FS2_RUN_MAX 2048)");

	r = t.cmd(0x45, cat({ le16(token), le32(0), le16(2048) }));
	check(r.cls == 0xc5 && r.status == 0 && r.u16_at(2) == 1500, "FS2_READ_RUN 2048 at 0: READY 1500");
	auto packets = t.take(0xc5, t.seq);
	check(packets.size() == 3 && packets[0].size() == 512 && packets[1].size() == 512 && packets[2].size() == 476,
			"run packets 512/512/476 (%zu packets)", packets.size());
	got.clear();
	for (auto const &p : packets)
		got.insert(got.end(), p.begin(), p.end());
	check(got == text, "run DATA");

	// Tokens: a wrong cookie, a closed slot, a stale generation.
	r = t.cmd(0x36, cat({ le16(token + 0x100), le32(0), le16(16) }));
	check(r.status == 0x48, "wrong cookie: NO_HANDLE");
	r = t.cmd(0x36, cat({ le16(0x0003), le32(0), le16(16) }));
	check(r.status == 0x48, "slot 3: NO_HANDLE");
	r = t.cmd(0x31);
	u32 const before = r.u32_at(0);
	r = t.cmd(0x32);
	check(r.u32_at(0) == before + 1, "FS2_RESET advances the generation");
	r = t.cmd(0x36, cat({ le16(token), le32(0), le16(16) }));
	check(r.status == 0x49, "token from the previous generation: STALE");
	check(t.media.open_objects() == 0, "FS2_RESET closed every context (%u open)", t.media.open_objects());

	// A removed card is noticed only by the first access that fails
	// (map_result): then the generation advances, the old token is STALE and
	// the resolver is back at the root.
	t.cmd(0x34, name11("DOCS"));
	r = t.cmd(0x35, name11("READ", "TXT"));
	u16 const token2 = r.u16_at(0);
	u32 const generation = t.cmd(0x31).u32_at(0);
	t.media.present = false;
	check(t.cmd(0x31).u32_at(0) == generation, "a removal alone changes nothing (no detection)");
	r = t.cmd(0x36, cat({ le16(token2), le32(0), le16(16) }));
	check(r.status == 0x4b, "the first access without the card: NO_MEDIA");
	check(t.cmd(0x31).u32_at(0) == generation + 1, "the failure advanced the generation");
	t.media.present = true;
	r = t.cmd(0x36, cat({ le16(token2), le32(0), le16(16) }));
	check(r.status == 0x49, "the card back: the old token is STALE");
	r = t.cmd(0x35, name11("READ", "TXT"));
	check(r.status == 0x40, "the resolver is at the root: NOT_FOUND");

	// A media-level failure (FR_DISK_ERR) drops every context (map_result).
	t.cmd(0x34, name11("DOCS"));
	r = t.cmd(0x35, name11("READ", "TXT"));
	u16 const token3 = r.u16_at(0);
	t.media.fail_next = memory_storage::fr::DISK_ERR;
	r = t.cmd(0x36, cat({ le16(token3), le32(8), le16(16) }));
	check(r.status == 0x4e, "FR_DISK_ERR: FS2_IO");
	r = t.cmd(0x36, cat({ le16(token3), le32(8), le16(16) }));
	check(r.status == 0x49, "after FR_DISK_ERR: STALE");
}

void fs2_directories()
{
	rig t;
	t.media.add_dir("/A");
	t.media.add_file("/A/ONE.TXT", pattern(10, 1));
	t.media.add_dir("/A/SUB");
	t.media.add_file("/A/LONG~1.TXT", pattern(3, 1)); // not an FS2 8.3 name
	t.media.add_file("/A/TWO", pattern(20, 1));
	reply_t r = t.cmd(0x34, name11("A"));
	r = t.cmd(0x38);
	check(r.cls == 0xb8 && r.status == 0 && r.data.size() == 2 && r.data[0] == 1, "FS2_OPENDIR of /A");
	u16 const dir = r.u16_at(0);
	r = t.cmd(0x38);
	check(r.status == 0x48, "second FS2_OPENDIR: NO_HANDLE (one DIR slot)");
	std::vector<std::string> names;
	std::vector<u8> attrs;
	for (;;)
	{
		r = t.cmd(0x39, le16(dir));
		if (r.status != 0)
			break;
		check(r.data.size() == 16, "dirent 16 DATA bytes");
		names.emplace_back(r.data.begin(), r.data.begin() + 11);
		attrs.push_back(r.data[11]);
	}
	check(r.status == 0x41 && r.data.empty(), "listing ends with END");
	check(names == std::vector<std::string>{ "ONE     TXT", "SUB        ", "TWO        " }, "entries ONE.TXT SUB TWO; LONG~1 skipped");
	check(attrs == std::vector<u8>{ 0, 0x10, 0 }, "only AM_DIR reported");
	r = t.cmd(0x3a, le16(dir));
	check(r.cls == 0xba && r.status == 0, "FS2_CLOSEDIR");
	r = t.cmd(0x39, le16(dir));
	check(r.status == 0x48, "READDIR after CLOSEDIR: NO_HANDLE");

	r = t.cmd(0x3b, name11("ONE", "TXT"));
	check(r.cls == 0xbb && r.status == 0 && r.u32_at(0) == 10 && r.data[4] == 0, "FS2_STAT ONE.TXT");
	r = t.cmd(0x3b, name11("SUB"));
	check(r.status == 0 && r.data[4] == 0x10, "FS2_STAT SUB: AM_DIR");
	r = t.cmd(0x34, name11("ONE", "TXT"));
	check(r.status == 0x46, "FS2_PUSH of a file: NOT_DIR");
	r = t.cmd(0x35, name11("SUB"));
	check(r.status == 0x47, "FS2_OPEN_RO of a directory: IS_DIR");
	r = t.cmd(0x34, name11("NOPE"));
	check(r.status == 0x40, "FS2_PUSH of a missing name: NOT_FOUND");
	r = t.cmd(0x3c);
	check(r.cls == 0xbc && r.status == 0 && r.data.size() == 16 && r.u32_at(4) == (1u << 20) && r.u32_at(12) == 1024,
			"FS2_SPACE: 1 MiB total, 1024 KiB");

	// The resolver bound: 16 components.
	rig deep;
	std::string path;
	for (int i = 0; i < 17; i++)
	{
		path += "/D" + std::to_string(i);
		deep.media.add_dir(path);
	}
	for (int i = 0; i < 16; i++)
	{
		r = deep.cmd(0x34, name11("D" + std::to_string(i)));
		check(r.status == 0, "PUSH %d", i);
	}
	r = deep.cmd(0x34, name11("D16"));
	check(r.status == 0x4a, "17th PUSH: RANGE (16 resolver components)");
	r = deep.cmd(0x33);
	r = deep.cmd(0x34, name11("D0"));
	check(r.status == 0, "FS2_ROOT then PUSH D0");
}

void fs2_names_and_negatives()
{
	rig t;
	t.media.add_file("/KEEP.TXT", pattern(40, 9));
	t.media.add_dir("/FULL");
	t.media.add_file("/FULL/X", { 1 });
	std::string const before = t.media.snapshot();

	reply_t r;
	for (auto const &bad : { name11("A.B"), name11("A B"), name11(""), name11("A*"), name11("AB", "T X"), name11("A", " X"),
			 name11("../X"), name11("A/B") })
	{
		r = t.cmd(0x43, bad);
		check(r.status == 0x43, "MKDIR bad name: BAD_NAME");
		r = t.cmd(0x41, bad);
		check(r.status == 0x43, "UNLINK bad name: BAD_NAME");
		r = t.cmd(0x3d, cat({ { 2 }, bad }));
		check(r.status == 0x43, "OPEN_RW bad name: BAD_NAME");
	}
	r = t.cmd(0x3d, cat({ { 3 }, name11("NEW") }));
	check(r.status == 0x4a, "OPEN_RW mode 3: RANGE");
	r = t.cmd(0x3d, cat({ { 1 }, name11("KEEP", "TXT") }));
	check(r.status == 0x42, "OPEN_RW CREATE_NEW of an existing file: EXISTS");
	r = t.cmd(0x3d, cat({ { 0 }, name11("NONE", "TXT") }));
	check(r.status == 0x40, "OPEN_RW UPDATE of a missing file: NOT_FOUND");
	r = t.cmd(0x3d, cat({ { 2 }, name11("FULL") }));
	check(r.status == 0x47, "OPEN_RW of a directory: IS_DIR");
	r = t.cmd(0x42, cat({ name11("KEEP", "TXT"), name11("FULL") }));
	check(r.status == 0x42, "RENAME onto an existing name: EXISTS");
	r = t.cmd(0x42, cat({ name11("GONE"), name11("NEW") }));
	check(r.status == 0x40, "RENAME of a missing name: NOT_FOUND");
	r = t.cmd(0x44, name11("FULL"));
	check(r.status == 0x44, "RMDIR of a non-empty directory: FR_DENIED -> READ_ONLY");
	r = t.cmd(0x43, name11("FULL"));
	check(r.status == 0x42, "MKDIR of an existing name: EXISTS");
	r = t.cmd(0x35, name11("KEEP", "TXT"));
	u16 const ro = r.u16_at(0);
	r = t.cmd(0x3e, cat({ le16(ro), le32(0), le16(16) }));
	check(r.status == 0x44 && t.core.bulk_armed() == bulk_dir::NONE, "WRITE on a read-only handle: READ_ONLY, nothing armed");
	r = t.cmd(0x40, cat({ le16(ro), le32(0) }));
	check(r.status == 0x44, "TRUNCATE on a read-only handle: READ_ONLY");
	r = t.cmd(0x3f, le16(ro));
	check(r.status == 0x44, "SYNC on a read-only handle: READ_ONLY");
	t.cmd(0x37, le16(ro));
	check(t.media.snapshot() == before, "negative requests left the media unchanged");

	t.media.read_only = true;
	r = t.cmd(0x3d, cat({ { 2 }, name11("NEW") }));
	check(r.status == 0x44, "write-protected media: OPEN_RW READ_ONLY");
	r = t.cmd(0x43, name11("NEW"));
	check(r.status == 0x44, "write-protected media: MKDIR READ_ONLY");
	check(t.media.snapshot() == before, "write-protected media unchanged");
}

void fs2_write()
{
	rig t;
	bytes const body = pattern(700, 5);
	reply_t r = t.cmd(0x3d, cat({ { 1 }, name11("OUT", "BIN") }));
	check(r.cls == 0xbd && r.status == 0 && r.u32_at(2) == 0, "OPEN_RW CREATE_NEW OUT.BIN");
	u16 const token = r.u16_at(0);

	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(512) }));
	check(r.cls == 0xbe && r.status == 0 && r.data[1] == 1 && r.u16_at(2) == 512 && r.u32_at(4) == 0,
			"FS2_WRITE: READY from the Z80, 512 bytes");
	u8 id = r.data[0];
	u8 const wseq = t.seq;
	check(t.media.file("/OUT.BIN")->empty(), "nothing written before the bulk phase");
	t.give(bytes(body.begin(), body.begin() + 512), 0x3e, wseq);
	r = t.done();
	check(r.data[0] == id && r.data[1] == 0, "DONE: id, OK");
	r = t.cmd(0x3e, cat({ le16(token), le32(512), le16(188) }));
	t.give(bytes(body.begin() + 512, body.end()), 0x3e, t.seq);
	r = t.done();
	check(r.data[1] == 0 && *t.media.file("/OUT.BIN") == body, "two writes: the file holds 700 bytes");

	// Partial transfer: the host stops inside the header; nothing is written.
	std::string snap = t.media.snapshot();
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	id = r.data[0];
	t.give(pattern(64, 0x77), 0x3e, t.seq, 5);
	r = t.done();
	check(r.data[0] == id && r.data[1] == 0x22 && t.media.snapshot() == snap, "host stopped in the header: BULK_NO_SYNC, unchanged");
	// A packet bound to another sequence or class is refused.
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	t.give(pattern(64, 0x77), 0x3e, u8(t.seq + 1));
	r = t.done();
	check(r.data[1] == 0x22 && t.media.snapshot() == snap, "wrong SEQ: BULK_NO_SYNC, unchanged");
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	t.give(pattern(64, 0x77), 0x24, t.seq);
	r = t.done();
	check(r.data[1] == 0x22 && t.media.snapshot() == snap, "wrong TYPE: BULK_NO_SYNC, unchanged");
	// The marker beyond the 16-byte search: not found.
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	t.give(pattern(64, 0x77), 0x3e, t.seq, -1, 16);
	r = t.done();
	check(r.data[1] == 0x22 && t.media.snapshot() == snap, "marker past the search range: BULK_NO_SYNC");
	// A late but in-range start is found.
	r = t.cmd(0x3e, cat({ le16(token), le32(700), le16(4) }));
	t.give({ 1, 2, 3, 4 }, 0x3e, t.seq, -1, 14);
	r = t.done();
	check(r.data[1] == 0 && t.media.file("/OUT.BIN")->size() == 704, "marker at byte 15 of the window: accepted");
	snap = t.media.snapshot();
	// The host never admits the transfer.
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	id = r.data[0];
	t.no_host();
	r = t.done();
	check(r.data[0] == id && r.data[1] == 0x21 && t.media.snapshot() == snap, "no host: BULK_NO_HOST, unchanged");
	// The host underruns inside the DATA: under the CRC bypass the fill is
	// what arrives, and the controller commits it.
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(8) }));
	t.give({ 9, 9, 9, 9, 9, 9, 9, 9 }, 0x3e, t.seq, 7 + 4);
	r = t.done();
	check(r.data[1] == 0 && bytes(t.media.file("/OUT.BIN")->begin(), t.media.file("/OUT.BIN")->begin() + 8) ==
			bytes{ 9, 9, 9, 9, 0xaa, 0xaa, 0xaa, 0xaa }, "underrun inside DATA: the WR7 fill is committed (CRC bypass)");

	// Reset during a transfer: nothing is committed, the DONE record is gone.
	snap = t.media.snapshot();
	r = t.cmd(0x3e, cat({ le16(token), le32(0), le16(64) }));
	t.core.reset();
	check(t.core.bulk_armed() == bulk_dir::NONE && t.media.snapshot() == snap && t.media.open_objects() == 0,
			"controller reset mid-transfer: nothing armed, nothing written, objects dropped");
	r = t.done();
	check(r.data[0] == 0 && r.data[1] == 0, "DONE after the reset: id 0");

	// Truncate grows (f_lseek past the end of a writable file) and shrinks.
	r = t.cmd(0x3d, cat({ { 0 }, name11("OUT", "BIN") }));
	u16 const t2 = r.u16_at(0);
	r = t.cmd(0x40, cat({ le16(t2), le32(1000) }));
	check(r.cls == 0xc0 && r.status == 0 && t.media.file("/OUT.BIN")->size() == 1000, "TRUNCATE to 1000 grows the file");
	r = t.cmd(0x40, cat({ le16(t2), le32(100) }));
	check(r.status == 0 && t.media.file("/OUT.BIN")->size() == 100, "TRUNCATE to 100");
	r = t.cmd(0x3f, le16(t2));
	check(r.cls == 0xbf && r.status == 0, "SYNC");

	// A full volume: the short write is NO_SPACE.
	t.media.capacity = 150;
	r = t.cmd(0x3e, cat({ le16(t2), le32(100), le16(100) }));
	t.give(pattern(100, 1), 0x3e, t.seq);
	r = t.done();
	check(r.data[1] == 0x45 && t.media.file("/OUT.BIN")->size() == 150, "full volume: FS2_NO_SPACE after 50 bytes");
	t.media.capacity = 1u << 20;

	// The commit checks the handle: closed between READY and the bulk phase
	// it cannot be, but a handle from an old generation can.
	r = t.cmd(0x3e, cat({ le16(t2), le32(0), le16(4) }));
	r = t.cmd(0x37, le16(t2));
	check(r.status == 0, "CLOSE");
	r = t.cmd(0x3e, cat({ le16(t2), le32(0), le16(4) }));
	check(r.status == 0x48, "WRITE on a closed handle: NO_HANDLE");

	// Rename, unlink, mkdir, rmdir.
	snap = t.media.snapshot();
	r = t.cmd(0x42, cat({ name11("OUT", "BIN"), name11("RENAMED") }));
	check(r.cls == 0xc2 && r.status == 0 && t.media.file("/RENAMED") && !t.media.file("/OUT.BIN"), "RENAME");
	r = t.cmd(0x43, name11("NEWDIR"));
	check(r.cls == 0xc3 && r.status == 0, "MKDIR");
	r = t.cmd(0x44, name11("NEWDIR"));
	check(r.cls == 0xc4 && r.status == 0, "RMDIR of an empty directory");
	r = t.cmd(0x3d, cat({ { 0 }, name11("RENAMED") }));
	u16 const t3 = r.u16_at(0);
	r = t.cmd(0x41, name11("RENAMED"));
	check(r.cls == 0xc1 && r.status == 0 && !t.media.file("/RENAMED"), "UNLINK");
	r = t.cmd(0x36, cat({ le16(t3), le32(0), le16(4) }));
	check(r.status == 0x48, "UNLINK closed every FS2 file (FF_FS_LOCK 0)");
}

//**************************************************************************
//  Shared folder (the legacy FS_* family)
//**************************************************************************

void shared_folder()
{
	rig t;
	t.media.add_dir("/SHARED");
	t.media.add_file("/SHARED/HELLO.TXT", pattern(600, 2));
	t.media.add_dir("/SHARED/SUB");
	t.media.add_file("/SHARED/B.COM", { 1, 2, 3 });
	reply_t r = t.cmd(0x20);
	check(r.cls == 0xa0 && r.status == 0 && r.data.empty(), "FS_OPENDIR");
	std::vector<std::string> names;
	for (;;)
	{
		r = t.cmd(0x21);
		check(r.status == 0 && r.data.size() == 17, "FS_READDIR reply 17 bytes");
		if (r.data[16] == 0)
			break;
		names.emplace_back(r.data.begin(), r.data.begin() + 11);
	}
	check(names == std::vector<std::string>{ "HELLO   TXT", "B       COM" }, "files only, SUB skipped");
	check(r.data == bytes(17, 0), "end of listing: blank entry, MORE 0");
	r = t.cmd(0x21);
	check(r.status == 0x36, "the end closed the session: FS_NO_HANDLE");

	r = t.cmd(0x26, name11("HELLO", "TXT"));
	check(r.cls == 0xa6 && r.status == 0 && r.u32_at(0) == 600 && r.data[4] == 0x20, "FS_STAT: size, FAT attributes");
	r = t.cmd(0x26, name11("NONE"));
	check(r.status == 0x34, "FS_STAT missing: FS_NO_FILE");
	r = t.cmd(0x26, name11("A.B"));
	check(r.status == 0x35, "FS_STAT dotted name: FS_BAD_NAME");

	r = t.cmd(0x22, cat({ { 0 }, name11("HELLO", "TXT") }));
	check(r.cls == 0xa2 && r.status == 0 && r.data[0] == 1 && r.u32_at(1) == 600, "FS_OPEN read: handle 1, size 600");
	u8 const h = r.data[0];
	r = t.cmd(0x23, cat({ { h }, le32(100), le16(512) }));
	check(r.cls == 0xa3 && r.status == 0 && r.u16_at(2) == 500 && r.u32_at(4) == 100, "FS_READ at 100: 500 bytes");
	bytes got = t.take_all(0xa3, t.seq);
	bytes const hello = pattern(600, 2);
	check(got == bytes(hello.begin() + 100, hello.end()), "FS_READ DATA");
	r = t.cmd(0x23, cat({ { h }, le32(600), le16(16) }));
	check(r.status == 0 && r.data == bytes(8, 0), "FS_READ at EOF: no transfer");
	r = t.cmd(0x23, cat({ { h }, le32(0), le16(513) }));
	check(r.status == 0x37, "FS_READ 513: FS_RANGE");
	r = t.cmd(0x23, cat({ { u8(h + 1) }, le32(0), le16(16) }));
	check(r.status == 0x36, "FS_READ other handle: FS_NO_HANDLE");
	r = t.cmd(0x24, cat({ { h }, le32(0), le16(16) }));
	check(r.status == 0x36, "FS_WRITE on a read handle: FS_NO_HANDLE");

	r = t.cmd(0x22, cat({ { 1 }, name11("OUT", "TXT") }));
	check(r.status == 0 && r.data[0] == 2, "FS_OPEN write closes the read handle; handle 2");
	u8 const w = r.data[0];
	r = t.cmd(0x23, cat({ { h }, le32(0), le16(16) }));
	check(r.status == 0x36, "old handle gone");
	r = t.cmd(0x24, cat({ { w }, le32(0), le16(256) }));
	check(r.cls == 0xa4 && r.status == 0 && r.data[1] == 1 && r.u16_at(2) == 256, "FS_WRITE: READY from the Z80");
	t.give(pattern(256, 4), 0x24, t.seq);
	r = t.done();
	check(r.data[1] == 0 && t.media.file("/SHARED/OUT.TXT")->size() == 256, "FS_WRITE committed 256 bytes");
	r = t.cmd(0x25, cat({ { w }, le32(200) }));
	check(r.cls == 0xa5 && r.status == 0 && t.media.file("/SHARED/OUT.TXT")->size() == 200, "FS_CLOSE truncates to 200");
	r = t.cmd(0x25, cat({ { w }, le32(200) }));
	check(r.status == 0x36, "second FS_CLOSE: FS_NO_HANDLE");

	r = t.cmd(0x22, cat({ { 0 }, name11("B", "COM") }));
	r = t.cmd(0x27, name11("B", "COM"));
	check(r.cls == 0xa7 && r.status == 0 && !t.media.file("/SHARED/B.COM"), "FS_DELETE");
	r = t.cmd(0x23, cat({ { r.data.empty() ? u8(3) : r.data[0] }, le32(0), le16(1) }));
	check(r.status == 0x36, "FS_DELETE closed the open file");
	r = t.cmd(0x27, name11("NONE"));
	check(r.status == 0x34, "FS_DELETE missing: FS_NO_FILE");

	r = t.cmd(0x28);
	u16 sum = 0;
	for (u8 b : pattern(600, 2))
		sum += b;
	check(r.cls == 0xa8 && r.status == 0 && r.data.size() == 17 && r.data[0] == 1 && r.data[1] == 3 && r.u16_at(2) == 8 &&
			r.u16_at(8) == 2 && r.u16_at(10) == sum && r.u32_at(12) == 600 && r.data[16] == 0,
			"FS_SELFTEST: mounted FAT32, 2 files, HELLO.TXT summed");

	rig nofat;
	nofat.media.fat = false;
	r = nofat.cmd(0x20);
	check(r.status == 0x33, "card without FAT: FS_NOT_MOUNTED");
	r = nofat.cmd(0x30);
	check(r.status == 0, "CAPS without FAT");
	r = nofat.cmd(0x38);
	check(r.status == 0x4b, "FS2 without FAT: NO_MEDIA");
}

//**************************************************************************
//  Records, blocks and volumes
//**************************************************************************

void volumes()
{
	rig t;
	t.media.blocks[3] = pattern(512, 0x31);
	reply_t r = t.cmd(0x11, { 0 });
	check(r.data[1] == 0, "before any record access unit 0 is unmounted");
	r = t.cmd(0x08, le32(13)); // block 3, quarter 1
	check(r.cls == 0x88 && r.status == 0 && r.data[1] == 0 && r.u16_at(2) == 128 && r.u32_at(4) == 13, "SD_READ_REC 13: READY 128, echo");
	bytes got = t.take_all(0x88, t.seq);
	check(got == bytes(t.media.blocks[3].begin() + 128, t.media.blocks[3].begin() + 256), "record DATA (raw mode)");
	r = t.cmd(0x11, { 0 });
	// The auto-mount ran after the card came up; no CPM_1.DRV: unit 0 drops
	// to unmounted (vol_service -> vol_mount clears the unit first).
	check(r.data[1] == 0 && r.data[2] == 0, "after the auto-mount without CPM_1.DRV unit 0 is unmounted (firmware vol_service)");
	r = t.cmd(0x08, le32(13));
	check(r.status == 0x30, "the next record read: VOL_UNMOUNTED");

	rig v;
	v.media.images["/CPM/CPM_1.DRV"] = bytes(8u << 20, 0xe5);
	v.media.images["/CPM/CPM_2.DRV"] = bytes(8u << 20, 0x00);
	v.media.images["/CPM/SMALL.DRV"] = bytes(4096, 0);
	r = v.cmd(0x0f, le32(2));
	check(r.cls == 0x8f && r.status == 0 && r.u16_at(2) == 512 && r.u32_at(4) == 2, "SD_READ_BLOCK 2 (raw): READY 512");
	v.take_all(0x8f, v.seq);
	r = v.cmd(0x11, { 0 });
	check(r.data[0] == 0 && r.data[1] == 2 && r.data[2] == 1 && r.u32_at(3) == 0x4000 && r.u32_at(7) == 65536 &&
			bytes(r.data.begin() + 11, r.data.begin() + 22) == name11("CPM_1", "DRV") && r.data[22] == 0 && r.data[23] == 0 && r.data[24] == 0,
			"VOL_INFO 0 after auto-mount: file mode, 1 extent, base, 65536 records, CPM_1.DRV, guard clear");
	r = v.cmd(0x11, { 1 });
	check(r.data[1] == 2, "unit 1 file mode");
	r = v.cmd(0x09, cat({ le32(65535), { 1 } }));
	check(r.status == 0 && r.u32_at(4) == 65535, "SD_WRITE_REC unit 1 record 65535: READY");
	v.give(pattern(128, 0x40), 0x09, v.seq);
	r = v.done();
	check(r.data[1] == 0 && bytes(v.media.images["/CPM/CPM_2.DRV"].end() - 128, v.media.images["/CPM/CPM_2.DRV"].end()) == pattern(128, 0x40),
			"record written to the last record of CPM_2.DRV");
	r = v.cmd(0x08, cat({ le32(65535), { 1 } }));
	check(v.take_all(0x88, v.seq) == pattern(128, 0x40), "and read back");
	std::string const snap = v.media.snapshot();
	r = v.cmd(0x08, cat({ le32(65536), { 1 } }));
	check(r.status == 0x31 && r.data == bytes(8, 0), "record 65536: VOL_RANGE, no transfer");
	r = v.cmd(0x0f, cat({ le32(16384), { 0 } }));
	check(r.status == 0x31, "block 16384: VOL_RANGE");
	r = v.cmd(0x0f, cat({ le32(0x40000000), { 0 } }));
	check(r.status == 0x31, "block 40000000h (would wrap): VOL_RANGE");
	r = v.cmd(0x08, cat({ le32(0), { 2 } }));
	check(r.status == 0x30, "unit 2: VOL_UNMOUNTED");
	r = v.cmd(0x09, cat({ le32(70000), { 0 } }));
	check(r.status == 0, "SD_WRITE_REC out of range still answers READY (handler_sd_write_rec)");
	v.give(pattern(128, 1), 0x09, v.seq);
	r = v.done();
	check(r.data[1] == 0x31 && v.media.snapshot() == snap, "its DONE: VOL_RANGE, nothing written");

	r = v.cmd(0x10, cat({ { 1 }, name11("SMALL", "DRV") }));
	check(r.cls == 0x90 && r.status == 0x32 && r.data[1] == 0, "VOL_MOUNT of a wrong-size image: VOL_BAD_IMAGE, unit unmounted");
	r = v.cmd(0x10, cat({ { 1 }, name11("NONE", "DRV") }));
	check(r.status == 0x10, "VOL_MOUNT of a missing image: SD_NO_RESPONSE");
	r = v.cmd(0x10, cat({ { 1 }, name11("CPM_2", "DRV") }));
	check(r.status == 0 && r.data[1] == 2, "VOL_MOUNT CPM_2.DRV");
	r = v.cmd(0x0a);
	check(r.status == 0, "SD_FLUSH");
	r = v.cmd(0x03);
	check(r.cls == 0x83 && r.status == 0 && r.data.size() == 16, "SD_READ: 16 bytes of block 0");

	// Media without card blocks (a host folder): no raw unit.
	rig f;
	f.media.raw = false;
	r = f.cmd(0x08, le32(0));
	check(r.status == 0x30, "folder media: record read VOL_UNMOUNTED (no raw unit)");
	r = f.cmd(0x03);
	check(r.status == 0 && r.data == bytes(16, 0), "folder media: SD_READ answers, block 0 blank");
}

//**************************************************************************
//  HID input queue
//**************************************************************************

void hid_queue()
{
	rig t;
	u8 const key[] = { 0x1b, '[', 'A' };
	check(t.core.hid().put(key, 3) && t.link.doorbell, "a key's bytes queued, /CTSB asserted");
	u8 const text[] = { 'a', 'b' };
	t.core.hid().put(text, 2);
	reply_t r = t.cmd(0x0e, { 2 });
	check(r.data.size() == 4 && r.data[0] == 3 && r.data[1] == 0 && r.data[2] == 0x1b && r.data[3] == '[', "partial dequeue: 2 of 5, 3 left");
	check(t.link.doorbell, "doorbell stays asserted after a partial dequeue");
	r = t.cmd(0x0e, { 0 });
	check(r.data.size() == 2 && r.data[0] == 3, "status-only query");
	r = t.cmd(0x0e, { 200 });
	check(r.data.size() == 5 && r.data[0] == 0 && r.data[2] == 'A' && r.data[4] == 'b' && !t.link.doorbell, "drain: doorbell released");
	bytes fill(128, 'x');
	check(t.core.hid().put(fill.data(), 127), "127 bytes queued");
	check(!t.core.hid().put(key, 3), "a 3-byte sequence with 1 byte free is refused whole");
	r = t.cmd(0x0e, { 30 });
	check(r.data.size() == 26 && r.data[0] == 103 && r.data[1] == 1, "dequeue capped at 24; dropped 1");
}

void save_registration()
{
	rig t;
	unsigned items = 0;
	t.core.save_state([&items] (auto &&...) { items++; });
	check(items > 60, "every persistent member registered (%u items)", items);
}

} // anonymous namespace

int main()
{
	std::vector<test> const tests = {
		{ "framing", framing },
		{ "classes", classes },
		{ "empty-socket", empty_socket },
		{ "fs2-read", fs2_read },
		{ "fs2-directories", fs2_directories },
		{ "fs2-negative", fs2_names_and_negatives },
		{ "fs2-write", fs2_write },
		{ "shared-folder", shared_folder },
		{ "volumes", volumes },
		{ "hid-queue", hid_queue },
		{ "save-state", save_registration },
	};
	return run_tests(tests);
}
