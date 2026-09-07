#!/usr/bin/env python3
"""Convert an Intel HEX file to a CP/M .COM binary (origin 0x0100)."""

import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} input.ihx output.com")

    ihx_path = Path(sys.argv[1])
    com_path = Path(sys.argv[2])

    mem = bytearray(65536)
    hi = 0x0100  # lowest address we'll write

    with ihx_path.open() as f:
        for line in f:
            line = line.strip()
            if not line.startswith(":"):
                continue
            rec_len = int(line[1:3], 16)
            addr = int(line[3:7], 16)
            rec_type = int(line[7:9], 16)
            if rec_type == 1:   # EOF record
                break
            if rec_type != 0:   # skip non-data records
                continue
            for i in range(rec_len):
                b = int(line[9 + i * 2 : 11 + i * 2], 16)
                mem[addr + i] = b
                hi = max(hi, addr + i)

    com_start = 0x0100
    com_path.write_bytes(bytes(mem[com_start : hi + 1]))


if __name__ == "__main__":
    main()
