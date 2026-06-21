#!/usr/bin/env python3
"""Fail the build if any address in the linked Intel HEX is emitted twice.

The ABS .org layout used by the Zephyr-80 BIOS lets two sections silently
overlap: sdas/sdld place bytes at absolute addresses and the later section
overwrites the earlier one with no error. The image's region validator only
checks declared boundaries, not emitted bytes, so byte-level collisions slip
through. This scans the .ihx directly and reports every overlapping range.

Optionally takes a symbol map (--symbols, sdld .map/.sym) to name the nearest
symbol at/below each overlap so the colliding sections are easy to identify.
"""
import argparse
import sys
from pathlib import Path


def load_ihx(path: Path) -> dict[int, int]:
    written: dict[int, int] = {}
    overlaps: dict[int, tuple[int, int]] = {}
    base = 0
    for line in path.read_text().splitlines():
        if not line.startswith(":"):
            continue
        count = int(line[1:3], 16)
        addr = int(line[3:7], 16)
        rectype = int(line[7:9], 16)
        if rectype == 0x04:  # extended linear address
            base = int(line[9:13], 16) << 16
            continue
        if rectype != 0x00:
            continue
        data = bytes.fromhex(line[9 : 9 + count * 2])
        for i, byte in enumerate(data):
            a = base + addr + i
            if a in written and written[a] != byte:
                overlaps[a] = (written[a], byte)
            written[a] = byte
    return overlaps


def load_symbols(path: Path | None) -> list[tuple[int, str]]:
    if path is None or not path.exists():
        return []
    syms: list[tuple[int, str]] = []
    for line in path.read_text().splitlines():
        parts = line.split()
        for i, tok in enumerate(parts):
            if len(tok) == 8 and all(c in "0123456789abcdefABCDEF" for c in tok):
                name = parts[i - 1] if i and not parts[i - 1].isdigit() else "?"
                try:
                    syms.append((int(tok, 16), name))
                except ValueError:
                    pass
    syms.sort()
    return syms


def nearest(syms: list[tuple[int, str]], addr: int) -> str:
    best = ""
    for a, name in syms:
        if a <= addr:
            best = f"{name}@{a:04X}"
        else:
            break
    return best


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("ihx", type=Path)
    ap.add_argument("--symbols", type=Path)
    args = ap.parse_args()

    overlaps = load_ihx(args.ihx)
    if not overlaps:
        print("check_overlap: OK (no overlapping bytes)")
        return 0

    syms = load_symbols(args.symbols)
    addrs = sorted(overlaps)
    print("check_overlap: ERROR - sections overwrite each other:", file=sys.stderr)
    start = prev = addrs[0]
    ranges = []
    for a in addrs[1:]:
        if a != prev + 1:
            ranges.append((start, prev))
            start = a
        prev = a
    ranges.append((start, prev))
    for lo, hi in ranges:
        old, new = overlaps[lo]
        loc = nearest(syms, lo)
        print(
            f"  {lo:04X}-{hi:04X} ({hi - lo + 1} bytes) "
            f"first={old:02X} overwritten-by={new:02X}  near {loc}",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
