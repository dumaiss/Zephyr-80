// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: an in-memory card for the IOC core tests.  It answers the
// zephyr80_ioc_storage contract with FatFs semantics where the core depends
// on them (f_lseek clipping and growth, short writes on a full volume,
// FR_DENIED for a non-empty directory, invalid objects after an unmount);
// it is not a FAT implementation and not a production backend.
#ifndef ZEPHYR80_TESTS_IOC_CORE_MEMORY_STORAGE_H
#define ZEPHYR80_TESTS_IOC_CORE_MEMORY_STORAGE_H

#include "emu.h"
#include "zephyr80_ioc_storage.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <map>
#include <string>
#include <vector>

class memory_storage : public zephyr80_ioc_storage
{
public:
	struct node
	{
		bool dir = false;
		std::vector<u8> data;
	};

	// Media state, set by the tests.
	bool present = true;      // a card in the socket
	bool fat = true;          // carries a FAT volume
	bool raw = true;          // has card blocks (false: a host folder)
	bool read_only = false;   // writes are refused (FR_WRITE_PROTECTED)
	u32 capacity = 1u << 20;  // bytes the volume holds
	fr fail_next = fr::OK;    // the next filesystem call answers this
	u32 generation = 1;

	std::map<std::string, node> tree;    // upper-case absolute path -> node
	std::vector<std::string> order;      // creation order (directory order)
	std::vector<std::vector<u8>> blocks; // raw card blocks
	std::map<std::string, std::vector<u8>> images; // "/CPM/NAME.EXT" -> bytes

	memory_storage() : blocks(32, std::vector<u8>(BLOCK_BYTES, 0)) { tree["/"].dir = true; }

	void add_dir(std::string const &path) { put(path).dir = true; }
	void add_file(std::string const &path, std::vector<u8> data) { put(path).data = std::move(data); }
	std::vector<u8> const *file(std::string const &path) const
	{
		auto it = tree.find(upper(path));
		return (it == tree.end() || it->second.dir) ? nullptr : &it->second.data;
	}
	void replace_media() { generation++; ready = false; mounted = false; for (auto &o : objects) o.valid = false; }
	unsigned open_objects() const { return unsigned(std::count_if(objects.begin(), objects.end(), [] (obj const &o) { return o.used; })); }

	// A digest of everything on the media, for "unchanged" checks.
	std::string snapshot() const
	{
		std::string s;
		for (auto const &[path, n] : tree)
			s += path + (n.dir ? "/" : "=") + std::string(n.data.begin(), n.data.end()) + "\n";
		for (auto const &b : blocks)
			s.append(b.begin(), b.end());
		for (auto const &[path, d] : images)
			s += path + std::string(d.begin(), d.end());
		return s;
	}

	// --- card ------------------------------------------------------------
	virtual card card_init() override
	{
		if (!present)
		{
			ready = false;
			return card::NO_CARD;
		}
		ready = true;
		return card::OK;
	}
	virtual bool card_ready() const override { return ready; }
	virtual u32 media_generation() const override { return generation; }
	virtual void controller_reset() override { objects.clear(); mounted = false; ready = false; }
	virtual bool raw_blocks() const override { return raw; }
	virtual card block_read(u32 lba, u8 *data) override
	{
		card const st = card_init();
		if (st != card::OK)
			return st;
		if (!raw || lba >= blocks.size())
			return card::READ;
		std::copy(blocks[lba].begin(), blocks[lba].end(), data);
		return card::OK;
	}
	virtual card block_write(u32 lba, u8 const *data) override
	{
		card const st = card_init();
		if (st != card::OK)
			return st;
		if (!raw || lba >= blocks.size())
			return card::WRITE;
		std::copy(data, data + BLOCK_BYTES, blocks[lba].begin());
		return card::OK;
	}
	virtual card flush() override { return card::OK; }

