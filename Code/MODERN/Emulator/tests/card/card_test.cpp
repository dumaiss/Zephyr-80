// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: the IOC core with the production card socket
// (zephyr80_card_socket) on real disposable media, driven by real frames
// (../ioc_core/rig.h).  card_backends.py makes the media in the directory
// given as the first argument, runs this, and then reads what it wrote with
// an independent FAT reader (fat_fixture.py) and the host filesystem.
//
// Per medium this writes expect/<medium>/..., the tree the medium must hold
// afterwards, and records.txt, the volume records written ("FILE OFFSET HEX").
#include "rig.h"
#include "zephyr80_card.h"

#include <algorithm>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <sys/resource.h>

namespace {

namespace fs = std::filesystem;
using card_rig = rig_t<zephyr80_card_socket>;

fs::path g_dir;
std::ofstream g_records;

constexpr u8 OK = 0x00;
constexpr u8 SD_READ_FAIL = 0x13, SD_WRITE_FAIL = 0x18, SD_WRITE_REJ = 0x19;
constexpr u8 BULK_NO_SYNC = 0x22, VOL_UNMOUNTED = 0x30, VOL_RANGE = 0x31, VOL_BAD_IMAGE = 0x32;
constexpr u8 FS_ERROR = 0x38;
constexpr u8 NOT_FOUND = 0x40, END = 0x41, EXISTS = 0x42, BAD_NAME = 0x43, READ_ONLY = 0x44, NO_SPACE = 0x45;
constexpr u8 IS_DIR = 0x47, STALE = 0x49, RANGE = 0x4a, NO_MEDIA = 0x4b, IO = 0x4e;

// "NAME.EXT" as a packed 8.3 request name (no validation: bad names pass).
bytes n83(std::string const &name)
{
	size_t const dot = name.find('.');
	return name11(name.substr(0, dot), dot == std::string::npos ? "" : name.substr(dot + 1));
}

bytes file_bytes(fs::path const &p)
{
	std::ifstream f(p, std::ios::binary);
	return bytes(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

void put_file(fs::path const &p, bytes const &data)
{
	fs::create_directories(p.parent_path());
	std::ofstream(p, std::ios::binary).write(reinterpret_cast<char const *>(data.data()), data.size());
}

std::string hex(bytes const &b)
{
	static char const digits[] = "0123456789abcdef";
	std::string s;
	for (u8 v : b)
	{
		s += digits[v >> 4];
		s += digits[v & 15];
	}
	return s;
}

// The seeded tree card_backends.py writes into every workload medium.
bytes text(char const *s) { return bytes(s, s + std::strlen(s)); }
bytes const HELLO = text("Hello, card!\n");
bytes const BIG = pattern(5000, 3);
bytes const NOTE = pattern(300, 9);

// The socket with media inserted, and FS2 / legacy / record requests.
struct client
{
	card_rig t;

	explicit client(fs::path const &medium, bool folder = false)
	{
		std::string const error = folder ? t.media.insert_folder(medium.string()) : t.media.insert_image(medium.string());
		check(error.empty(), "insert %s: %s", medium.string().c_str(), error.c_str());
	}

	u8 st(u8 cls, bytes const &data = {}) { return t.cmd(cls, data).status; }
	u8 push(std::string const &dir) { return st(0x34, n83(dir)); }
	void root() { t.cmd(0x33); }

	u8 open_ro(std::string const &name, u16 &token, u32 &size)
	{
		reply_t r = t.cmd(0x35, n83(name));
		token = r.status ? 0 : r.u16_at(0);
		size = r.status ? 0 : r.u32_at(2);
		return r.status;
	}
	u8 open_rw(u8 mode, std::string const &name, u16 &token, u32 &size)
	{
		reply_t r = t.cmd(0x3d, cat({ { mode }, n83(name) }));
		token = r.status ? 0 : r.u16_at(0);
		size = r.status ? 0 : r.u32_at(2);
		return r.status;
	}
	u8 read(u16 token, u32 offset, u16 length, bytes &out, u8 cls = 0x36)
	{
		out.clear();
		reply_t r = t.cmd(cls, cat({ le16(token), le32(offset), le16(length) }));
		if (r.status == OK && r.u16_at(2))
			out = t.take_all(u8(cls | 0x80), t.seq);
		return r.status;
	}
	// READY, the packet, then DONE's status.
	u8 write(u16 token, u32 offset, bytes const &data)
	{
		reply_t r = t.cmd(0x3e, cat({ le16(token), le32(offset), le16(u16(data.size())) }));
		if (r.status)
			return r.status;
		t.give(data, 0x3e, t.seq);
		return t.done().data[1];
	}
	u8 close(u16 token) { return st(0x37, le16(token)); }
	u8 sync(u16 token) { return st(0x3f, le16(token)); }
	u8 truncate(u16 token, u32 size) { return st(0x40, cat({ le16(token), le32(size) })); }
	u8 rename(std::string const &a, std::string const &b) { return st(0x42, cat({ n83(a), n83(b) })); }
	u8 stat(std::string const &name, u32 &size, u8 &dir)
	{
		reply_t r = t.cmd(0x3b, n83(name));
		size = r.status ? 0 : r.u32_at(0);
		dir = r.status ? 0 : r.data[4];
		return r.status;
	}

	// The resolver directory: "NAME.EXT" or "NAME/" per entry, in listing order.
	std::vector<std::string> list()
	{
		std::vector<std::string> names;
		reply_t r = t.cmd(0x38);
		check(r.status == OK, "OPENDIR: %02X", r.status);
		u16 const token = r.u16_at(0);
		for (unsigned i = 0; i < 1000; i++)
		{
			r = t.cmd(0x39, le16(token));
			if (r.status != OK)
			{
				check(r.status == END, "READDIR: %02X", r.status);
				break;
			}
			std::string const base = std::string(r.data.begin(), r.data.begin() + 8);
			std::string const ext = std::string(r.data.begin() + 8, r.data.begin() + 11);
			std::string name = base.substr(0, base.find_last_not_of(' ') + 1);
			if (ext != "   ")
				name += "." + ext.substr(0, ext.find_last_not_of(' ') + 1);
			names.push_back(name + (r.data[11] ? "/" : ""));
		}
		check(st(0x3a, le16(token)) == OK, "CLOSEDIR");
		return names;
	}

	bytes read_file(std::string const &name)
	{
		u16 token;
		u32 size;
		bytes all, part;
		if (open_ro(name, token, size) != OK)
			return { 0xde, 0xad };
		for (u32 offset = 0; offset < size; offset += 512)
		{
			check(read(token, offset, 512, part) == OK, "READ %s at %u", name.c_str(), offset);
			all.insert(all.end(), part.begin(), part.end());
		}
		close(token);
		return all;
	}

	bool write_file(std::string const &name, bytes const &data)
	{
		u16 token;
		u32 size;
		if (open_rw(2, name, token, size) != OK)
			return false;
		bool ok = true;
		for (size_t offset = 0; offset < data.size(); offset += 512)
			ok = ok && write(token, u32(offset), bytes(data.begin() + offset, data.begin() + std::min(data.size(), offset + 512))) == OK;
		return close(token) == OK && ok;
	}

	// Records and volumes
	u8 read_rec(u32 record, u8 unit, bytes &out)
	{
		out.clear();
		reply_t r = t.cmd(0x08, cat({ le32(record), { unit } }));
		if (r.status == OK)
			out = t.take_all(0x88, t.seq);
		return r.status;
	}
	u8 read_block(u32 block, u8 unit, bytes &out)
	{
		out.clear();
		reply_t r = t.cmd(0x0f, cat({ le32(block), { unit } }));
		if (r.status == OK)
			out = t.take_all(0x8f, t.seq);
		return r.status;
	}
	u8 write_rec(u32 record, u8 unit, bytes const &data, int cut = -1)
	{
		reply_t r = t.cmd(0x09, cat({ le32(record), { unit } }));
		if (r.status)
			return r.status;
		t.give(data, 0x09, t.seq, cut);
		return t.done().data[1];
	}
	reply_t vol_info(u8 unit) { return t.cmd(0x11, { unit }); }
	u8 vol_mount(u8 unit, std::string const &name) { return st(0x10, cat({ { unit }, n83(name) })); }
};

// The medium's expected tree, for card_backends.py.
void expect(std::string const &medium, std::map<std::string, bytes> const &files, std::vector<std::string> const &dirs)
{
	fs::path const root = g_dir / "expect" / medium;
	fs::remove_all(root);
	fs::create_directories(root);
	for (auto const &d : dirs)
		fs::create_directories(root / d);
	for (auto const &[name, data] : files)
		put_file(root / name, data);
}


//**************************************************************************
//  The shared workload: every medium, the same requests and results
//**************************************************************************

void workload(std::string const &medium, bool folder)
{
	fs::path const path = g_dir / (folder ? medium : medium + ".img");
	std::map<std::string, bytes> files;
	{
		client c(path, folder);
		reply_t r = c.t.cmd(0x32);
		check(r.status == OK && r.u32_at(0) == 2, "%s FS2_RESET: generation 2", medium.c_str());

		auto names = c.list();
		std::sort(names.begin(), names.end());
		check(names == std::vector<std::string>{ "DOCS/", "HELLO.TXT", "SHARED/" }, "%s root listing (%zu entries)", medium.c_str(), names.size());

		// Reading, EOF and ranges
		u16 token;
		u32 size;
		bytes got;
		check(c.open_ro("HELLO.TXT", token, size) == OK && size == 13, "%s OPEN_RO HELLO.TXT: 13 bytes", medium.c_str());
		check(c.read(token, 0, 512, got) == OK && got == HELLO, "%s READ: the 13 bytes", medium.c_str());
		check(c.read(token, 13, 64, got) == OK && got.empty(), "%s READ at the end: READY 0, no transfer", medium.c_str());
		check(c.read(token, 4000, 64, got) == OK && got.empty(), "%s READ past the end of a read-only file: clipped, nothing", medium.c_str());
		check(c.read(token, 0, 513, got) == RANGE, "%s READ 513: RANGE", medium.c_str());
		check(c.close(token) == OK, "%s CLOSE", medium.c_str());
		check(c.push("DOCS") == OK, "%s PUSH DOCS", medium.c_str());
		check(c.open_ro("BIG.TXT", token, size) == OK && size == 5000, "%s OPEN_RO DOCS/BIG.TXT", medium.c_str());
		bytes run;
		for (u32 offset = 0; offset < 5000; offset += 2048)
		{
			check(c.read(token, offset, 2048, got, 0x45) == OK, "%s READ_RUN at %u", medium.c_str(), offset);
			run.insert(run.end(), got.begin(), got.end());
		}
		check(run == BIG, "%s READ_RUN: 2048 + 2048 + 904 bytes, BIG.TXT", medium.c_str());
		check(c.read(token, 100, 512, got, 0x45) == RANGE, "%s READ_RUN unaligned: RANGE", medium.c_str());
		c.close(token);
		c.root();

		// Create, write, overwrite, sync, truncate
		check(c.open_rw(1, "NEW.BIN", token, size) == OK && size == 0, "%s OPEN_RW CREATE_NEW NEW.BIN", medium.c_str());
		bytes body = pattern(1100, 0x51);
		check(c.write(token, 0, bytes(body.begin(), body.begin() + 512)) == OK &&
				c.write(token, 512, bytes(body.begin() + 512, body.begin() + 1024)) == OK &&
				c.write(token, 1024, bytes(body.begin() + 1024, body.end())) == OK, "%s three WRITEs", medium.c_str());
		check(c.sync(token) == OK, "%s SYNC", medium.c_str());
		bytes const patch = pattern(100, 0xa0);
		check(c.write(token, 200, patch) == OK, "%s overwrite at 200", medium.c_str());
		std::copy(patch.begin(), patch.end(), body.begin() + 200);
		check(c.truncate(token, 1000) == OK, "%s TRUNCATE 1000", medium.c_str());
		body.resize(1000);
		check(c.close(token) == OK, "%s CLOSE NEW.BIN", medium.c_str());
		check(c.read_file("NEW.BIN") == body, "%s NEW.BIN reads back 1000 bytes", medium.c_str());
		check(c.open_rw(0, "NEW.BIN", token, size) == OK && size == 1000, "%s OPEN_RW UPDATE: size 1000", medium.c_str());
		bytes const tail = pattern(24, 0x77);
		check(c.write(token, 1000, tail) == OK, "%s append 24 at the end", medium.c_str());
		body.insert(body.end(), tail.begin(), tail.end());
		c.close(token);

		check(c.open_rw(1, "NEW.BIN", token, size) == EXISTS, "%s CREATE_NEW of an existing file: EXISTS", medium.c_str());
		check(c.open_rw(0, "MISSING.BIN", token, size) == NOT_FOUND, "%s UPDATE of a missing file: NOT_FOUND", medium.c_str());
		check(c.open_rw(0, "DOCS", token, size) == IS_DIR && c.open_ro("DOCS", token, size) == IS_DIR, "%s a directory as a file: IS_DIR", medium.c_str());
		check(c.open_ro("BAD*.TXT", token, size) == BAD_NAME && c.open_ro("A B", token, size) == BAD_NAME, "%s bad names: BAD_NAME", medium.c_str());

		// Directories and the namespace
		check(c.st(0x43, n83("SUB")) == OK && c.st(0x43, n83("SUB")) == EXISTS, "%s MKDIR SUB, again EXISTS", medium.c_str());
		check(c.push("SUB") == OK && c.write_file("A.TXT", pattern(10, 1)), "%s SUB/A.TXT", medium.c_str());
		check(c.list() == std::vector<std::string>{ "A.TXT" }, "%s SUB lists A.TXT", medium.c_str());
		c.root();
		check(c.rename("NEW.BIN", "REN.BIN") == OK, "%s RENAME NEW.BIN REN.BIN", medium.c_str());
		check(c.rename("HELLO.TXT", "REN.BIN") == EXISTS, "%s RENAME onto an existing name: EXISTS", medium.c_str());
		check(c.rename("MISSING.BIN", "X.BIN") == NOT_FOUND, "%s RENAME of a missing name: NOT_FOUND", medium.c_str());
		check(c.st(0x44, n83("SUB")) == READ_ONLY, "%s RMDIR of a non-empty directory: READ_ONLY (FR_DENIED)", medium.c_str());
		check(c.push("SUB") == OK && c.st(0x41, n83("A.TXT")) == OK, "%s UNLINK SUB/A.TXT", medium.c_str());
		c.root();
		check(c.st(0x44, n83("SUB")) == OK, "%s RMDIR SUB", medium.c_str());
		u8 dir;
		check(c.stat("SUB", size, dir) == NOT_FOUND, "%s SUB is gone", medium.c_str());
		check(c.stat("REN.BIN", size, dir) == OK && size == 1024 && dir == 0, "%s STAT REN.BIN: 1024 bytes", medium.c_str());
		check(c.stat("DOCS", size, dir) == OK && dir == 0x10, "%s STAT DOCS: a directory", medium.c_str());
		r = c.t.cmd(0x3c);
		check(r.status == OK && r.u32_at(4) > 0 && r.u32_at(0) <= r.u32_at(4) && r.u32_at(8) <= r.u32_at(12), "%s SPACE: free <= total",
				medium.c_str());

		// A token from before FS2_RESET is stale.
		check(c.open_ro("REN.BIN", token, size) == OK, "%s OPEN_RO REN.BIN", medium.c_str());
		c.t.cmd(0x32);
		check(c.read(token, 0, 16, got) == STALE, "%s token of an earlier generation: STALE", medium.c_str());

		// The legacy /SHARED folder, and FS2 seeing what it wrote
		r = c.t.cmd(0x20);
		check(r.status == OK, "%s FS_OPENDIR", medium.c_str());
		r = c.t.cmd(0x21);
		check(r.status == OK && bytes(r.data.begin(), r.data.begin() + 11) == n83("NOTE.TXT") && r.u32_at(12) == 300,
				"%s FS_READDIR: NOTE.TXT 300 bytes", medium.c_str());
		r = c.t.cmd(0x21);
		check(r.status == OK && r.data[16] == 0, "%s FS_READDIR: the end", medium.c_str());
		r = c.t.cmd(0x22, cat({ { 1 }, n83("OUT.TXT") }));
		u8 const h = r.data[0];
		check(r.status == OK && r.u32_at(1) == 0, "%s FS_OPEN write OUT.TXT", medium.c_str());
		bytes const out = pattern(700, 0x33);
		r = c.t.cmd(0x24, cat({ { h }, le32(0), le16(512) }));
		c.t.give(bytes(out.begin(), out.begin() + 512), 0x24, c.t.seq);
		check(c.t.done().data[1] == OK, "%s FS_WRITE 512", medium.c_str());
		r = c.t.cmd(0x24, cat({ { h }, le32(512), le16(188) }));
		c.t.give(bytes(out.begin() + 512, out.end()), 0x24, c.t.seq);
		check(c.t.done().data[1] == OK, "%s FS_WRITE 188", medium.c_str());
		check(c.st(0x25, cat({ { h }, le32(650) })) == OK, "%s FS_CLOSE at 650 bytes", medium.c_str());
		r = c.t.cmd(0x26, n83("OUT.TXT"));
		check(r.status == OK && r.u32_at(0) == 650, "%s FS_STAT OUT.TXT: 650", medium.c_str());
		r = c.t.cmd(0x22, cat({ { 0 }, n83("NOTE.TXT") }));
		r = c.t.cmd(0x23, cat({ { r.data[0] }, le32(0), le16(512) }));
		check(r.status == OK && c.t.take_all(0xa3, c.t.seq) == NOTE, "%s FS_READ NOTE.TXT", medium.c_str());
		check(c.st(0x27, n83("NOTE.TXT")) == OK && c.t.cmd(0x26, n83("NOTE.TXT")).status == 0x34, "%s FS_DELETE NOTE.TXT", medium.c_str());
		r = c.t.cmd(0x28);
		u16 sum = 0;
		for (unsigned i = 0; i < 650; i++)
			sum += out[i];
		check(r.status == OK && r.data[0] == 1 && r.u16_at(8) == 1 && r.u16_at(10) == sum && r.u32_at(12) == 650,
				"%s FS_SELFTEST: mounted, 1 file, OUT.TXT's sum and length", medium.c_str());
		check(c.push("SHARED") == OK && c.read_file("OUT.TXT") == bytes(out.begin(), out.begin() + 650), "%s FS2 reads /SHARED/OUT.TXT",
				medium.c_str());
		c.root();

		files = { { "HELLO.TXT", HELLO }, { "DOCS/BIG.TXT", BIG }, { "REN.BIN", body },
				{ "SHARED/OUT.TXT", bytes(out.begin(), out.begin() + 650) } };
		expect(medium, files, { "DOCS", "SHARED" });
	}
	// Exit and reopen: a new socket on the same media reads it all back.
	client again(path, folder);
	again.t.cmd(0x32);
	for (auto const &[name, data] : files)
	{
		size_t const slash = name.find('/');
		if (slash != std::string::npos)
			again.push(name.substr(0, slash));
		check(again.read_file(name.substr(slash == std::string::npos ? 0 : slash + 1)) == data, "%s reopened: %s", medium.c_str(), name.c_str());
		again.root();
	}
}

void workload_fat16() { workload("fat16", false); }
void workload_fat32() { workload("fat32", false); }
void workload_mbr32() { workload("mbr32", false); }
void workload_folder() { workload("folder", true); }


//**************************************************************************
//  Read-only and full media
//**************************************************************************

void read_only(fs::path const &path, bool folder)
{
	client c(path, folder);
	u16 token;
	u32 size;
	char const *what = folder ? "read-only folder" : "read-only image";
	check(c.read_file("HELLO.TXT") == HELLO, "%s: reads work", what);
	check(c.open_rw(2, "NEW.TXT", token, size) == READ_ONLY && c.open_rw(0, "HELLO.TXT", token, size) == READ_ONLY,
			"%s: OPEN_RW READ_ONLY (FR_WRITE_PROTECTED)", what);
	check(c.st(0x43, n83("D")) == READ_ONLY && c.st(0x41, n83("HELLO.TXT")) == READ_ONLY && c.rename("HELLO.TXT", "X.TXT") == READ_ONLY,
			"%s: MKDIR, UNLINK, RENAME READ_ONLY", what);
	reply_t r = c.t.cmd(0x22, cat({ { 1 }, n83("OUT.TXT") }));
	check(r.status == FS_ERROR, "%s: FS_OPEN for writing FS_ERROR (%02X)", what, r.status);
	check(c.st(0x27, n83("NOTE.TXT")) == FS_ERROR, "%s: FS_DELETE FS_ERROR", what);
	if (!folder)
	{
		// The auto-mount has run (no CPM_1.DRV), so record access gets the raw unit.
		bytes before, got;
		check(c.read_rec(3, 0, before) == OK && c.write_rec(3, 0, pattern(128, 7)) == SD_WRITE_REJ &&
				c.read_rec(3, 0, got) == OK && got == before && c.t.media.card_ready(),
				"%s: a raw record write is refused (SD_WRITE_REJ), the record unchanged, the session kept", what);
	}
}

void read_only_media()
{
	read_only(g_dir / "ro.img", false);
}

void read_only_folder()
{
	read_only(g_dir / "ro_folder", true);
}

void full_image()
{
	client c(g_dir / "small16.img");
	u16 token;
	u32 size;
	check(c.open_rw(2, "FILL.BIN", token, size) == OK, "small FAT16: create FILL.BIN");
	bytes const chunk = pattern(512, 0x10);
	u32 offset = 0;
	u8 status = OK;
	for (; offset < (8u << 20) && (status = c.write(token, offset, chunk)) == OK; offset += 512) { }
	check(status == NO_SPACE, "the write that does not fit: DONE NO_SPACE (%02X at %u)", status, offset);
	check(c.close(token) == OK, "CLOSE after a full volume");
	reply_t r = c.t.cmd(0x3c);
	check(r.status == OK && r.u32_at(0) == 0, "SPACE: no free bytes (%u)", r.u32_at(0));
	u8 dir;
	check(c.stat("FILL.BIN", size, dir) == OK && size >= offset && size < offset + 512, "FILL.BIN holds what fit (%u)", size);
	check(c.st(0x41, n83("FILL.BIN")) == OK && c.t.cmd(0x3c).u32_at(0) > offset / 2, "UNLINK frees the space");
}

// A full folder: the host refuses the bytes past a file-size limit
// (RLIMIT_FSIZE, EFBIG), as a full card refuses clusters.
void full_folder()
{
	client c(g_dir / "full_folder", true);
	u16 token;
	u32 size;
	check(c.open_rw(2, "FILL.BIN", token, size) == OK, "folder: create FILL.BIN");
	std::signal(SIGXFSZ, SIG_IGN);
	rlimit saved;
	getrlimit(RLIMIT_FSIZE, &saved);
	rlimit limit = saved;
	limit.rlim_cur = 65536 + 100;
	setrlimit(RLIMIT_FSIZE, &limit);
	bytes const chunk = pattern(512, 0x10);
	u32 offset = 0;
	u8 status = OK;
	for (; offset < (1u << 20) && (status = c.write(token, offset, chunk)) == OK; offset += 512) { }
	setrlimit(RLIMIT_FSIZE, &saved);
	check(status == NO_SPACE && offset == 65536, "folder: the write past the limit is short: NO_SPACE (%02X at %u)", status, offset);
	c.close(token);
	check(fs::file_size(g_dir / "full_folder" / "FILL.BIN") == 65536 + 100, "folder: FILL.BIN holds what the host accepted");
}


//**************************************************************************
//  Raw cards, raw coherence and media changes (image only)
//**************************************************************************

void raw_card()
{
	bytes const image = file_bytes(g_dir / "raw.img");
	{
		client c(g_dir / "raw.img");
		bytes got;
		check(c.read_rec(5, 0, got) == OK && got == bytes(image.begin() + 640, image.begin() + 768), "first record access: raw unit 0, record 5");
		reply_t r = c.vol_info(0);
		check(r.data[1] == 0, "the auto-mount found no CPM_1.DRV: unit 0 unmounted (owner-confirmed board behaviour)");
		check(c.read_rec(5, 0, got) == VOL_UNMOUNTED, "the next record access: VOL_UNMOUNTED");
		r = c.t.cmd(0x03);
		check(r.status == OK && r.data == bytes(image.begin(), image.begin() + 16), "raw card SD_READ: block 0's first 16 bytes");
		check(c.st(0x38) == NO_MEDIA, "no FAT: FS2 NO_MEDIA");
	}
	{
		client c(g_dir / "raw.img");
		check(c.write_rec(9, 0, pattern(128, 0x99)) == OK, "raw card: a first-access record write lands on the raw unit");
		check(c.st(0x0a) == OK, "SD_FLUSH");
		g_records << "raw.img " << 9 * 128 << " " << hex(pattern(128, 0x99)) << "\n";
	}
	{
		client c(g_dir / "raw.img");
		bytes got;
		check(c.read_rec(70000, 0, got) == VOL_RANGE, "record 70000 of the raw unit: VOL_RANGE");
	}
	{
		// A card smaller than the 8 MiB raw unit: reading past its end fails
		// the card access (SD_READ_FAIL) and ends the session.
		client c(g_dir / "raw_small.img");
		bytes got;
		check(c.read_rec(40000, 0, got) == SD_READ_FAIL && !c.t.media.card_ready(), "past the card's end: SD_READ_FAIL, session over");
	}
}

// A raw write to the block FatFs holds dirty in its window: the window is
// written back first and reloaded after, so neither side loses the other's
// bytes.
void raw_coherence()
{
	client c(g_dir / "coherent.img");
	u16 token;
	u32 size;
	check(c.open_rw(2, "C.BIN", token, size) == OK && c.write(token, 0, bytes(100, 'A')) == OK && c.sync(token) == OK,
			"coherence: C.BIN with 100 bytes, synced");
	bytes got;
	u32 block = 0;
	for (; block < 16384; block++)
		if (c.read_block(block, 0, got) == OK && bytes(got.begin(), got.begin() + 100) == bytes(100, 'A'))
			break;
	check(block < 16384, "C.BIN's data block found through the raw unit (%u)", block);
	check(c.write(token, 0, bytes(100, 'B')) == OK, "FS2 write: the block is dirty in the FatFs window");
	check(c.write_rec(block * 4, 0, bytes(128, 'C')) == OK, "raw record write to that block");
	check(c.close(token) == OK, "FS2 CLOSE (sync)");
	check(c.read_block(block, 0, got) == OK && bytes(got.begin(), got.begin() + 128) == bytes(128, 'C'),
			"the raw write survives the sync (the window did not overwrite it)");
	check(c.read_file("C.BIN") == bytes(100, 'C'), "FS2 reads the raw write (the window was reloaded)");
	expect("coherent", { { "HELLO.TXT", HELLO }, { "DOCS/BIG.TXT", BIG }, { "SHARED/NOTE.TXT", NOTE }, { "C.BIN", bytes(100, 'C') } },
			{ "DOCS", "SHARED" });
}

// A media change is noticed only through a failing access.
void media_change()
{
	client c(g_dir / "change_a.img");
	u16 token;
	u32 size;
	check(c.open_ro("HELLO.TXT", token, size) == OK, "change: HELLO.TXT open on card A");
	u32 const generation = c.t.cmd(0x31).u32_at(0);
	c.t.media.eject();
	check(c.t.cmd(0x31).u32_at(0) == generation, "removal alone: no detection, generation unchanged");
	bytes got;
	check(c.read(token, 0, 16, got) == IO, "the first read with the socket empty fails: IO (FR_DISK_ERR)");
	check(c.t.cmd(0x31).u32_at(0) == generation + 1 && !c.t.media.card_ready(), "then the generation advanced and the session ended");
	check(c.read(token, 0, 16, got) == STALE, "the old token: STALE");
	check(c.open_ro("HELLO.TXT", token, size) == NO_MEDIA, "with no card: NO_MEDIA");
	check(c.t.media.insert_image((g_dir / "change_b.img").string()).empty(), "insert card B");
	check(c.read_file("HELLO.TXT") == bytes(13, 'b'), "card B mounts fresh: its HELLO.TXT");

	// A swap the controller does not see: the session survives it, and a
	// write with nothing read first (the FatFs window's write-back) fails and
	// ends the session; the card swapped in is untouched.
	check(c.open_rw(2, "W.BIN", token, size) == OK && c.write(token, 0, bytes(100, 'w')) == OK, "W.BIN on card B, its data pending in the window");
	u32 const before = c.t.cmd(0x31).u32_at(0);
	c.t.media.eject();
	check(c.t.media.insert_image((g_dir / "change_a.img").string()).empty() && c.t.media.card_ready(), "swap to A between commands: the session stays up");
	check(c.sync(token) == IO && !c.t.media.card_ready(), "the write-back to the swapped card fails: IO, session over");
	check(c.t.cmd(0x31).u32_at(0) == before + 1 && c.read(token, 0, 16, got) == STALE, "generation advanced; the token is STALE");
	check(file_bytes(g_dir / "change_a.img") == file_bytes(g_dir / "change_a.orig"), "card A unchanged");
	check(c.read_file("HELLO.TXT") == bytes(13, 'a'), "remounted: card A's HELLO.TXT");
}

// The controller restarts: every object and the session go; media stay.
void controller_reset()
{
	client c(g_dir / "change_b.img");
	u16 token;
	u32 size;
	check(c.open_ro("HELLO.TXT", token, size) == OK, "reset: HELLO.TXT open");
	c.t.core.reset();
	bytes got;
	check(!c.t.media.card_ready() && c.read(token, 0, 16, got) == 0x48, "after a controller reset the session is gone and the token unknown (NO_HANDLE)");
	check(c.read_file("HELLO.TXT") == bytes(13, 'b'), "and the card mounts again");
}


//**************************************************************************
//  Folder names, collisions, traversal and links
//**************************************************************************

void folder_names()
{
	client c(g_dir / "names", true);
	c.t.cmd(0x32);
	auto const names = c.list();
	check(names == std::vector<std::string>{ "MIXED.TXT", "README.TXT", "SUB/", "UPPER.TXT" },
			"listing: 8.3 names upper-cased, in 8.3 order; long, spaced, dot, non-ASCII, colliding and linked names absent (%zu)", names.size());
	check(c.read_file("readme.txt") == bytes{ 'r' } && c.read_file("README.TXT") == bytes{ 'r' }, "lookup is case-insensitive");
	u16 token;
	u32 size;
	check(c.open_ro("DUP.TXT", token, size) == READ_ONLY && c.open_rw(2, "dup.txt", token, size) == READ_ONLY && c.st(0x41, n83("DUP.TXT")) == READ_ONLY,
			"dup.txt and DUP.TXT collide: every use is refused (READ_ONLY, FR_DENIED), neither is chosen");
	check(c.open_ro("LINK.TXT", token, size) == NOT_FOUND && c.push("LINKDIR") == NOT_FOUND, "symbolic links are not on the card");
	check(c.push("..") == BAD_NAME && c.open_ro("..", token, size) == BAD_NAME, "'..' is not a name");
	{
		zephyr80_ioc_storage::entry info;
		auto &s = c.t.media;
		check(s.stat("/../OUTSIDE.TXT", info) == zephyr80_ioc_storage::fr::INVALID_NAME &&
				s.stat("/SUB/../../OUTSIDE.TXT", info) == zephyr80_ioc_storage::fr::INVALID_NAME &&
				s.stat("/SUB/./INNER.TXT", info) == zephyr80_ioc_storage::fr::INVALID_NAME,
				"socket paths with '.' or '..' segments: INVALID_NAME");
		check(s.stat("/SUB/INNER.TXT", info) == zephyr80_ioc_storage::fr::OK && info.size == 5, "an ordinary nested path resolves");
	}
	check(c.write_file("new.txt", { 1, 2, 3 }) && fs::exists(g_dir / "names" / "NEW.TXT"), "a new file takes its upper-case 8.3 host name");
	check(c.rename("Mixed.Txt", "RENAMED.TXT") == OK && fs::exists(g_dir / "names" / "RENAMED.TXT") && !fs::exists(g_dir / "names" / "Mixed.Txt"),
			"RENAME gives the host entry the new 8.3 name");
	check(c.push("SUB") == OK && c.st(0x41, n83("INNER.TXT")) == OK, "UNLINK SUB/INNER.TXT");
	c.root();
	check(c.st(0x44, n83("SUB")) == READ_ONLY && fs::exists(g_dir / "names" / "SUB" / "long name.txt"),
			"RMDIR of a directory holding only names the card does not show: DENIED, the host file kept");
}


//**************************************************************************
//  CP/M volumes
//**************************************************************************

struct vol_layout
{
	u32 base[2] = { 0, 0 };
	u8 extents[2] = { 0, 0 };
};

vol_layout read_layout(fs::path const &path)
{
	vol_layout v;
	std::ifstream f(path);
	std::string name;
	u32 base, extents;
	while (f >> name >> base >> extents)
	{
		unsigned const unit = name == "CPM_1.DRV" ? 0 : 1;
		v.base[unit] = base;
		v.extents[unit] = u8(extents);
	}
	return v;
}

void volumes(std::string const &medium, bool folder)
{
	fs::path const path = g_dir / medium;
	vol_layout const want = folder ? vol_layout{ { 0, 0 }, { 1, 1 } } : read_layout(g_dir / (medium + ".layout"));
	client c(path, folder);
	char const *m = medium.c_str();
	reply_t r = c.vol_info(0);
	check(r.status == OK && r.data[1] == 0, "%s before the card is up: unit 0 unmounted", m);
	r = c.t.cmd(0x03);
	check(r.status == OK && r.data.size() == 16, "%s SD_READ (the ZSDOS card probe): OK", m);
	for (u8 unit = 0; unit < 2; unit++)
	{
		r = c.vol_info(unit);
		check(r.status == OK && r.data[1] == 2 && r.data[2] == want.extents[unit] && r.u32_at(3) == want.base[unit] && r.u32_at(7) == 65536 &&
				bytes(r.data.begin() + 11, r.data.begin() + 22) == n83(unit ? "CPM_2.DRV" : "CPM_1.DRV"),
				"%s auto-mount: unit %u file mode, %u extents, base %u, 65536 records (got mode %u, %u extents, base %u)", m, unit,
				want.extents[unit], want.base[unit], r.data[1], r.data[2], r.u32_at(3));
	}
	// Records across the extents of unit 1, and the ends of both units.
	std::vector<u32> const records = { 0, 1, 3, 4, 1023, 1024, 4095, 4096, 21845, 21846, 32767, 32768, 43690, 50000, 65532, 65535 };
	bytes got;
	for (u32 rec : records)
	{
		bytes const data = pattern(128, u8(rec * 3 + 1));
		check(c.write_rec(rec, 1, data) == OK && c.read_rec(rec, 1, got) == OK && got == data, "%s unit 1 record %u written and read", m, rec);
		g_records << medium << (folder ? "/" : ":/") << "CPM/CPM_2.DRV " << u64(rec) * 128 << " " << hex(data) << "\n";
	}
	bytes const last = pattern(128, 0xc1);
	check(c.write_rec(65535, 0, last) == OK, "%s unit 0 last record", m);
	g_records << medium << (folder ? "/" : ":/") << "CPM/CPM_1.DRV " << u64(65535) * 128 << " " << hex(last) << "\n";
	check(c.read_block(1024, 1, got) == OK && bytes(got.begin(), got.begin() + 128) == pattern(128, u8(4096 * 3 + 1)), "%s SD_READ_BLOCK unit 1 block 1024", m);
	check(c.read_rec(65536, 1, got) == VOL_RANGE && c.read_block(16384, 0, got) == VOL_RANGE && c.read_rec(0, 2, got) == VOL_UNMOUNTED,
			"%s record 65536, block 16384: VOL_RANGE; unit 2: VOL_UNMOUNTED", m);
	check(c.write_rec(65536, 1, pattern(128, 1)) == VOL_RANGE, "%s a write past the end: DONE VOL_RANGE", m);
	bytes before;
	c.read_rec(77, 1, before);
	check(c.write_rec(77, 1, pattern(128, 0xee), 5) == BULK_NO_SYNC && c.read_rec(77, 1, got) == OK && got == before,
			"%s a cut write: DONE BULK_NO_SYNC, the record unchanged", m);

	// FS2 and the volume see one file.
	check(c.push("CPM") == OK, "%s PUSH CPM", m);
	u16 token;
	u32 size;
	check(c.open_ro("CPM_2.DRV", token, size) == OK && size == (8u << 20), "%s FS2 opens /CPM/CPM_2.DRV", m);
	check(c.read(token, 4096 * 128, 128, got) == OK && got == pattern(128, u8(4096 * 3 + 1)), "%s FS2 reads record 4096's bytes", m);
	c.close(token);
	bytes const via_fs2 = pattern(128, 0x5e);
	check(c.open_rw(0, "CPM_2.DRV", token, size) == OK && c.write(token, 7 * 128, via_fs2) == OK && c.close(token) == OK, "%s FS2 writes record 7", m);
	check(c.read_rec(7, 1, got) == OK && got == via_fs2, "%s the volume reads FS2's write", m);
	g_records << medium << (folder ? "/" : ":/") << "CPM/CPM_2.DRV " << 7 * 128 << " " << hex(via_fs2) << "\n";
	c.root();

	// VOL_MOUNT: wrong size, missing, too fragmented; the unit is dropped first.
	check(c.vol_mount(1, "BAD.DRV") == VOL_BAD_IMAGE && c.vol_info(1).data[1] == 0 && c.read_rec(0, 1, got) == VOL_UNMOUNTED,
			"%s VOL_MOUNT BAD.DRV (4 MiB): VOL_BAD_IMAGE, unit 1 unmounted", m);
	check(c.vol_mount(1, "NONE.DRV") == 0x10, "%s VOL_MOUNT of a missing image: SD_NO_RESPONSE", m);
	if (!folder)
		check(c.vol_mount(1, "FRAG.DRV") == VOL_BAD_IMAGE, "%s VOL_MOUNT FRAG.DRV (17 extents): VOL_BAD_IMAGE (FATMAP_FRAGMENTED)", m);
	check(c.vol_mount(1, "CPM_2.DRV") == OK && c.read_rec(7, 1, got) == OK && got == via_fs2, "%s VOL_MOUNT CPM_2.DRV again", m);
	check(c.vol_mount(2, "CPM_2.DRV") == VOL_UNMOUNTED, "%s VOL_MOUNT unit 2: VOL_UNMOUNTED", m);
}

void volumes_image() { volumes("vol.img", false); }
void volumes_folder() { volumes("vol_folder", true); }

// Folder media have no card blocks: no raw unit, while volume files work.
void folder_raw()
{
	client c(g_dir / "folder", true);
	reply_t r = c.t.cmd(0x03);
	check(r.status == OK && r.data == bytes(16, 0), "folder SD_READ: the card answers, block 0 blank");
	bytes got;
	check(c.read_rec(0, 0, got) == VOL_UNMOUNTED && c.read_block(0, 0, got) == VOL_UNMOUNTED, "folder: no raw unit (VOL_UNMOUNTED)");
	check(c.vol_info(0).data[1] == 0, "folder: VOL_INFO unit 0 unmounted");
	check(c.write_rec(0, 0, pattern(128, 1)) == VOL_UNMOUNTED, "folder: a raw record write is refused");
}

void read_only_volume()
{
	client c(g_dir / "vol_ro", true);
	c.t.cmd(0x03);
	bytes got, before;
	check(c.read_rec(10, 0, before) == OK, "read-only volume file: reads work");
	check(c.write_rec(10, 0, pattern(128, 2)) == SD_WRITE_REJ && c.read_rec(10, 0, got) == OK && got == before && c.t.media.card_ready(),
			"read-only volume file: DONE SD_WRITE_REJ, unchanged, session kept");
}

} // anonymous namespace

int main(int argc, char **argv)
{
	if (argc < 2)
	{
		std::fprintf(stderr, "usage: card_test MEDIA_DIR [TEST...]\n");
		return 2;
	}
	g_dir = argv[1];
	g_records.open(g_dir / "records.txt");
	std::vector<test> const tests = {
		{ "workload-fat16", workload_fat16 },
		{ "workload-fat32", workload_fat32 },
		{ "workload-mbr32", workload_mbr32 },
		{ "workload-folder", workload_folder },
		{ "read-only-image", read_only_media },
		{ "read-only-folder", read_only_folder },
		{ "full-image", full_image },
		{ "full-folder", full_folder },
		{ "raw-card", raw_card },
		{ "raw-coherence", raw_coherence },
		{ "media-change", media_change },
		{ "controller-reset", controller_reset },
		{ "folder-names", folder_names },
		{ "volumes-image", volumes_image },
		{ "volumes-folder", volumes_folder },
		{ "folder-raw", folder_raw },
		{ "read-only-volume", read_only_volume },
	};
	// Further arguments name the tests to run; none runs them all.
	std::vector<test> selected;
	for (auto const &t : tests)
		if (argc == 2 || std::any_of(argv + 2, argv + argc, [&t] (char const *name) { return !std::strcmp(name, t.name); }))
			selected.push_back(t);
	return run_tests(selected);
}
