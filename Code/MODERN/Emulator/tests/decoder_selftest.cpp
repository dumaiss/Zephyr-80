// license:BSD-3-Clause
// copyright-holders:Kitamura
// TEST-ONLY: standalone debug self-test of the CPU/debugger mapping facts.
#ifndef MAME_DEBUG
#error This self-test must be built with MAME_DEBUG
#endif
#include "osdcomm.h"
using osd::u8;
using osd::u16;
using osd::u32;
#include "zephyr80_map.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	std::ifstream fixture(argv[1]);
	std::string line;
	unsigned count = 0;
	while (std::getline(fixture, line))
	{
		if (line.empty() || line[0] == '#')
			continue;
		unsigned latch, address, flash, read, write;
		std::istringstream row(line);
		if (!(row >> std::hex >> latch >> address >> flash >> read >> write))
			return 2;
		auto const got = zephyr80_map::decode(address, latch);
		if (got.read_flash != bool(flash) || got.read_address != read || got.write_address != write
			|| got.read_address >= zephyr80_map::mem::ROM_SIZE || got.write_address >= zephyr80_map::mem::RAM_SIZE
			|| (got.read_address & 0xffff) != address || (got.write_address & 0xffff) != address)
		{
			std::cerr << "FAIL " << line << '\n';
			return 1;
		}
		++count;
	}
	if (count != 8192)
		return 2;
	std::cout << "PASS debug decoder self-test: " << count << " read/write mappings, bounded addresses and preserved A0-A15\n";
}
