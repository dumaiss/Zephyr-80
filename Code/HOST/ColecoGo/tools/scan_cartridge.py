#!/usr/bin/env python3
"""Reference model for ColecoGo's in-loader cartridge I/O adaptation.

`COLECOGO.COM` traces a cartridge from its header vectors and rewrites the
operand of every direct I/O instruction it can prove is reachable code. This
module implements the identical algorithm in Python so the Z80 implementation
can be checked against it, and so a `.PAT` manifest can be produced for the
sites the trace cannot reach.

The two implementations must agree exactly. `tools/check_build.py` compares the
instruction-length table below against the one assembled into the program.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

CART_BASE = 0x8000
MAX_CART_BYTES = 0x8000

# LunchCrema passes A1:A0 to the V9958, where a ColecoVision decodes only A0.
VDP_BLOCK_LO, VDP_BLOCK_HI = 0xA0, 0xBF
ZEPHYR_VDP_DATA, ZEPHYR_VDP_COMMAND = 0xA0, 0xA1

# Afternoon Blend decodes A2:A0 within E0h-FFh; only writes reach the PSGs.
SOUND_BLOCK_LO, SOUND_BLOCK_HI = 0xE0, 0xFF
ZEPHYR_SOUND_PORT = 0xE0

PAT_MAGIC = b"CGP1"
PAT_MAX_ENTRIES = 512


def _main_length_table() -> list[int]:
    """Total byte length of every main-page Z80 opcode.

    Prefix opcodes (CBh, DDh, EDh, FDh) are decoded separately and carry 1.
    """
    table = [1] * 256
    for op, length in {
        0x01: 3, 0x06: 2, 0x0E: 2,
        0x10: 2, 0x11: 3, 0x16: 2, 0x18: 2, 0x1E: 2,
        0x20: 2, 0x21: 3, 0x22: 3, 0x26: 2, 0x28: 2, 0x2A: 3, 0x2E: 2,
        0x30: 2, 0x31: 3, 0x32: 3, 0x36: 2, 0x38: 2, 0x3A: 3, 0x3E: 2,
    }.items():
        table[op] = length
    for op in range(0xC0, 0x100):
        low = op & 0x0F
        if low in (0x02, 0x04, 0x0A, 0x0C):          # JP cc / CALL cc / JP / CALL
            table[op] = 3
        elif low in (0x06, 0x0E):                     # ALU A,n
            table[op] = 2
    table[0xC3] = 3                                   # JP nn
    table[0xCD] = 3                                   # CALL nn
    table[0xD3] = 2                                   # OUT (n),A
    table[0xDB] = 2                                   # IN A,(n)
    for prefix in (0xCB, 0xDD, 0xED, 0xFD):
        table[prefix] = 1
    return table


MAIN_LENGTH = _main_length_table()


def _is_hl_form(op: int) -> bool:
    """True when a main-page opcode references (HL) and so gains a displacement."""
    if op in (0x34, 0x35, 0x36):
        return True
    if op & 0xC7 == 0x46:                             # LD r,(HL)
        return True
    if op & 0xF8 == 0x70 and op != 0x76:              # LD (HL),r
        return True
    return op & 0xC7 == 0x86                          # ALU A,(HL)


class Scanner:
    """Recursive-descent trace that rewrites only provably reachable operands."""

    def __init__(self, image: bytes):
        self.rom = bytearray(image)
        self.size = len(image)
        self.starts = bytearray(self.size)
        self.work: list[int] = []
        self.vdp = 0
        self.sound = 0
        self.indirect: list[int] = []
        self.patched: list[tuple[int, int, int]] = []

    # -- helpers ---------------------------------------------------------
    def byte(self, off: int) -> int:
        return self.rom[off]

    def word(self, off: int) -> int:
        return self.rom[off] | self.rom[off + 1] << 8

    def in_range(self, off: int) -> bool:
        return 0 <= off < self.size

    def push_logical(self, address: int) -> None:
        off = address - CART_BASE
        if self.in_range(off) and not self.starts[off]:
            self.work.append(off)

    def push_offset(self, off: int) -> None:
        if self.in_range(off) and not self.starts[off]:
            self.work.append(off)

    # -- entry points ----------------------------------------------------
    def has_header(self) -> bool:
        return self.size >= 0x24 and self.rom[0:2] in (b"\xaa\x55", b"\x55\xaa")

    def seed(self) -> None:
        self.push_logical(self.word(0x0A))
        for slot in range(0x0C, 0x24, 3):
            self.push_offset(slot)

    # -- operand rewriting -----------------------------------------------
    def adapt_port(self, off: int, port: int, is_out: bool) -> None:
        if VDP_BLOCK_LO <= port <= VDP_BLOCK_HI:
            new = ZEPHYR_VDP_COMMAND if port & 1 else ZEPHYR_VDP_DATA
            kind = "vdp"
        elif is_out and SOUND_BLOCK_LO <= port <= SOUND_BLOCK_HI:
            new = ZEPHYR_SOUND_PORT
            kind = "sound"
        else:
            # E0h-FFh reads are controller latches and already correct.
            return
        if new == port:
            return
        self.rom[off] = new
        self.patched.append((off, port, new))
        if kind == "vdp":
            self.vdp += 1
        else:
            self.sound += 1

    # -- single instruction ----------------------------------------------
    def step(self, off: int) -> tuple[int, bool]:
        """Return (length, stop) for the instruction at off, applying effects."""
        op = self.rom[off]

        if op == 0xCB:
            return 2, False

        if op == 0xED:
            op2 = self.rom[off + 1] if off + 1 < self.size else 0
            length = 4 if op2 & 0xC7 == 0x43 else 2
            if op2 & 0xC7 in (0x40, 0x41) or op2 & 0xE6 == 0xA2:
                self.indirect.append(off)
            return length, op2 & 0xC7 == 0x45          # RETN / RETI

        if op in (0xDD, 0xFD):
            op2 = self.rom[off + 1] if off + 1 < self.size else 0
            if op2 == 0xCB:
                return 4, False
            if op2 in (0xDD, 0xFD, 0xED):
                return 1, False                        # redundant prefix
            length = 1 + MAIN_LENGTH[op2] + (1 if _is_hl_form(op2) else 0)
            return length, op2 == 0xE9                 # JP (IX) / JP (IY)

        length = MAIN_LENGTH[op]

        if op in (0xD3, 0xDB) and off + 1 < self.size:
            self.adapt_port(off + 1, self.rom[off + 1], op == 0xD3)
            return length, False

        target_off = off + length
        if op == 0xC3:                                 # JP nn
            self.push_logical(self.word(off + 1))
            return length, True
        if op & 0xC7 == 0xC2:                          # JP cc,nn
            self.push_logical(self.word(off + 1))
            return length, False
        if op == 0xCD or op & 0xC7 == 0xC4:            # CALL nn / CALL cc,nn
            self.push_logical(self.word(off + 1))
            return length, False
        if op == 0x18:                                 # JR e
            self.push_offset(target_off + ((self.rom[off + 1] ^ 0x80) - 0x80))
            return length, True
        if op & 0xE7 == 0x20 or op == 0x10:            # JR cc,e / DJNZ e
            self.push_offset(target_off + ((self.rom[off + 1] ^ 0x80) - 0x80))
            return length, False
        if op in (0xC9, 0xE9):                         # RET / JP (HL)
            return length, True
        return length, False

    # -- driver ----------------------------------------------------------
    def run(self) -> None:
        if not self.has_header():
            return
        self.seed()
        while self.work:
            off = self.work.pop()
            while True:
                if not self.in_range(off) or self.starts[off]:
                    break
                # Mark before decoding: the address is an instruction start
                # whatever the instruction turns out to be, and marking first
                # keeps a second path from applying the same effects twice.
                self.starts[off] = 1
                length, stop = self.step(off)
                if stop or off + length > self.size:
                    break
                off += length


def record_rounded(data: bytes) -> bytes:
    """The image as CP/M delivers it: padded with FFh to a 128-byte boundary.

    The loader can only ever see whole records, so a manifest must be bound to
    the rounded image rather than to the host file's exact length.
    """
    return data + b"\xff" * (-len(data) % 128)


def crc16(data: bytes) -> int:
    """CRC-16/CCITT-FALSE over the record-rounded image.

    Matches the loader's table-free bitwise routine.
    """
    data = record_rounded(data)
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def read_rom(path: Path) -> bytes:
    data = path.read_bytes()
    if not data or len(data) > MAX_CART_BYTES:
        raise SystemExit(f"error: ROM must be 1-{MAX_CART_BYTES} bytes; found {len(data)}")
    if len(data) % 128:
        print(
            f"warning: {path} is not a multiple of 128 bytes; CP/M rounds it up",
            file=sys.stderr,
        )
    return data


def survey(scanner: Scanner) -> dict[str, int]:
    """Counts a maintainer needs to triage a title before patching it.

    `untraced` is the headline number: byte pairs that look like direct I/O but
    that the trace could not prove are instructions. Most are data -- Donkey
    Kong has eight and no direct I/O at all -- so this is a hint to
    disassemble, never a list of sites to patch.
    """
    image = scanner.rom
    counts = {"bios_calls": 0, "untraced": 0, "mode_select": 0, "controller": 0}
    for off in range(scanner.size - 2):
        op = image[off]
        if op in (0xD3, 0xDB):
            port = image[off + 1]
            looks_like_io = VDP_BLOCK_LO <= port <= VDP_BLOCK_HI or (
                op == 0xD3 and port >= SOUND_BLOCK_LO
            )
            if looks_like_io and not scanner.starts[off]:
                counts["untraced"] += 1
        if not scanner.starts[off]:
            continue
        if op == 0xD3 and (0x80 <= image[off + 1] <= 0x9F or 0xC0 <= image[off + 1] <= 0xDF):
            counts["mode_select"] += 1
        if op == 0xDB and image[off + 1] >= SOUND_BLOCK_LO:
            counts["controller"] += 1
        if op == 0xCD or op & 0xC7 == 0xC4:
            if (image[off + 1] | image[off + 2] << 8) < 0x2000:
                counts["bios_calls"] += 1
    return counts


def command_scan(args: argparse.Namespace) -> None:
    data = read_rom(args.rom)
    scanner = Scanner(data)
    scanner.run()
    print(f"ROM:      {args.rom} ({scanner.size} bytes, crc16 {crc16(data):04X})")
    if not scanner.has_header():
        print("Header:   no AA55h/55AAh cartridge header; the loader will not scan")
        return
    reached = sum(scanner.starts)
    print(f"Traced:   {reached} reachable instructions")
    print(f"Patched:  {scanner.vdp} VDP, {scanner.sound} sound")
    for off, old, new in scanner.patched:
        print(f"    {CART_BASE + off - 1:04X}  {old:02X} -> {new:02X}")
    print(f"Indirect: {len(scanner.indirect)} unpatchable OUT (C)/IN (C) site(s)")
    for off in scanner.indirect:
        print(f"    {CART_BASE + off:04X}")

    counts = survey(scanner)
    print(f"BIOS:     {counts['bios_calls']} calls into 0000h-1FFFh")
    print(f"Untraced: {counts['untraced']} byte pair(s) that resemble direct I/O")
    if counts["mode_select"]:
        print(
            f"Warning:  {counts['mode_select']} controller mode-select write(s); "
            "Zephyr decodes neither 80h-9Fh nor C0h-DFh"
        )
    print()
    if scanner.vdp or scanner.sound:
        print("Verdict:  the loader adapts this title's own hardware access.")
    elif counts["bios_calls"] > 20:
        print(
            "Verdict:  this title works through the BIOS, which ColecoGo already\n"
            "          adapts. Nothing here needs a cartridge patch; any remaining\n"
            "          fault is CPU speed or controller semantics, not port mapping."
        )
    else:
        print(
            "Verdict:  no reachable direct I/O and little BIOS use. Its hardware\n"
            "          access is most likely behind a computed jump or in a\n"
            "          register; disassemble before writing a manifest."
        )


def command_pat(args: argparse.Namespace) -> None:
    original = read_rom(args.rom)
    patched = read_rom(args.patched_rom)
    if len(original) != len(patched):
        raise SystemExit("error: the two ROMs differ in length")

    scanner = Scanner(original)
    scanner.run()
    auto = {off for off, _, _ in scanner.patched}

    entries = []
    for off, (a, b) in enumerate(zip(original, patched)):
        if a == b or off in auto:
            continue
        entries.append((off, a, b))
    if not entries:
        raise SystemExit("error: no differences remain once the automatic scan is applied")
    if len(entries) > PAT_MAX_ENTRIES:
        raise SystemExit(f"error: {len(entries)} entries exceed the {PAT_MAX_ENTRIES} limit")

    rounded = record_rounded(original)
    blob = PAT_MAGIC + struct.pack(
        "<HHH", len(rounded), crc16(original), len(entries)
    )
    for off, old, new in entries:
        blob += struct.pack("<HBB", off, old, new)
    blob += b"\x1a" * (-len(blob) % 128)
    args.output.write_bytes(blob)
    print(f"Wrote {args.output}: {len(entries)} entry(s), {len(blob)} bytes")
    for off, old, new in entries:
        print(f"    {CART_BASE + off:04X}  {old:02X} -> {new:02X}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    scan = commands.add_parser("scan", help="report what the loader's scan will do")
    scan.add_argument("rom", type=Path)
    scan.set_defaults(function=command_scan)

    pat = commands.add_parser(
        "pat", help="build a .PAT manifest from a hand-patched ROM"
    )
    pat.add_argument("rom", type=Path, help="the original cartridge image")
    pat.add_argument("patched_rom", type=Path, help="the hand-corrected image")
    pat.add_argument("output", type=Path)
    pat.set_defaults(function=command_pat)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    args.function(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
