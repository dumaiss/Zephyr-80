#!/usr/bin/env python3
"""Build a CP/M 2.2 disk image from a tree of per-user-area directories.

WHY THIS EXISTS INSTEAD OF cpmtools
-----------------------------------
mkfs.cpm and cpmcp write correct volumes, but this cpmtools build's READER
aborts -- `malloc(): invalid size (unsorted)` -- on volumes that are provably
fine.  A dump of the directory after a "failing" write shows a textbook entry
and a byte-exact payload; it is cpmls and the directory scan at the start of the
next cpmcp that crash, not the image.

That makes any multi-pass build impossible: the first copy into a fresh volume
succeeds, and every pass after it dies reading what the first one wrote.  The
trigger is filename-dependent and deterministic (MANDEL.BAS crashes it,
SMILEY.COM does not), which is not a distinction the on-disk format makes.

The project already avoids cpmcp for extraction for related reasons; see
../CPM2.2/tools/build_rom_disk.py.

This writes the whole volume in one pass and then VERIFIES it by reading its own
output back, so a wrong image is a build failure rather than a disk that behaves
oddly three weeks later.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

RECORD = 128
DIR_ENTRY = 32


class Geometry:
    """The subset of a cpmtools diskdef this writer needs."""

    def __init__(self, params: dict[str, int]) -> None:
        self.seclen = params["seclen"]
        self.tracks = params["tracks"]
        self.sectrk = params["sectrk"]
        self.blocksize = params["blocksize"]
        self.maxdir = params["maxdir"]
        self.boottrk = params.get("boottrk", 0)

        if self.seclen != RECORD:
            raise SystemExit(f"seclen {self.seclen}: this writer assumes 128")

        self.total_bytes = self.tracks * self.sectrk * self.seclen
        self.data_offset = self.boottrk * self.sectrk * self.seclen
        self.data_bytes = self.total_bytes - self.data_offset
        self.total_blocks = self.data_bytes // self.blocksize
        self.dsm = self.total_blocks - 1
        self.recs_per_block = self.blocksize // RECORD

        # Directory occupies whole blocks at the start of the data area.
        self.dir_bytes = self.maxdir * DIR_ENTRY
        self.dir_blocks = math.ceil(self.dir_bytes / self.blocksize)
        self.first_data_block = self.dir_blocks

        # Block pointers are 16-bit once DSM exceeds 255, which halves how many
        # fit in an entry and therefore how much one entry can describe.
        self.wide_pointers = self.dsm > 255
        self.ptrs_per_entry = 8 if self.wide_pointers else 16
        self.recs_per_entry = self.ptrs_per_entry * self.recs_per_block


def read_diskdef(path: Path, name: str) -> Geometry:
    params: dict[str, int] = {}
    inside = False
    for line in path.read_text().splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "diskdef":
            inside = fields[1] == name
            continue
        if not inside:
            continue
        if fields[0] == "end":
            break
        if len(fields) >= 2:
            try:
                params[fields[0]] = int(fields[1], 0)
            except ValueError:
                pass
    if not params:
        raise SystemExit(f"format '{name}' not found in {path}")
    return Geometry(params)


def cpm_name(filename: str) -> tuple[bytes, bytes]:
    """Split a host filename into CP/M's 8 and 3 byte fields, space padded."""
    stem, _, ext = filename.partition(".")
    stem, ext = stem.upper(), ext.upper()
    if not stem or len(stem) > 8 or len(ext) > 3:
        raise SystemExit(f"'{filename}' is not a valid 8.3 CP/M name")
    bad = set(filename.upper()) - set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$-_.()[]{}!#&+@^~'`"
    )
    if bad:
        raise SystemExit(f"'{filename}' contains characters CP/M cannot store: {sorted(bad)}")
    return stem.ljust(8).encode("ascii"), ext.ljust(3).encode("ascii")


