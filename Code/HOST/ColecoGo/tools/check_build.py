#!/usr/bin/env python3
"""Check ColecoGo's fixed TPA and takeover-stage layout."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


COM_ORIGIN = 0x0100
FILE_BUFFER_BASE = 0x1800
COMMON_STAGE_A = 0xC000
COMMON_STAGE_LIMIT = 0xC400
TARGET_STAGE_B = 0x5F80
TARGET_STAGE_LIMIT = 0x6000


def listing_label(text: str, label: str) -> int:
    pattern = re.compile(
        rf"^\s*([0-9A-Fa-f]{{8}})\s+(?:\d+\s+)?{re.escape(label)}:\s*$",
        re.MULTILINE,
    )
    match = pattern.search(text)
    if not match:
        raise ValueError(f"label {label!r} not found in assembler listing")
    return int(match.group(1), 16)


def ihex_addresses(path: Path) -> set[int]:
    addresses: set[int] = set()
    upper = 0
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line:
            continue
        record = bytes.fromhex(line[1:])
        count = record[0]
        address = (record[1] << 8) | record[2]
        kind = record[3]
        data = record[4 : 4 + count]
        if kind == 0:
            addresses.update(range(upper + address, upper + address + count))
        elif kind == 2:
            upper = int.from_bytes(data, "big") << 4
        elif kind == 4:
            upper = int.from_bytes(data, "big") << 16
    return addresses


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listing", required=True, type=Path)
    parser.add_argument("--ihx", required=True, type=Path)
    parser.add_argument("--com", required=True, type=Path)
    args = parser.parse_args()

    try:
        listing = args.listing.read_text()
        stage_a_start = listing_label(listing, "stage_a_template")
        stage_a_end = listing_label(listing, "stage_a_template_end")
        stage_b_start = listing_label(listing, "stage_b_template")
        stage_b_end = listing_label(listing, "stage_b_template_end")
        program_end = listing_label(listing, "program_end")

        if not (stage_a_start < stage_a_end <= program_end):
            raise ValueError("Stage A labels are not ordered within the program")
        if not (stage_b_start < stage_b_end <= program_end):
            raise ValueError("Stage B labels are not ordered within the program")
        if program_end > FILE_BUFFER_BASE:
            raise ValueError(
                f"program ends at {program_end:04X}h and overlaps the file buffer at "
                f"{FILE_BUFFER_BASE:04X}h"
            )

        stage_a_size = stage_a_end - stage_a_start
        stage_b_size = stage_b_end - stage_b_start
        if COMMON_STAGE_A + stage_a_size > COMMON_STAGE_LIMIT:
            raise ValueError(f"Stage A is too large: {stage_a_size} bytes")
        if TARGET_STAGE_B + stage_b_size > TARGET_STAGE_LIMIT:
            raise ValueError(f"Stage B is too large: {stage_b_size} bytes")

        addresses = ihex_addresses(args.ihx)
        if not addresses:
            raise ValueError("linked image contains no data")
        if min(addresses) < COM_ORIGIN or max(addresses) >= FILE_BUFFER_BASE:
            raise ValueError("linked data lies outside the reserved program range")

        expected_com_size = program_end - COM_ORIGIN
        actual_com_size = args.com.stat().st_size
        if actual_com_size != expected_com_size:
            raise ValueError(
                f"COM size is {actual_com_size}, expected {expected_com_size} from program_end"
            )
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    print(
        f"layout ok: COM {actual_com_size} bytes; "
        f"Stage A {stage_a_size}/1024; Stage B {stage_b_size}/128"
    )


if __name__ == "__main__":
    main()
