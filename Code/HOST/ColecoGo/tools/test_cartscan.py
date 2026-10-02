#!/usr/bin/env python3
"""Check the Z80 cartridge scanner against the reference model.

Builds nothing. Runs `build/SCANTEST.COM` under a CP/M emulator once per ROM
and compares, byte for byte, the trace bitmap and the adapted image it prints
against `tools/scan_cartridge.py`. A divergence in the instruction decoder
fails here rather than on hardware.
"""

from __future__ import annotations

import argparse
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scan_cartridge import Scanner, crc16, record_rounded  # noqa: E402

REPORT = re.compile(
    r"Cartridge scan: (\d+) VDP and (\d+) sound operand\(s\) adapted, "
    r"(\d+) indirect"
)


def run_emulator(emulator: str, program: Path, rom: Path, workdir: Path) -> str:
    shutil.copy(program, workdir / "SCANTEST.COM")
    shutil.copy(rom, workdir / "CART.ROM")
    # A manifest beside the ROM must be picked up under the harness's name too.
    manifest = workdir / "CART.PAT"
    manifest.unlink(missing_ok=True)
    if rom.with_suffix(".PAT").exists():
        shutil.copy(rom.with_suffix(".PAT"), manifest)
    result = subprocess.run(
        [emulator, "SCANTEST.COM", "CART.ROM"],
        cwd=workdir,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        raise SystemExit(f"error: emulator failed for {rom}:\n{result.stderr}")
    return result.stdout


def parse_section(text: str, start: str, end: str) -> bytes:
    """Collect the hex between two markers, whatever line endings arrive."""
    try:
        body = text.split(start, 1)[1].split(end, 1)[0]
    except IndexError as exc:
        raise SystemExit(f"error: {start} section missing from harness output") from exc
    digits = "".join(character for character in body if character in "0123456789abcdef")
    return bytes.fromhex(digits)


def check_rom(emulator: str, program: Path, rom: Path, workdir: Path) -> list[str]:
    output = run_emulator(emulator, program, rom, workdir)

    image = record_rounded(rom.read_bytes())
    model = Scanner(image)
    model.run()

    failures: list[str] = []

    # Apply the same manifest to the model, so the comparison covers both the
    # automatic scan and the per-title overrides.
    manifest_path = rom.with_suffix(".PAT")
    manifest_entries = 0
    if manifest_path.exists():
        blob = manifest_path.read_bytes()
        if blob[:4] != b"CGP1":
            return [f"{rom.name}: {manifest_path.name} is not a CGP1 manifest"]
        length, crc, manifest_entries = struct.unpack("<HHH", blob[4:10])
        if length != len(image) or crc != crc16(rom.read_bytes()):
            return [f"{rom.name}: {manifest_path.name} does not bind to this image"]
        for index in range(manifest_entries):
            base = 10 + index * 4
            offset, expected, replacement = struct.unpack("<HBB", blob[base:base + 4])
            if model.rom[offset] != expected:
                return [
                    f"{rom.name}: {manifest_path.name} entry {index} expects "
                    f"{expected:02X} at {0x8000 + offset:04X}"
                ]
            model.rom[offset] = replacement
        if f"Patch manifest: {manifest_entries} entry(s) applied." not in output:
            failures.append(
                f"{rom.name}: harness did not report {manifest_entries} applied entries"
            )

    report = REPORT.search(output)
    if not report:
        return [f"{rom.name}: harness printed no scan report"]
    vdp, sound, indirect = (int(value) for value in report.groups())
    if (vdp, sound, indirect) != (model.vdp, model.sound, len(model.indirect)):
        failures.append(
            f"{rom.name}: counts {vdp}/{sound}/{indirect} differ from model "
            f"{model.vdp}/{model.sound}/{len(model.indirect)}"
        )

    bitmap = parse_section(output, "BITMAP", "IMAGE")
    if len(bitmap) != 0x1000:
        failures.append(f"{rom.name}: bitmap is {len(bitmap)} bytes, expected 4096")
    else:
        traced = [
            offset
            for offset in range(len(image))
            if ((bitmap[offset >> 3] >> (offset & 7)) & 1) != model.starts[offset]
        ]
        if traced:
            shown = ", ".join(f"{0x8000 + off:04X}" for off in traced[:8])
            failures.append(
                f"{rom.name}: {len(traced)} instruction-start mismatch(es) at {shown}"
            )

    adapted = parse_section(output, "IMAGE", "END")
    if len(adapted) != len(image):
        failures.append(
            f"{rom.name}: image is {len(adapted)} bytes, expected {len(image)}"
        )
    else:
        bad = [off for off in range(len(image)) if adapted[off] != model.rom[off]]
        if bad:
            shown = ", ".join(f"{0x8000 + off:04X}" for off in bad[:8])
            failures.append(f"{rom.name}: {len(bad)} adapted-byte mismatch(es) at {shown}")

    if not failures:
        print(
            f"ok: {rom.name} -- {sum(model.starts)} traced bytes, "
            f"{model.vdp} VDP, {model.sound} sound, {len(model.indirect)} indirect"
        )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--program", type=Path, default=Path("build/SCANTEST.COM"))
    parser.add_argument("--emulator", default="cpmemu")
    parser.add_argument("--workdir", type=Path, default=Path("build/scantest"))
    parser.add_argument("roms", nargs="+", type=Path)
    args = parser.parse_args()

    if not shutil.which(args.emulator):
        print(f"skipping: {args.emulator} is not installed")
        return 0
    if not args.program.exists():
        parser.error(f"{args.program} has not been built")

    args.workdir.mkdir(parents=True, exist_ok=True)
    failures: list[str] = []
    for rom in args.roms:
        if not rom.exists():
            print(f"skipping: {rom} is not present")
            continue
        failures.extend(check_rom(args.emulator, args.program, rom, args.workdir))

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