	// --- filesystem --------------------------------------------------------
	virtual card fs_mount(bool &is_mounted) override
	{
		is_mounted = false;
		card const st = card_init();
		if (st != card::OK)
			return st;
		mounted = fat;
		is_mounted = mounted;
		return card::OK;
	}
	virtual void fs_unmount() override
	{
		mounted = false;
		for (auto &o : objects)
			if (o.kind != IMAGE)
				o.valid = false;
	}
	virtual fr fs_geometry(geometry &info) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		info.fs_type = 3;
		info.cluster_blocks = 8;
		info.data_base = 0x2000;
		info.clusters = capacity / 4096;
		info.free_clusters = (capacity - std::min(capacity, used())) / 4096;
		return fr::OK;
	}
	virtual fr stat(char const *path, entry &info) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		std::string const p = upper(path);
		auto it = tree.find(p);
		if (it == tree.end())
			return parent_exists(p) ? fr::NO_FILE : fr::NO_PATH;
		fill(info, p, it->second);
		return fr::OK;
	}
	virtual fr open(char const *path, u8 mode, object &file) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		std::string const p = upper(path);
		if (!parent_exists(p))
			return fr::NO_PATH;
		auto it = tree.find(p);
		bool const writing = mode & OPEN_WRITE;
		if (writing && read_only)
			return fr::WRITE_PROTECTED;
		if (it != tree.end() && it->second.dir)
			return (mode & (OPEN_CREATE_NEW | OPEN_CREATE_ALWAYS)) ? fr::DENIED : fr::NO_FILE;
		if (mode & OPEN_CREATE_NEW)
		{
			if (it != tree.end())
				return fr::EXIST;
			put(p);
		}
		else if (mode & OPEN_CREATE_ALWAYS)
		{
			put(p).data.clear();
		}
		else if (it == tree.end())
		{
			return fr::NO_FILE;
		}
		return allocate(obj{ true, true, FILE, p, 0, writing, 0, {} }, file);
	}
	virtual fr close(object file) override
	{
		if (file >= objects.size() || !objects[file].used)
			return fr::INVALID_OBJECT;
		bool const valid = objects[file].valid;
		objects[file].used = false;
		return valid ? fr::OK : fr::INVALID_OBJECT;
	}
	virtual u32 size(object file) const override
	{
		obj const *o = lookup(file, FILE);
		return o ? u32(tree.at(o->path).data.size()) : 0;
	}
	virtual fr seek(object file, u32 offset) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		obj *o = lookup(file, FILE);
		if (!o)
			return fr::INVALID_OBJECT;
		auto &data = tree.at(o->path).data;
		if (offset > data.size())
		{
			if (!o->writable)
				offset = u32(data.size());
			else
				data.resize(std::min<u32>(offset, data.size() + room()), 0);
		}
		o->pos = std::min<u32>(offset, u32(data.size()));
		return fr::OK;
	}
	virtual fr read(object file, u8 *data, u16 length, u16 &done) override
	{
		done = 0;
		if (fr const f = gate(); f != fr::OK)
			return f;
		obj *o = lookup(file, FILE);
		if (!o)
			return fr::INVALID_OBJECT;
		auto const &d = tree.at(o->path).data;
		done = u16(std::min<size_t>(length, d.size() - std::min<size_t>(o->pos, d.size())));
		std::copy_n(d.begin() + o->pos, done, data);
		o->pos += done;
		return fr::OK;
	}
	virtual fr write(object file, u8 const *data, u16 length, u16 &done) override
	{
		done = 0;
		if (fr const f = gate(); f != fr::OK)
			return f;
		obj *o = lookup(file, FILE);
		if (!o)
			return fr::INVALID_OBJECT;
		if (!o->writable)
			return fr::DENIED;
		auto &d = tree.at(o->path).data;
		size_t const end = o->pos + length;
		size_t const grow = end > d.size() ? end - d.size() : 0;
		size_t const take = length - (grow - std::min<size_t>(grow, room()));
		if (o->pos + take > d.size())
			d.resize(o->pos + take);
		std::copy_n(data, take, d.begin() + o->pos);
		o->pos += u32(take);
		done = u16(take);
		return fr::OK;
	}
	virtual fr truncate(object file) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		obj *o = lookup(file, FILE);
		if (!o)
			return fr::INVALID_OBJECT;
		if (!o->writable)
			return fr::DENIED;
		tree.at(o->path).data.resize(o->pos);
		return fr::OK;
	}
	virtual fr sync(object file) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		return lookup(file, FILE) ? fr::OK : fr::INVALID_OBJECT;
	}
	virtual fr opendir(char const *path, object &dir) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		std::string const p = upper(path);
		auto it = tree.find(p);
		if (it == tree.end() || !it->second.dir)
			return fr::NO_PATH;
		obj o{ true, true, DIR, p, 0, false, 0, {} };
		for (auto const &name : order)
			if (name != p && parent_of(name) == p && tree.count(name))
				o.listing.push_back(name);
		return allocate(o, dir);
	}
	virtual fr readdir(object dir, entry &info) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		obj *o = lookup(dir, DIR);
		if (!o)
			return fr::INVALID_OBJECT;
		while (o->next < o->listing.size() && !tree.count(o->listing[o->next]))
			o->next++;
		if (o->next >= o->listing.size())
		{
			info = entry{};
			return fr::OK;
		}
		std::string const &p = o->listing[o->next++];
		fill(info, p, tree.at(p));
		return fr::OK;
	}
	virtual fr closedir(object dir) override { return close(dir); }
	virtual fr unlink(char const *path) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		if (read_only)
			return fr::WRITE_PROTECTED;
		std::string const p = upper(path);
		auto it = tree.find(p);
		if (it == tree.end())
			return parent_exists(p) ? fr::NO_FILE : fr::NO_PATH;
		if (it->second.dir)
			for (auto const &[name, n] : tree)
				if (name != p && parent_of(name) == p)
					return fr::DENIED;
		tree.erase(it);
		return fr::OK;
	}
	virtual fr mkdir(char const *path) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		if (read_only)
			return fr::WRITE_PROTECTED;
		std::string const p = upper(path);
		if (!parent_exists(p))
			return fr::NO_PATH;
		if (tree.count(p))
			return fr::EXIST;
		add_dir(p);
		return fr::OK;
	}
	virtual fr rename(char const *from, char const *to) override
	{
		if (fr const f = gate(); f != fr::OK)
			return f;
		if (read_only)
			return fr::WRITE_PROTECTED;
		std::string const a = upper(from), b = upper(to);
		auto it = tree.find(a);
		if (it == tree.end())
			return fr::NO_FILE;
		if (tree.count(b))
			return fr::EXIST;
		node n = it->second;
		tree.erase(it);
		put(b) = n;
		return fr::OK;
	}

	// --- volume images -----------------------------------------------------
	virtual image_status image_open(u8 const *dir11, u8 const *name11, u32 bytes, image &info, object &img) override
	{
		if (!present)
			return image_status::IO;
		if (!fat)
			return image_status::NO_FS;
		std::string const p = "/" + unpack(dir11) + "/" + unpack(name11);
		auto it = images.find(p);
		if (it == images.end())
			return image_status::NO_FILE;
		if (it->second.size() != bytes)
			return image_status::BAD_SIZE;
		info.extents = 1;
		info.base_lba = 0x4000;
		return allocate(obj{ true, true, IMAGE, p, 0, true, 0, {} }, img) == fr::OK ? image_status::OK : image_status::IO;
	}
	virtual void image_close(object img) override { close(img); }
	virtual card image_read(object img, u32 block, u8 *data) override
	{
		obj *o = lookup(img, IMAGE);
		if (!o || u64(block + 1) * BLOCK_BYTES > images.at(o->path).size())
			return card::READ;
		std::copy_n(images.at(o->path).begin() + block * BLOCK_BYTES, BLOCK_BYTES, data);
		return card::OK;
	}
	virtual card image_write(object img, u32 block, u8 const *data) override
	{
		obj *o = lookup(img, IMAGE);
		if (!o || u64(block + 1) * BLOCK_BYTES > images.at(o->path).size())
			return card::WRITE;
		std::copy_n(data, BLOCK_BYTES, images.at(o->path).begin() + block * BLOCK_BYTES);
		return card::OK;
	}

