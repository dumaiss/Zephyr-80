#!/usr/bin/env python3
"""Build a synthetic ColecoVision image that exercises every scanner decision.

Real cartridges are a poor test of the operand rewriting: Donkey Kong drives
the hardware entirely through the BIOS, and Zaxxon reaches it through OUT (C).
This image contains a reachable instance of each case the scanner must get
right, plus the two it must leave alone -- an unexecuted data table full of
plausible I/O byte pairs, and an inline constant that a JR skips over.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scan_cartridge import Scanner, crc16, record_rounded

ROM_BYTES = 0x2000
CODE = 0x40
DATA = 0x200
NMI = 0x300


def build() -> bytes:
    rom = bytearray(b"\xff" * ROM_BYTES)

    rom[0:2] = b"\xaa\x55"
    rom[0x0A:0x0C] = (0x8000 + CODE).to_bytes(2, "little")
    for slot in range(0x0C, 0x24, 3):
        rom[slot:slot + 3] = b"\xc9\x00\x00"
    rom[0x21:0x24] = b"\xc3" + (0x8000 + NMI).to_bytes(2, "little")

    code = bytes([
        0xD3, 0xBE,              # OUT (BEh),A  -> A0h, the stock VDP data port
        0xD3, 0xBF,              # OUT (BFh),A  -> A1h, the stock command port
        0xDB, 0xBE,              # IN  A,(BEh)  -> A0h
        0xDB, 0xBF,              # IN  A,(BFh)  -> A1h
        0xD3, 0xAA,              # OUT (AAh),A  -> A0h, a VDP block alias
        0xD3, 0xB3,              # OUT (B3h),A  -> A1h, a VDP block alias
        0xD3, 0xA0,              # already native; must not be counted
        0xD3, 0xA1,              # already native; must not be counted
        0xD3, 0xFF,              # OUT (FFh),A  -> E0h, PSG0
        0xD3, 0xE0,              # already PSG0; must not be counted
        0xDB, 0xFF,              # IN  A,(FFh): a controller latch, untouched
        0xDB, 0xFC,              # IN  A,(FCh): a controller latch, untouched
        0xD3, 0x7E,              # not decoded on Zephyr; untouched
        0xED, 0x79,              # OUT (C),A: indirect, counted only
        0xED, 0x78,              # IN  A,(C): indirect, counted only
        0xED, 0xB3,              # OTIR:      indirect, counted only
        0xDD, 0x36, 0x0C, 0xFE,  # LD (IX+0Ch),FEh -- four bytes
        0xFD, 0x7E, 0x05,        # LD A,(IY+5)     -- three bytes
        0xDD, 0xCB, 0x02, 0x46,  # BIT 0,(IX+2)    -- four bytes
        0xED, 0x4B, 0x34, 0x12,  # LD BC,(1234h)   -- four bytes
        0xCB, 0x27,              # SLA A           -- two bytes
        0x06, 0x03,              # LD B,3
        0x10, 0xFE,              # DJNZ $
        0x18, 0x02, 0xD3, 0xBE,  # JR +2 over an inline D3h BEh that is data
        0xCD, 0x00, 0x00,        # CALL into the BIOS, outside the image
        0xC9,                    # RET
    ])
    rom[CODE:CODE + len(code)] = code

    # Never executed. A blind byte scan would rewrite all of this.
    rom[DATA:DATA + 16] = bytes([
        0xD3, 0xBE, 0xDB, 0xBF, 0xD3, 0xFF, 0xDB, 0xFF,
        0xD3, 0xAA, 0xD3, 0xE0, 0xDB, 0xBE, 0xD3, 0xB2,
    ])

    # Reached only through the header's NMI vector slot.
    rom[NMI:NMI + 4] = bytes([0xD3, 0xBF, 0xED, 0x45])
    return bytes(rom)


def build_manifest(image: bytes) -> bytes:
    """A manifest covering the two cases the trace deliberately cannot reach.

    One entry replaces an indirect OUT (C),A with a direct PSG0 write; the
    other corrects a site inside the unexecuted data table, standing in for
    code that only a computed jump ever reaches.
    """
    rounded = record_rounded(image)
    model = Scanner(rounded)
    model.run()
    automatic = {offset for offset, _, _ in model.patched}

    entries = [
        (CODE + 0x1A, 0xED, 0xD3),
        (CODE + 0x1B, 0x79, 0xE0),
        (DATA + 0x00, 0xD3, 0xA0),
        (DATA + 0x01, 0xBE, 0xA1),
    ]
    for offset, expected, _ in entries:
        assert offset not in automatic, f"{offset:04X} is already patched by the scan"
        assert model.rom[offset] == expected, f"{offset:04X} does not hold {expected:02X}"

    blob = b"CGP1" + struct.pack(
        "<HHH", len(rounded), crc16(image), len(entries)
    )
    for offset, expected, replacement in entries:
        blob += struct.pack("<HBB", offset, expected, replacement)
    return blob + b"\x1a" * (-len(blob) % 128)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} OUTPUT.ROM", file=sys.stderr)
        return 2
    output = Path(sys.argv[1])
    image = build()
    output.write_bytes(image)
    output.with_suffix(".PAT").write_bytes(build_manifest(image))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
