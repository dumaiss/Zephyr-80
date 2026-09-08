#!/usr/bin/env python3
"""Turn a MAC-produced Intel HEX file into a fixed-size CCP image.

MLOAD.COM does this under CP/M, but doing it here keeps the step in the host
build where it can be checked.  Two details of MAC's output matter:

  * it terminates with `:0000000000` -- a type 0 record of length zero -- not
    the Intel-standard `:00000001FF`, so a strict reader treats the terminator
    as a data record at address 0000h and rejects it as out of range; and
  * the image is shorter than the slot, so the tail must be padded rather than
    left as whatever the previous CCP had there.

Every record is checksummed and bounds-checked against the slot, because the
output of this is written straight into the ROM at a fixed address: a record
outside the slot would silently corrupt whatever lives next to it.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hex", type=Path, required=True)
    parser.add_argument("--base", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--size", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pad", type=lambda v: int(v, 0), default=0x00)
    args = parser.parse_args()

    image = bytearray([args.pad]) * args.size
    lo, hi = None, 0

    for number, line in enumerate(args.hex.read_text(errors="replace").splitlines(), 1):
        line = line.strip().rstrip("\x1a")
        if not line.startswith(":"):
            continue
        try:
            record = bytes.fromhex(line[1:])
        except ValueError:
            raise SystemExit(f"{args.hex}:{number}: not valid hex")
        if len(record) < 5:
            raise SystemExit(f"{args.hex}:{number}: short record")
        if sum(record) & 0xFF:
            raise SystemExit(f"{args.hex}:{number}: checksum mismatch")

        count, address, kind = record[0], (record[1] << 8) | record[2], record[3]
        if kind != 0 or count == 0:      # MAC's zero-length type 0 terminator
            continue
        if address < args.base or address + count > args.base + args.size:
            raise SystemExit(
                f"{args.hex}:{number}: record {address:04X}h+{count} falls outside "
                f"the {args.base:04X}h-{args.base + args.size - 1:04X}h slot"
            )

        offset = address - args.base
        image[offset : offset + count] = record[4 : 4 + count]
        lo = address if lo is None else min(lo, address)
        hi = max(hi, address + count)

    if lo is None:
        raise SystemExit(f"{args.hex}: no data records")

    args.output.write_bytes(bytes(image))
    print(f"  {args.output}: {args.size} bytes")
    print(f"    code {lo:04X}h-{hi - 1:04X}h ({hi - lo} bytes), "
          f"{args.size - (hi - lo)} spare in the slot")


if __name__ == "__main__":
    main()
