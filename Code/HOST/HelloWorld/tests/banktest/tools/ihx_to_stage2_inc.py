#!/usr/bin/env python3
"""Convert an Intel HEX image into an ASxxxx .db include.

The stage 2 program is linked for its runtime address at 0x0100, but the monitor
cannot load records below 0x6000. This helper turns the linked stage 2 IHX into
bytes that stage 1 embeds in its 0x8000 image and later copies to 0x0100.
"""

from __future__ import annotations

import sys
from pathlib import Path


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_ihx(path: Path) -> dict[int, int]:
    memory: dict[int, int] = {}
    upper = 0

    for line_number, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith(":"):
            raise ValueError(f"{path}:{line_number}: missing ':'")

        count = int(line[1:3], 16)
        address = int(line[3:7], 16)
        record_type = int(line[7:9], 16)
        data = bytes.fromhex(line[9 : 9 + count * 2])
        checksum = int(line[9 + count * 2 : 11 + count * 2], 16)

        total = count + (address >> 8) + (address & 0xFF) + record_type
        total += sum(data) + checksum
        if total & 0xFF:
            raise ValueError(f"{path}:{line_number}: bad checksum")

        if record_type == 0x00:
            base = upper + address
            for offset, byte in enumerate(data):
                memory[base + offset] = byte
        elif record_type == 0x01:
            break
        elif record_type == 0x04:
            if count != 2:
                raise ValueError(f"{path}:{line_number}: bad extended address")
            upper = int.from_bytes(data, "big") << 16
        elif record_type in (0x03, 0x05):
            continue
        else:
            raise ValueError(f"{path}:{line_number}: unsupported record {record_type:02X}")

    return memory


def write_include(memory: dict[int, int], base: int, out_path: Path) -> None:
    if not memory:
        raise ValueError("input image has no data records")

    lowest = min(memory)
    highest = max(memory)
    if lowest < base:
        raise ValueError(f"input has data below requested base: 0x{lowest:04X}")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as out:
        out.write("; Generated from stage2.ihx. Do not edit by hand.\n")
        out.write("stage2_blob:\n")
        row: list[str] = []
        for address in range(base, highest + 1):
            row.append(f"0x{memory.get(address, 0):02x}")
            if len(row) == 16:
                out.write("\t.db " + ",".join(row) + "\n")
                row = []
        if row:
            out.write("\t.db " + ",".join(row) + "\n")
        out.write("stage2_blob_end:\n")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(f"Usage: {argv[0]} input.ihx base-address output.inc", file=sys.stderr)
        return 2

    in_path = Path(argv[1])
    base = parse_int(argv[2])
    out_path = Path(argv[3])

    try:
        write_include(parse_ihx(in_path), base, out_path)
    except ValueError as exc:
        print(f"{argv[0]}: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
