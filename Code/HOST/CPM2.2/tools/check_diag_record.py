#!/usr/bin/env python3
"""Fail the build if the IOC failure-record layout has drifted between the BIOS
and the CP/M tools.

The record at CBIOS_IOC_DIAG_BASE is read by .COM programs at fixed addresses.
Its layout is declared twice: as offsets in the BIOS (src/cbios_defs.inc, the
authority) and as absolute addresses in the tools' mirror
(../HelloWorld/src/ioc_diag_record.inc).

Two hand-maintained copies of one layout is exactly the arrangement that has
already failed twice in this project.  ioc_levels.inc documents the first time:
five tools kept expecting controller level 62 after the firmware moved on.  The
second time was this record -- the BIOS field order was changed to allow two
16-bit stores and the mirror was not updated, so every migrated tool read RR0
where BULK_REASON had moved to.  Nothing caught it, because a stale tool
assembles perfectly and only lies at runtime, on the one report consulted when
the link is already broken.

This check is the thing that was missing.  It costs no target bytes.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Mirror name -> BIOS offset name.  Every field must appear on both sides;
# a field present in one and absent from the other is itself a failure.
FIELDS = {
    "IOC_DIAG_STATUS": "IOC_DIAG_OFF_STATUS",
    "IOC_DIAG_LANE": "IOC_DIAG_OFF_LANE",
    "IOC_DIAG_BULK_REASON": "IOC_DIAG_OFF_BULK_REASON",
    "IOC_DIAG_RR0": "IOC_DIAG_OFF_RR0",
    "IOC_DIAG_RR1": "IOC_DIAG_OFF_RR1",
    "IOC_DIAG_READY": "IOC_DIAG_OFF_READY",
    "IOC_DIAG_SYNCED": "IOC_DIAG_OFF_SYNCED",
    "IOC_DIAG_BULK_SYNCED": "IOC_DIAG_OFF_BULK_SYNCED",
    "IOC_DIAG_SEQ": "IOC_DIAG_OFF_SEQ",
    "IOC_DIAG_BULK_TYPE": "IOC_DIAG_OFF_BULK_TYPE",
    "IOC_DIAG_BULK_SEQ": "IOC_DIAG_OFF_BULK_SEQ",
    "IOC_DIAG_BULK_STATUS": "IOC_DIAG_OFF_BULK_STATUS",
    "IOC_DIAG_RESERVED": "IOC_DIAG_OFF_RESERVED",
}

# Constants that must simply agree by value.
SHARED_CONSTANTS = [
    ("IOC_DIAG_LANE_COMMAND", "IOC_DIAG_LANE_COMMAND"),
    ("IOC_DIAG_LANE_BULK", "IOC_DIAG_LANE_BULK"),
    ("IOC_BULK_REASON_NONE", "IOC_BULK_REASON_NONE"),
    ("IOC_BULK_REASON_INPUT", "IOC_BULK_REASON_INPUT"),
    ("IOC_BULK_REASON_MARKER", "IOC_BULK_REASON_MARKER"),
    ("IOC_BULK_REASON_LEN", "IOC_BULK_REASON_LEN"),
    ("IOC_BULK_REASON_TYPE", "IOC_BULK_REASON_TYPE"),
    ("IOC_BULK_REASON_SEQ", "IOC_BULK_REASON_SEQ"),
    ("IOC_BULK_REASON_STATUS", "IOC_BULK_REASON_STATUS"),
    ("IOC_BULK_REASON_CRC", "IOC_BULK_REASON_CRC"),
]

# Pairs the BIOS capture writes with a single 16-bit store.  If these stop being
# adjacent the assembler assertions in cbios_bank.asm fire, but state the intent
# here too so the reason is visible from either side.
ADJACENT_PAIRS = [
    ("IOC_DIAG_OFF_LANE", "IOC_DIAG_OFF_BULK_REASON"),
    ("IOC_DIAG_OFF_READY", "IOC_DIAG_OFF_SYNCED"),
]

NUMBER = r"(0x[0-9A-Fa-f]+|\d+)"


def parse_plain(text: str) -> dict[str, int]:
    """Collect NAME = <number> definitions."""
    out: dict[str, int] = {}
    for name, value in re.findall(rf"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{NUMBER}\s*(?:;.*)?$",
                                  text, re.MULTILINE):
        out[name] = int(value, 0)
    return out


def parse_based(text: str, base_name: str) -> dict[str, int]:
    """Collect NAME = <base> + <number> definitions, returning the offsets."""
    out: dict[str, int] = {}
    pattern = rf"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{re.escape(base_name)}\s*\+\s*{NUMBER}\s*(?:;.*)?$"
    for name, value in re.findall(pattern, text, re.MULTILINE):
        out[name] = int(value, 0)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--defs", type=Path, required=True,
                        help="BIOS src/cbios_defs.inc (the authority)")
    parser.add_argument("--mirror", type=Path, required=True,
                        help="CP/M tools ioc_diag_record.inc")
    args = parser.parse_args()

    for path in (args.defs, args.mirror):
        if not path.is_file():
            print(f"check_diag_record: missing {path}", file=sys.stderr)
            return 2

    defs_text = args.defs.read_text()
    mirror_text = args.mirror.read_text()

    defs = parse_plain(defs_text)
    mirror_consts = parse_plain(mirror_text)
    mirror_offsets = parse_based(mirror_text, "IOC_DIAG_BASE")

    errors: list[str] = []

    # Record base and size.
    base_match = re.search(rf"^CBIOS_IOC_DIAG_BASE\s*=\s*CBIOS_BASE\s*\+\s*{NUMBER}",
                           defs_text, re.MULTILINE)
    cbios_base = defs.get("CBIOS_BASE")
    if base_match and cbios_base is not None:
        bios_base = cbios_base + int(base_match.group(1), 0)
        mirror_base = mirror_consts.get("IOC_DIAG_BASE")
        if mirror_base is None:
            errors.append("mirror does not define IOC_DIAG_BASE")
        elif mirror_base != bios_base:
            errors.append(
                f"record base differs: BIOS {bios_base:#06x}, mirror {mirror_base:#06x}")

    bios_size = defs.get("CBIOS_IOC_DIAG_SIZE")
    mirror_size = mirror_consts.get("IOC_DIAG_SIZE")
    if bios_size is None:
        errors.append("BIOS does not define CBIOS_IOC_DIAG_SIZE")
    elif mirror_size is None:
        errors.append("mirror does not define IOC_DIAG_SIZE")
    elif bios_size != mirror_size:
        errors.append(f"record size differs: BIOS {bios_size}, mirror {mirror_size}")

    # Field offsets.
    for mirror_name, defs_name in FIELDS.items():
        want = defs.get(defs_name)
        got = mirror_offsets.get(mirror_name)
        if want is None:
            errors.append(f"BIOS does not define {defs_name}")
            continue
        if got is None:
            errors.append(f"mirror does not define {mirror_name}")
            continue
        if want != got:
            errors.append(
                f"{mirror_name}: BIOS offset {want:#04x}, mirror offset {got:#04x}")

    # A field the mirror declares that the BIOS no longer has is drift too --
    # this is how IOC_DIAG_CLASS survived in the mirror after being dropped.
    for name in mirror_offsets:
        if name not in FIELDS:
            errors.append(f"mirror declares {name}, which the BIOS layout does not have")

    # Shared constant values.
    for defs_name, mirror_name in SHARED_CONSTANTS:
        want = defs.get(defs_name)
        got = mirror_consts.get(mirror_name)
        if want is None:
            errors.append(f"BIOS does not define {defs_name}")
        elif got is None:
            errors.append(f"mirror does not define {mirror_name}")
        elif want != got:
            errors.append(f"{mirror_name}: BIOS {want:#04x}, mirror {got:#04x}")

    # Adjacency the 16-bit stores depend on.
    for first, second in ADJACENT_PAIRS:
        a, b = defs.get(first), defs.get(second)
        if a is not None and b is not None and b - a != 1:
            errors.append(
                f"{first} and {second} must stay adjacent for the 16-bit store "
                f"(offsets {a:#04x}, {b:#04x})")

    # The mirror gates decoding on a transport level; it must not claim a level
    # the BIOS has not reached.
    bios_level = defs.get("ZBIOS_XPORT_LEVEL")
    min_level = mirror_consts.get("IOC_DIAG_RECORD_MIN_XPORT_LEVEL")
    if bios_level is None:
        errors.append("BIOS does not define ZBIOS_XPORT_LEVEL")
    elif min_level is None:
        errors.append("mirror does not define IOC_DIAG_RECORD_MIN_XPORT_LEVEL")
    elif min_level > bios_level:
        errors.append(
            f"mirror requires transport level {min_level:#04x} but the BIOS is "
            f"{bios_level:#04x}; every tool would refuse to decode")

    if errors:
        print("check_diag_record: ERROR - IOC failure-record layout has drifted:",
              file=sys.stderr)
        for message in errors:
            print(f"  {message}", file=sys.stderr)
        print(f"  authority: {args.defs}", file=sys.stderr)
        print(f"  mirror:    {args.mirror}", file=sys.stderr)
        return 1

    print(f"check_diag_record: OK ({len(FIELDS)} fields, "
          f"{len(SHARED_CONSTANTS)} constants agree)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
