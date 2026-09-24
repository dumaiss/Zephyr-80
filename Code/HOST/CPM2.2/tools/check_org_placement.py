#!/usr/bin/env python3
"""Fail the build if an `.org` did not land where its constant says.

The layout is expressed as ~54 `.area`/`.org` pairs. In asxxxx, `.org` inside an
ABS area that has already been entered once is **relative to where that area left
off**, not absolute. So re-entering an area and calling `.org` again silently
places the block somewhere other than the address the source names.

That is not theoretical. Splitting `drivers/storage/rom.asm` into its own
translation unit moved `storage_caller_sp` from `FE68h` to `FE6Ch`, and the three
SD-backend call sites followed it. The build was clean; only a byte-for-byte
comparison against the previous image caught it.

This check compares, for every `.org <symbol>` in the resolved listings, the
address the assembler assigned against the value of that symbol. They must
agree. It costs nothing and it turns a silent relocation into a named failure.

The fix, when it fires, is to give the block its own area name rather than
re-entering one that is already open.
"""
import argparse
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_memory_docs import add_defs, parse_listings  # noqa: E402

# "    0000FE6C                        307 \t.org CBIOS_STORAGE_CALLER_SP"
ORG = re.compile(r"^\s+([0-9A-F]{8})\s+\d+\s+\.org\s+([A-Za-z_][\w]*)\s*$")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--listing", type=Path, required=True, nargs="+",
                    help="resolved listings (.rst), one per translation unit")
    ap.add_argument("--defs", type=Path, required=True,
                    help="layout header, for constants the listings do not show")
    args = ap.parse_args()

    symbols, _ = parse_listings(args.listing)
    add_defs(symbols, args.defs)

    checked = 0
    bad: list[str] = []
    for listing in args.listing:
        for line in listing.read_text(errors="replace").splitlines():
            m = ORG.match(line)
            if not m:
                continue
            name = m.group(2)
            if name not in symbols:
                # An expression or a constant the listings do not carry; the
                # region limit checks still bound whatever it produced.
                continue
            placed, declared = int(m.group(1), 16), symbols[name]
            checked += 1
            if placed != declared:
                bad.append(
                    f"  {listing.name}: .org {name} placed at {placed:04X}h, "
                    f"but {name} = {declared:04X}h (off by {placed - declared:+d})"
                )

    if bad:
        print("check_org_placement: ERROR - .org did not land on its constant:",
              file=sys.stderr)
        print("\n".join(bad), file=sys.stderr)
        print("\n  Cause: re-entering an ABS area makes the following .org relative.",
              file=sys.stderr)
        print("  Fix:   give the block its own .area name instead of re-entering one.",
              file=sys.stderr)
        return 1

    print(f"check_org_placement: OK ({checked} .org sites on their declared addresses)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
