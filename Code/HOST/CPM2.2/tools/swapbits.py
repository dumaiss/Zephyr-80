#!/usr/bin/env python3
import sys
from pathlib import Path

def swap_d0_d2(byte: int) -> int:
    b0 = (byte >> 0) & 1
    b2 = (byte >> 2) & 1

    # Clear bits 0 and 2
    byte &= ~0b00000101

    # Put old bit 0 into bit 2, old bit 2 into bit 0
    byte |= b0 << 2
    byte |= b2 << 0

    return byte

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} input.bin output-swapped.bin")
    sys.exit(1)

inp = Path(sys.argv[1]).read_bytes()
out = bytes(swap_d0_d2(b) for b in inp)
Path(sys.argv[2]).write_bytes(out)
