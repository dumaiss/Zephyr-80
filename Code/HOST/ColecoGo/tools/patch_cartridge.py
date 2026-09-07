#!/usr/bin/env python3
"""Inspect, verify, or apply guarded byte patches to a ColecoVision ROM."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


FORMAT = "colecogo-patch-v1"
DEFAULT_LOAD_ADDRESS = 0x8000
MAX_CART_BYTES = 0x8000


class PatchError(ValueError):
    """A manifest or ROM failed validation."""


@dataclass(frozen=True)
class Patch:
    name: str
    offset: int
    expected: bytes
    replacement: bytes


def rom_identity(data: bytes) -> dict[str, Any]:
    return {
        "size": len(data),
        "crc32": f"{zlib.crc32(data) & 0xFFFFFFFF:08x}",
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def parse_integer(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise PatchError(f"{field} must be an integer, not Boolean")
    if isinstance(value, int):
        result = value
    elif isinstance(value, str):
        try:
            result = int(value, 0)
        except ValueError as exc:
            raise PatchError(f"{field} is not a valid integer: {value!r}") from exc
    else:
        raise PatchError(f"{field} must be an integer or 0x-prefixed string")
    if result < 0:
        raise PatchError(f"{field} must not be negative")
    return result


def parse_hex_bytes(value: Any, field: str) -> bytes:
    if not isinstance(value, str):
        raise PatchError(f"{field} must be a hexadecimal string")
    compact = "".join(value.split())
    if not compact or len(compact) % 2:
        raise PatchError(f"{field} must contain one or more complete bytes")
    try:
        return bytes.fromhex(compact)
    except ValueError as exc:
        raise PatchError(f"{field} contains invalid hexadecimal data") from exc


def read_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise PatchError(f"cannot read manifest {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise PatchError(
            f"invalid JSON in {path} at line {exc.lineno}, column {exc.colno}: {exc.msg}"
        ) from exc
    if not isinstance(value, dict):
        raise PatchError("manifest root must be a JSON object")
    return value


def validate_rom_identity(manifest: dict[str, Any], data: bytes) -> None:
    wanted = manifest.get("rom")
    if not isinstance(wanted, dict):
        raise PatchError("manifest rom field must be an object")

    actual = rom_identity(data)
    if "size" not in wanted or "sha256" not in wanted:
        raise PatchError("manifest rom field must contain size and sha256")

    wanted_size = parse_integer(wanted["size"], "rom.size")
    wanted_sha = wanted["sha256"]
    if not isinstance(wanted_sha, str) or len(wanted_sha) != 64:
        raise PatchError("rom.sha256 must contain 64 hexadecimal characters")
    try:
        bytes.fromhex(wanted_sha)
    except ValueError as exc:
        raise PatchError("rom.sha256 contains invalid hexadecimal data") from exc

    if actual["size"] != wanted_size:
        raise PatchError(
            f"ROM size mismatch: expected {wanted_size}, found {actual['size']}"
        )
    if actual["sha256"] != wanted_sha.lower():
        raise PatchError(
            "ROM SHA-256 mismatch: expected "
            f"{wanted_sha.lower()}, found {actual['sha256']}"
        )


def parse_patches(manifest: dict[str, Any], rom_size: int) -> list[Patch]:
    if manifest.get("format") != FORMAT:
        raise PatchError(f"manifest format must be {FORMAT!r}")

    load_address = parse_integer(
        manifest.get("load_address", DEFAULT_LOAD_ADDRESS), "load_address"
    )
    raw_patches = manifest.get("patches")
    if not isinstance(raw_patches, list) or not raw_patches:
        raise PatchError("manifest patches field must be a non-empty array")

    patches: list[Patch] = []
    occupied: list[tuple[int, int, str]] = []
    for index, raw in enumerate(raw_patches):
        prefix = f"patches[{index}]"
        if not isinstance(raw, dict):
            raise PatchError(f"{prefix} must be an object")

        name = raw.get("name", f"patch {index + 1}")
        if not isinstance(name, str) or not name.strip():
            raise PatchError(f"{prefix}.name must be a non-empty string")

        has_offset = "offset" in raw
        has_address = "address" in raw
        if has_offset == has_address:
            raise PatchError(f"{prefix} must contain exactly one of offset or address")
        if has_offset:
            offset = parse_integer(raw["offset"], f"{prefix}.offset")
        else:
            address = parse_integer(raw["address"], f"{prefix}.address")
            if address < load_address:
                raise PatchError(
                    f"{prefix}.address lies below load_address 0x{load_address:04X}"
                )
            offset = address - load_address

        expected = parse_hex_bytes(raw.get("expect"), f"{prefix}.expect")
        replacement = parse_hex_bytes(raw.get("replace"), f"{prefix}.replace")
        if len(expected) != len(replacement):
            raise PatchError(
                f"{prefix} changes length ({len(expected)} bytes to "
                f"{len(replacement)}); cartridge patches must be size-preserving"
            )
        end = offset + len(expected)
        if end > rom_size:
            raise PatchError(
                f"{prefix} range 0x{offset:04X}-0x{end - 1:04X} exceeds ROM size"
            )
        for other_start, other_end, other_name in occupied:
            if offset < other_end and end > other_start:
                raise PatchError(f"{name!r} overlaps earlier patch {other_name!r}")

        occupied.append((offset, end, name))
        patches.append(Patch(name, offset, expected, replacement))

    return patches


def verify_and_patch(data: bytes, patches: list[Patch]) -> bytes:
    result = bytearray(data)
    for patch in patches:
        actual = data[patch.offset : patch.offset + len(patch.expected)]
        if actual != patch.expected:
            raise PatchError(
                f"{patch.name}: expected {patch.expected.hex(' ')} at ROM offset "
                f"0x{patch.offset:04X}, found {actual.hex(' ')}"
            )
        result[patch.offset : patch.offset + len(patch.replacement)] = patch.replacement
    return bytes(result)


def read_rom(path: Path) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise PatchError(f"cannot read ROM {path}: {exc}") from exc
    if not data or len(data) > MAX_CART_BYTES:
        raise PatchError(
            f"ROM size must be 1-{MAX_CART_BYTES} bytes; found {len(data)}"
        )
    return data


def command_info(args: argparse.Namespace) -> None:
    data = read_rom(args.rom)
    identity = rom_identity(data)
    print(f"ROM:    {args.rom}")
    print(f"Size:   {identity['size']} bytes")
    print(f"CRC32:  {identity['crc32']}")
    print(f"SHA256: {identity['sha256']}")


def load_verified_patch(rom_path: Path, manifest_path: Path) -> tuple[bytes, list[Patch]]:
    data = read_rom(rom_path)
    manifest = read_json_object(manifest_path)
    validate_rom_identity(manifest, data)
    patches = parse_patches(manifest, len(data))
    verify_and_patch(data, patches)
    return data, patches


def print_patch_summary(patches: list[Patch]) -> None:
    for patch in patches:
        end = patch.offset + len(patch.expected) - 1
        print(
            f"  0x{patch.offset:04X}-0x{end:04X}  "
            f"{patch.expected.hex(' ')} -> {patch.replacement.hex(' ')}  {patch.name}"
        )


def command_verify(args: argparse.Namespace) -> None:
    _, patches = load_verified_patch(args.rom, args.manifest)
    print(f"Verified {len(patches)} patch(es):")
    print_patch_summary(patches)


def command_apply(args: argparse.Namespace) -> None:
    data, patches = load_verified_patch(args.rom, args.manifest)
    output = args.output.resolve()
    if output == args.rom.resolve():
        raise PatchError("output ROM must be different from the input ROM")
    if args.output.exists():
        raise PatchError(f"output already exists: {args.output}")

    patched = verify_and_patch(data, patches)
    try:
        with args.output.open("xb") as stream:
            stream.write(patched)
    except OSError as exc:
        raise PatchError(f"cannot write output ROM {args.output}: {exc}") from exc

    print(f"Applied {len(patches)} patch(es):")
    print_patch_summary(patches)
    print(f"Wrote:  {args.output}")
    print(f"SHA256: {hashlib.sha256(patched).hexdigest()}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    info = commands.add_parser("info", help="print a ROM's size and hashes")
    info.add_argument("rom", type=Path)
    info.set_defaults(function=command_info)

    verify = commands.add_parser("verify", help="validate a manifest without writing")
    verify.add_argument("rom", type=Path)
    verify.add_argument("manifest", type=Path)
    verify.set_defaults(function=command_verify)

    apply = commands.add_parser("apply", help="write a separately patched ROM")
    apply.add_argument("rom", type=Path)
    apply.add_argument("manifest", type=Path)
    apply.add_argument("output", type=Path)
    apply.set_defaults(function=command_apply)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.function(args)
    except PatchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

