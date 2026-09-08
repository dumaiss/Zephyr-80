#!/usr/bin/env python3
"""Cut the useful part out of a Microsoft LINK-80 output image.

L80 writes a CP/M .COM-style file: a flat image that begins at 0100h, whatever
origin the code was linked to.  Linking the BDOS at CC00h therefore produces a
55 KiB file that is almost entirely zeros, with the 3.5 KiB that matters near
the end.  This slices that out.

Bounds are checked rather than assumed: an origin or size that runs past the end
of the image means the link did not land where the caller thinks it did, and
carrying on would write zeros into the ROM.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--load", type=lambda v: int(v, 0), default=0x0100,
                        help="address the image loads at (L80 default 0100h)")
    parser.add_argument("--origin", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--size", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    data = args.image.read_bytes()
    start = args.origin - args.load
    if start < 0:
        raise SystemExit(f"origin {args.origin:04X}h is below the load address "
                         f"{args.load:04X}h")
    if start + args.size > len(data):
        raise SystemExit(
            f"{args.image}: {len(data)} bytes, but {args.origin:04X}h+{args.size} "
            f"needs {start + args.size}; the link did not land where expected"
        )

    args.output.write_bytes(data[start : start + args.size])
    used = sum(1 for b in data[start : start + args.size] if b)
    print(f"  {args.output}: {args.size} bytes from {args.origin:04X}h "
          f"({used} non-zero)")


if __name__ == "__main__":
    main()
