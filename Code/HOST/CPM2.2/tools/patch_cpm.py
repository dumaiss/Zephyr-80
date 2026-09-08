#!/usr/bin/env python3
"""Replace the CCP and/or the BDOS inside the 64 KiB firmware image.

The CCP is assembled into the firmware at CBASE like everything else, so
swapping it is a byte replacement rather than a link-time change.  That is only
safe if the replacement really is a CCP and really does fit, so this checks
both rather than trusting the caller.

WHAT IS DELIBERATELY NOT REPLACED
---------------------------------
The slot is CBASE..CBASE+7FFh.  The six bytes at CBASE+800h are the BDOS serial
number, and FBASE -- the BDOS entry the whole system calls through -- is at
CBASE+806h.  Writing 2054 bytes instead of 2048 would take both out, and the
symptom would be a machine that cold-boots and dies on the first BDOS call.

The BIOS's restore_ccp_from_rom copies CBASE..FBASE, i.e. 2054 bytes: the CCP
plus that serial.  So the serial has to survive here for warm boot to keep
working.
"""

from __future__ import annotations

import argparse
from pathlib import Path

SLOT = 0x800        # CCP
BDOS_SLOT = 0xE00   # BDOS, immediately above it


def install_ccp(firmware: bytearray, cbase: int, ccp: bytes) -> None:
    """CBASE..CBASE+7FFh.  The six bytes above it belong to the BDOS."""
    if len(ccp) != SLOT:
        raise SystemExit(f"CCP is {len(ccp)} bytes, the slot is {SLOT}")
    if ccp[0] != 0xC3 or ccp[3] != 0xC3:
        raise SystemExit(
            f"CCP does not begin with the two-entry header "
            f"({ccp[0]:02X} {ccp[3]:02X}); refusing to install it"
        )
    serial = bytes(firmware[cbase + SLOT : cbase + SLOT + 6])
    firmware[cbase : cbase + SLOT] = ccp
    assert bytes(firmware[cbase + SLOT : cbase + SLOT + 6]) == serial
    print(f"  CCP  at {cbase:04X}h: {SLOT} bytes, entries "
          f"{ccp[1] | (ccp[2] << 8):04X}h / {ccp[4] | (ccp[5] << 8):04X}h")
    print(f"    BDOS serial at {cbase + SLOT:04X}h left intact")


def install_bdos(firmware: bytearray, cbase: int, bdos: bytes) -> None:
    """CBASE+800h..CBASE+15FFh.

    Unlike the CCP this DOES replace the six serial-number bytes, because a
    BDOS supplies its own: ZSDOS puts 'ZSDOS ' there and stock CP/M puts the
    DRI serial.  FBASE -- the entry every BDOS call goes through -- is six
    bytes in, so a replacement whose seventh byte is not a jump would produce a
    machine that cold-boots and dies on the first BDOS call.
    """
    if len(bdos) != BDOS_SLOT:
        raise SystemExit(f"BDOS is {len(bdos)} bytes, the slot is {BDOS_SLOT}")
    if bdos[6] != 0xC3:
        raise SystemExit(
            f"BDOS has no jump at FBASE (byte 6 is {bdos[6]:02X}); "
            "refusing to install it"
        )
    base = cbase + SLOT
    firmware[base : base + BDOS_SLOT] = bdos
    print(f"  BDOS at {base:04X}h: {BDOS_SLOT} bytes, serial {bytes(bdos[:6])!r}, "
          f"FBASE {base + 6:04X}h -> JP {bdos[7] | (bdos[8] << 8):04X}h")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--ccp", type=Path)
    parser.add_argument("--bdos", type=Path)
    parser.add_argument("--cbase", type=lambda v: int(v, 0), required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if not args.ccp and not args.bdos:
        raise SystemExit("nothing to do: pass --ccp and/or --bdos")

    firmware = bytearray(args.firmware.read_bytes())
    if args.cbase + SLOT + BDOS_SLOT > len(firmware):
        raise SystemExit("CBASE plus both slots exceeds the firmware image")

    if args.ccp:
        install_ccp(firmware, args.cbase, args.ccp.read_bytes())
    if args.bdos:
        install_bdos(firmware, args.cbase, args.bdos.read_bytes())

    # Whatever was installed, the BDOS entry must still be a jump.
    fbase = args.cbase + SLOT + 6
    if firmware[fbase] != 0xC3:
        raise SystemExit(f"FBASE at {fbase:04X}h is not a JP after patching")

    args.output.write_bytes(bytes(firmware))


if __name__ == "__main__":
    main()