def build(tree: Path, geo: Geometry) -> bytearray:
    image = bytearray(b"\xe5" * geo.total_bytes)
    entries: list[bytes] = []
    next_block = geo.first_data_block

    for user_dir in sorted(tree.iterdir(), key=lambda p: int(p.name) if p.name.isdigit() else -1):
        if not user_dir.is_dir() or not user_dir.name.isdigit():
            continue
        user = int(user_dir.name)
        if not 0 <= user <= 15:
            raise SystemExit(f"user area {user} is outside 0-15")

        for src in sorted(user_dir.iterdir()):
            if not src.is_file():
                continue
            stem, ext = cpm_name(src.name)
            data = src.read_bytes()
            records = math.ceil(len(data) / RECORD) or 1
            blocks_needed = math.ceil(len(data) / geo.blocksize) or 1

            allocated: list[int] = []
            for _ in range(blocks_needed):
                if next_block > geo.dsm:
                    raise SystemExit("volume full")
                allocated.append(next_block)
                next_block += 1

            # Payload, padded to a whole block with E5 like a real volume.
            for index, block in enumerate(allocated):
                chunk = data[index * geo.blocksize : (index + 1) * geo.blocksize]
                start = geo.data_offset + block * geo.blocksize
                image[start : start + len(chunk)] = chunk

            # One directory entry per ptrs_per_entry blocks.
            done = 0
            for first in range(0, len(allocated), geo.ptrs_per_entry):
                group = allocated[first : first + geo.ptrs_per_entry]
                remaining = records - done
                in_entry = min(geo.recs_per_entry, remaining)
                done += in_entry

                # EX names the LAST logical extent this entry covers; RC counts
                # the records in that extent.  This is the EXM>0 encoding: one
                # physical entry spans several 128-record logical extents.
                logical = (first // geo.ptrs_per_entry) * (geo.recs_per_entry // 128)
                logical += (in_entry - 1) // 128
                rc = in_entry - ((in_entry - 1) // 128) * 128

                entry = bytearray(b"\x00" * DIR_ENTRY)
                entry[0] = user
                entry[1:9] = stem
                entry[9:12] = ext
                entry[12] = logical & 0x1F
                entry[13] = 0
                entry[14] = logical >> 5
                entry[15] = rc
                for slot, block in enumerate(group):
                    if geo.wide_pointers:
                        entry[16 + slot * 2] = block & 0xFF
                        entry[17 + slot * 2] = block >> 8
                    else:
                        entry[16 + slot] = block
                entries.append(bytes(entry))

    if len(entries) > geo.maxdir:
        raise SystemExit(f"{len(entries)} directory entries needed, {geo.maxdir} available")

    for index, entry in enumerate(entries):
        start = geo.data_offset + index * DIR_ENTRY
        image[start : start + DIR_ENTRY] = entry

    return image


def verify(image: bytes, tree: Path, geo: Geometry) -> None:
    """Read the image back and prove every source file is in it, byte for byte."""
    found: dict[tuple[int, str], list[int]] = {}
    sizes: dict[tuple[int, str], int] = {}

    for index in range(geo.maxdir):
        start = geo.data_offset + index * DIR_ENTRY
        entry = image[start : start + DIR_ENTRY]
        if entry[0] == 0xE5 or entry[0] > 15:
            continue
        name = entry[1:9].decode("ascii").rstrip()
        ext = entry[9:12].decode("ascii").rstrip()
        key = (entry[0], f"{name}.{ext}" if ext else name)
        logical = (entry[14] << 5) | (entry[12] & 0x1F)
        recs = logical * 128 + entry[15]
        blocks = []
        for slot in range(geo.ptrs_per_entry):
            block = (
                entry[16 + slot * 2] | (entry[17 + slot * 2] << 8)
                if geo.wide_pointers
                else entry[16 + slot]
            )
            if block:
                blocks.append(block)
        found.setdefault(key, []).extend(blocks)
        sizes[key] = max(sizes.get(key, 0), recs)

    expected = 0
    for user_dir in sorted(tree.iterdir()):
        if not user_dir.is_dir() or not user_dir.name.isdigit():
            continue
        user = int(user_dir.name)
        for src in sorted(user_dir.iterdir()):
            if not src.is_file():
                continue
            expected += 1
            stem, ext = cpm_name(src.name)
            key = (user, f"{stem.decode().rstrip()}.{ext.decode().rstrip()}".rstrip("."))
            if key not in found:
                raise SystemExit(f"verify: {user}:{src.name} is not in the image")
            data = src.read_bytes()
            recovered = b"".join(
                image[
                    geo.data_offset + b * geo.blocksize : geo.data_offset + (b + 1) * geo.blocksize
                ]
                for b in found[key]
            )
            if recovered[: len(data)] != data:
                raise SystemExit(f"verify: {user}:{src.name} payload differs")
            if sizes[key] != (math.ceil(len(data) / RECORD) or 1):
                raise SystemExit(
                    f"verify: {user}:{src.name} record count is "
                    f"{sizes[key]}, expected {math.ceil(len(data)/RECORD) or 1}"
                )

    if len(found) != expected:
        raise SystemExit(f"verify: image holds {len(found)} files, tree has {expected}")
    print(f"  verified {expected} files")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, required=True)
    parser.add_argument("--diskdef", type=Path, required=True)
    parser.add_argument("--format", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    geo = read_diskdef(args.diskdef, args.format)
    image = build(args.tree, geo)
    verify(bytes(image), args.tree, geo)
    args.output.write_bytes(image)
    print(f"  {args.output}: {len(image)} bytes")


if __name__ == "__main__":
    main()