private:
	enum kind_t : u8 { FILE, DIR, IMAGE };
	struct obj
	{
		bool used;
		bool valid;
		kind_t kind;
		std::string path;
		u32 pos;
		bool writable;
		size_t next;
		std::vector<std::string> listing;
	};

	bool ready = false;
	bool mounted = false;
	std::vector<obj> objects;

	static std::string upper(std::string s)
	{
		for (auto &c : s)
			c = char(std::toupper(u8(c)));
		return s;
	}
	static std::string parent_of(std::string const &p)
	{
		size_t const slash = p.rfind('/');
		return slash == 0 ? "/" : p.substr(0, slash);
	}
	static std::string unpack(u8 const *name11)
	{
		std::string s;
		for (unsigned i = 0; i < 8 && name11[i] != ' '; i++)
			s += char(name11[i]);
		if (name11[8] != ' ')
		{
			s += '.';
			for (unsigned i = 8; i < 11 && name11[i] != ' '; i++)
				s += char(name11[i]);
		}
		return s;
	}
	bool parent_exists(std::string const &p) const
	{
		auto it = tree.find(parent_of(p));
		return it != tree.end() && it->second.dir;
	}
	node &put(std::string const &path)
	{
		std::string const p = upper(path);
		if (!tree.count(p))
			order.push_back(p);
		return tree[p];
	}
	void fill(entry &info, std::string const &p, node const &n) const
	{
		info = entry{};
		std::string const name = p.substr(p.rfind('/') + 1);
		std::strncpy(info.name, name.c_str(), sizeof(info.name) - 1);
		info.attr = n.dir ? ATTR_DIR : 0x20; // AM_ARC
		info.size = n.dir ? 0 : u32(n.data.size());
	}
	u32 used() const
	{
		u32 total = 0;
		for (auto const &[p, n] : tree)
			total += u32(n.data.size());
		return total;
	}
	size_t room() const { return capacity - std::min(capacity, used()); }
	fr gate()
	{
		if (!present)
			return fr::NOT_READY;
		if (fail_next != fr::OK)
		{
			fr const f = fail_next;
			fail_next = fr::OK;
			return f;
		}
		return mounted ? fr::OK : fr::NOT_ENABLED;
	}
	fr allocate(obj const &o, object &id)
	{
		for (size_t i = 0; i < objects.size(); i++)
			if (!objects[i].used)
			{
				objects[i] = o;
				id = object(i);
				return fr::OK;
			}
		if (objects.size() >= 16)
			return fr::TOO_MANY_OPEN_FILES;
		objects.push_back(o);
		id = object(objects.size() - 1);
		return fr::OK;
	}
	obj *lookup(object id, kind_t kind)
	{
		return (id < objects.size() && objects[id].used && objects[id].valid && objects[id].kind == kind) ? &objects[id] : nullptr;
	}
	obj const *lookup(object id, kind_t kind) const { return const_cast<memory_storage *>(this)->lookup(id, kind); }
};

#endif
