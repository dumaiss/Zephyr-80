#!/usr/bin/env python3
"""Check the keyboard-to-ColecoVision-keypad mapping against the real BIOS.

The firmware presents an active-low matrix nibble on the controller latch. The
BIOS reads that port, complements it, and uses the low four bits to index a
decode table, so a wrong nibble yields a different key rather than an obvious
failure -- something hardware testing would not make clear.

This extracts the mapping function from src/ioc_hid.c (the shipped text, not a
copy), compiles it for the host, and checks every key against the decode table
read out of the BIOS image itself.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "src" / "ioc_hid.c"
BIOS = ROOT.parent.parent / "HOST" / "Software" / "disk1" / "8" / "coleco.rom"

BIOS_DECODE_TABLE = 0x10F5
KEYS = "0123456789*#"
NONE = 0xFF

PRELUDE = """
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#define KEYBOARD_MODIFIER_LEFTSHIFT   0x02u
#define KEYBOARD_MODIFIER_RIGHTSHIFT  0x20u
#define HID_KEY_1                     0x1E
#define HID_KEY_3                     0x20
#define HID_KEY_8                     0x25
#define HID_KEY_0                     0x27
#define HID_KEY_KEYPAD_MULTIPLY       0x55
#define HID_KEY_KEYPAD_1              0x59
#define HID_KEY_KEYPAD_0              0x62
#define CONTROLLER_KEYPAD_NONE        0xffu
"""

SHIFT = 0x02


def cases() -> dict[str, tuple[int, int]]:
    """label -> (modifier byte, usage byte)."""
    table: dict[str, tuple[int, int]] = {}
    for digit in range(10):
        row = 0x27 if digit == 0 else 0x1E + digit - 1
        pad = 0x62 if digit == 0 else 0x59 + digit - 1
        table[f"row {digit}"] = (0x00, row)
        table[f"keypad {digit}"] = (0x00, pad)
    table["shift+8"] = (SHIFT, 0x25)
    table["keypad *"] = (0x00, 0x55)
    table["shift+3"] = (SHIFT, 0x20)
    # Negative cases.
    table["shift+5"] = (SHIFT, 0x22)
    table["letter a"] = (0x00, 0x04)
    table["released"] = (0x00, 0x00)
    return table


def expected() -> dict[str, int]:
    """label -> the nibble the latch must present, derived from the BIOS."""
    decode = BIOS.read_bytes()[BIOS_DECODE_TABLE:BIOS_DECODE_TABLE + 16]
    by_key = {KEYS[value]: (~index) & 0x0F for index, value in enumerate(decode) if value < 12}
    wanted = {}
    for digit in range(10):
        wanted[f"row {digit}"] = by_key[str(digit)]
        wanted[f"keypad {digit}"] = by_key[str(digit)]
    wanted["shift+8"] = by_key["*"]
    wanted["keypad *"] = by_key["*"]
    wanted["shift+3"] = by_key["#"]
    wanted["shift+5"] = NONE
    wanted["letter a"] = NONE
    wanted["released"] = NONE
    return wanted


def extract() -> str:
    text = SOURCE.read_text()
    start = text.index("static const uint8_t coleco_keypad_nibble")
    body = text.index("coleco_keypad_for_report(uint8_t const", start)
    return text[start:text.index("\n}\n", body) + 3]


def run(labels: list[tuple[int, int]]) -> list[int]:
    body = []
    for modifier, usage in labels:
        body.append(
            f"    r[0]={modifier}u; r[1]=0u; r[2]={usage}u;"
            " r[3]=0u; r[4]=0u; r[5]=0u; r[6]=0u; r[7]=0u;"
        )
        body.append('    printf("%02x\\n", (unsigned)coleco_keypad_for_report(r, 8u));')
    harness = (
        "int main(void)\n{\n    uint8_t r[8];\n" + "\n".join(body) + "\n    return 0;\n}\n"
    )
    with tempfile.TemporaryDirectory() as workdir:
        source = Path(workdir) / "harness.c"
        source.write_text(PRELUDE + extract() + harness)
        binary = Path(workdir) / "harness"
        subprocess.run(
            ["cc", "-O1", "-Wall", "-Wextra", "-Werror", "-o", str(binary), str(source)],
            check=True,
        )
        out = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
    return [int(line, 16) for line in out.stdout.split()]


def idle_value() -> int:
    """CONTROLLER_LATCH_IDLE, read from the header rather than duplicated."""
    text = (ROOT / "include" / "controller_latch.h").read_text()
    for line in text.split("\n"):
        if line.startswith("#define CONTROLLER_LATCH_IDLE"):
            return int(line.split()[2].rstrip("u"), 16)
    raise SystemExit("error: CONTROLLER_LATCH_IDLE not found")


def check_full_byte(wanted: dict[str, int]) -> list[str]:
    """Replay what a game actually sees: the whole latch byte, complemented.

    The nibble check above proves the key is right. This proves the rest of the
    byte is too -- in particular D7, which Montezuma's Revenge tests with
    `AND 0C0h / CP 0C0h` and which was wrong until it was found.
    """
    decode = BIOS.read_bytes()[BIOS_DECODE_TABLE:BIOS_DECODE_TABLE + 16]
    idle = idle_value()
    problems = []

    if (~idle) & 0x80 == 0:
        problems.append(
            f"idle {idle:#04x} leaves D7 high; a complemented read can never "
            "satisfy CP 0C0h (Monte's jump test)"
        )

    for digit in range(10):
        nibble = wanted[f"row {digit}"]
        latch = (idle & 0xF0) | nibble
        seen = (~latch) & 0xFF
        decoded = decode[seen & 0x0F]
        if decoded >= 12 or KEYS[decoded] != str(digit):
            problems.append(
                f"key {digit}: latch {latch:#04x} decodes to "
                f"{KEYS[decoded] if decoded < 12 else 'none'}"
            )
        # Active low in the latch, so a released fire reads back as 0 once the
        # BIOS complements the port.
        if seen & 0x40 != 0:
            problems.append(f"key {digit}: latch {latch:#04x} reads as fire pressed")
        if seen & 0x80 == 0:
            problems.append(f"key {digit}: latch {latch:#04x} leaves D7 clear after CPL")
    return problems


def main() -> int:
    if not shutil.which("cc"):
        print("skipping: no host C compiler")
        return 0
    if not BIOS.exists():
        print(f"skipping: {BIOS} is not present")
        return 0

    table = cases()
    wanted = expected()
    labels = list(table)
    got = run([table[label] for label in labels])

    failures = [
        f"{label}: got {value:#04x}, want {wanted[label]:#04x}"
        for label, value in zip(labels, got)
        if value != wanted[label]
    ]
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1

    failures += check_full_byte(wanted)
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1

    print(f"ok: {len(labels)} cases match the BIOS decode table at {BIOS_DECODE_TABLE:04X}h")
    for digit in range(10):
        print(f"    {digit} -> {wanted[f'row {digit}']:#04x}", end="")
    print(f"\n    * -> {wanted['shift+8']:#04x}   # -> {wanted['shift+3']:#04x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
