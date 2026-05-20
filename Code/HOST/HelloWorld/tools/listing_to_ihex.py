#!/usr/bin/env python3
"""Convert z80asm listing addresses plus a packed binary to Intel HEX."""

from __future__ import annotations

import re
import sys
from pathlib import Path


LISTING_LINE_RE = re.compile(r"^([0-9A-Fa-f]{4})(?:\s+(.*))?$")
BYTE_RE = re.compile(r"^[0-9A-Fa-f]{2}$")


def usage() -> None:
    print("usage: listing_to_ihex.py listing.lst packed.bin output.hex", file=sys.stderr)


def parse_listing(path: Path) -> list[tuple[int, int]]:
    lines: list[tuple[int, list[str]]] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        match = LISTING_LINE_RE.match(raw_line)
        if not match:
            continue

        address = int(match.group(1), 16)
        rest = match.group(2) or ""
        tokens = rest.split()
        byte_tokens: list[str] = []

        for token in tokens:
            if token == ".." or BYTE_RE.match(token):
                byte_tokens.append(token)
                continue
            break

        lines.append((address, byte_tokens))

    chunks: list[tuple[int, int]] = []
    for index, (address, byte_tokens) in enumerate(lines):
        if not byte_tokens:
            continue

        if ".." in byte_tokens:
            length = None
            for next_address, _ in lines[index + 1 :]:
                if next_address > address:
                    length = next_address - address
                    break
            if length is None:
                raise ValueError(f"cannot infer abbreviated byte count at {address:04X}")
        else:
            length = len(byte_tokens)

        chunks.append((address, length))

    return chunks


def checksum(record: bytes) -> int:
    return (-sum(record)) & 0xFF


def data_record(address: int, data: bytes) -> str:
    header = bytes((len(data), (address >> 8) & 0xFF, address & 0xFF, 0x00))
    return ":" + (header + data + bytes((checksum(header + data),))).hex().upper()


def eof_record() -> str:
    return ":00000001FF"


def write_ihex(chunks: list[tuple[int, bytes]], path: Path) -> None:
    records: list[str] = []

    for address, data in chunks:
        offset = 0
        while offset < len(data):
            record_data = data[offset : offset + 16]
            records.append(data_record(address + offset, record_data))
            offset += len(record_data)

    records.append(eof_record())
    path.write_text("\n".join(records) + "\n", encoding="ascii")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        usage()
        return 2

    listing_path = Path(argv[1])
    binary_path = Path(argv[2])
    output_path = Path(argv[3])

    chunks = parse_listing(listing_path)
    packed = binary_path.read_bytes()

    sparse_chunks: list[tuple[int, bytes]] = []
    cursor = 0
    for address, length in chunks:
        next_cursor = cursor + length
        if next_cursor > len(packed):
            raise ValueError(
                f"listing describes more bytes than packed binary contains at {address:04X}"
            )
        sparse_chunks.append((address, packed[cursor:next_cursor]))
        cursor = next_cursor

    if cursor != len(packed):
        raise ValueError(
            f"packed binary has {len(packed) - cursor} trailing bytes not present in listing"
        )

    write_ihex(sparse_chunks, output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
