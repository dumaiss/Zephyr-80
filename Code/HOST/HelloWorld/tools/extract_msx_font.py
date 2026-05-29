#!/usr/bin/env python3
import argparse
from pathlib import Path


def format_asm_bytes(data: bytes, label: str, bytes_per_line: int = 8) -> str:
    lines = []
    lines.append(f"{label}:")

    for offset in range(0, len(data), bytes_per_line):
        chunk = data[offset:offset + bytes_per_line]
        values = ",".join(f"0x{b:02x}" for b in chunk)
        char_index = offset // 8
        lines.append(f"\t.db {values}\t; char 0x{char_index:02x}")

    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract 8x8 MSX BIOS font data into SDCC/ASxxxx .db format."
    )
    parser.add_argument("rom", help="Input 32K MSX BIOS ROM file")
    parser.add_argument("out", help="Output .asm include file")
    parser.add_argument(
        "--offset",
        type=lambda x: int(x, 0),
        default=0x1BBF,
        help="Font offset in ROM. Default: 0x1BBF",
    )
    parser.add_argument(
        "--first",
        type=lambda x: int(x, 0),
        default=0x20,
        help="First character code to extract. Default: 0x20",
    )
    parser.add_argument(
        "--count",
        type=lambda x: int(x, 0),
        default=0x60,
        help="Number of characters to extract. Default: 0x60 for ASCII 0x20-0x7F",
    )
    parser.add_argument(
        "--label",
        default="msx_font_20_7f",
        help="ASM label name. Default: msx_font_20_7f",
    )

    args = parser.parse_args()

    rom_path = Path(args.rom)
    out_path = Path(args.out)

    rom = rom_path.read_bytes()

    if len(rom) < 0x8000:
        print(f"warning: ROM is only {len(rom)} bytes; expected 32768 bytes for a 32K BIOS")

    glyph_size = 8
    start = args.offset + args.first * glyph_size
    size = args.count * glyph_size
    end = start + size

    if end > len(rom):
        raise SystemExit(
            f"font slice exceeds ROM size: need 0x{start:04x}..0x{end - 1:04x}, "
            f"ROM size is 0x{len(rom):04x}"
        )

    font = rom[start:end]

    header = (
        "; Extracted MSX BIOS 8x8 font\n"
        f"; Source: {rom_path.name}\n"
        f"; Font base offset: 0x{args.offset:04x}\n"
        f"; First char: 0x{args.first:02x}\n"
        f"; Count: 0x{args.count:02x}\n"
        f"; Bytes: {len(font)}\n"
        ";\n"
        "; Each character is 8 bytes, one byte per row.\n"
        "; Bit 7 is the leftmost pixel.\n\n"
    )

    out_path.write_text(header + format_asm_bytes(font, args.label), encoding="utf-8")

    print(
        f"wrote {len(font)} bytes / {args.count} chars "
        f"from 0x{start:04x}..0x{end - 1:04x} to {out_path}"
    )


if __name__ == "__main__":
    main()