#!/usr/bin/env python3
"""Convert an Intel HEX image at CP/M origin 0x0100 to a .COM file."""

from __future__ import annotations

import argparse
from pathlib import Path


COM_ORIGIN = 0x0100


def read_ihex(path: Path) -> dict[int, int]:
    memory: dict[int, int] = {}
    upper = 0
    saw_eof = False

    for line_number, raw_line in enumerate(path.read_text().splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if not line.startswith(":"):
            raise ValueError(f"{path}:{line_number}: not an Intel HEX record")

        try:
            record = bytes.fromhex(line[1:])
        except ValueError as exc:
            raise ValueError(f"{path}:{line_number}: invalid hexadecimal data") from exc
        if len(record) < 5 or len(record) != record[0] + 5:
            raise ValueError(f"{path}:{line_number}: invalid record length")
        if sum(record) & 0xFF:
            raise ValueError(f"{path}:{line_number}: checksum mismatch")

        count = record[0]
        address = (record[1] << 8) | record[2]
        record_type = record[3]
        data = record[4 : 4 + count]

        if record_type == 0x00:
            base = upper + address
            for offset, value in enumerate(data):
                absolute = base + offset
                if absolute in memory:
                    raise ValueError(f"{path}:{line_number}: overlapping data at {absolute:04X}h")
                memory[absolute] = value
        elif record_type == 0x01:
            saw_eof = True
            break
        elif record_type == 0x02:
            if count != 2:
                raise ValueError(f"{path}:{line_number}: invalid segment-address record")
            upper = int.from_bytes(data, "big") << 4
        elif record_type == 0x04:
            if count != 2:
                raise ValueError(f"{path}:{line_number}: invalid linear-address record")
            upper = int.from_bytes(data, "big") << 16
        elif record_type not in (0x03, 0x05):
            raise ValueError(f"{path}:{line_number}: unsupported record type {record_type:02X}h")

    if not saw_eof:
        raise ValueError(f"{path}: missing EOF record")
    if not memory:
        raise ValueError(f"{path}: contains no data")
    return memory


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    try:
        memory = read_ihex(args.input)
        low = min(memory)
        high = max(memory) + 1
        if low < COM_ORIGIN:
            raise ValueError(f"image begins below CP/M origin: {low:04X}h")
        image = bytes(memory.get(address, 0) for address in range(COM_ORIGIN, high))
        args.output.write_bytes(image)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
