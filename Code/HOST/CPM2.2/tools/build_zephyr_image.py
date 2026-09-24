#!/usr/bin/env python3
"""Build the Zephyr-80 paged CP/M image."""

from __future__ import annotations

import argparse
import configparser
from dataclasses import dataclass
from pathlib import Path
import re
import sys

from split_banked_image import constants, value


APP_BASE = 0x0100
COMMON_BASE = 0xE000
BANK_SIZE = 0x10000
MAX_BANK = 7
IMAGE_BANK_COUNT = 8  # physical ROM pages; only explicitly declared boot pages seed SRAM
REQUIRED_SYMBOLS = ("MOVE", "XMOVE", "SELMEM", "SETBNK")
DEFAULT_DEFS_PATH = Path("src/layout/memory.inc")


@dataclass(frozen=True)
class Payload:
    key: str
    name: str
    bank: int
    path: Path
    entry: int = APP_BASE
    kind: str = "data"
    ram_bank: int | None = None

    @property
    def data(self) -> bytes:
        return self.path.read_bytes()

    @property
    def size(self) -> int:
        return self.path.stat().st_size

    @property
    def end_exclusive(self) -> int:
        return self.entry + self.size


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware", required=True, type=Path)
    parser.add_argument("--payload-config", type=Path)
    parser.add_argument("--monitor", type=Path)
    parser.add_argument("--bbcbasic", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--symbols", type=Path)
    parser.add_argument("--defs", default=DEFAULT_DEFS_PATH, type=Path)
    parser.add_argument("--console", choices=("v9958", "vdrip"), default="v9958")
    parser.add_argument("--storage-a", choices=("rom", "vdrip"), default="rom")
    return parser.parse_args()


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise SystemExit(f"Missing {label}: {path}")


def parse_int(value: str, label: str) -> int:
    raw = value.strip()
    try:
        if raw.lower().endswith("h"):
            return int(raw[:-1], 16)
        return int(raw, 0)
    except ValueError as exc:
        raise SystemExit(f"Invalid {label}: {value}") from exc


def payload_key(name: str) -> str:
    key = re.sub(r"[^A-Za-z0-9]+", "_", name.strip().lower()).strip("_")
    return key or "payload"


def payloads_from_config(path: Path) -> list[Payload]:
    require_file(path, "payload configuration")

    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(path)

    payloads: list[Payload] = []
    seen_banks: set[int] = set()
    seen_keys: set[str] = set()
    for section in config.sections():
        if not section.startswith("payload."):
            continue
        values = config[section]
        section_id = section.split(".", 1)[1]
        key = payload_key(section_id)
        name = values.get("name", section_id).strip()
        if "bank" not in values:
            raise SystemExit(f"Missing bank in payload section: {section}")
        if "path" not in values:
            raise SystemExit(f"Missing path in payload section: {section}")

        bank = parse_int(values["bank"], f"{section}.bank")
        entry = parse_int(values.get("entry", f"{APP_BASE:04X}h"), f"{section}.entry")
        payload = Payload(key=key, name=name, bank=bank, path=Path(values["path"]), entry=entry,
                          kind=values.get("kind", "data"),
                          ram_bank=parse_int(values["ram_bank"], f"{section}.ram_bank") if "ram_bank" in values else None)
        if key in seen_keys:
            raise SystemExit(f"Duplicate payload section key: {key}")
        if bank in seen_banks:
            raise SystemExit(f"Multiple payloads configured for bank {bank}")
        seen_keys.add(key)
        seen_banks.add(bank)
        payloads.append(payload)

    return payloads


def config_has_section(path: Path, section: str) -> bool:
    require_file(path, "payload configuration")
    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(path)
    return section in config


def legacy_payloads(args: argparse.Namespace) -> list[Payload]:
    if args.monitor is None or args.bbcbasic is None:
        raise SystemExit("Provide --payload-config, or both legacy --monitor and --bbcbasic payloads")
    return [
        Payload("monitor", "Monitor", 0, args.monitor),
        Payload("bbc_basic", "BBC BASIC", 1, args.bbcbasic),
    ]


def validate_payload(payload: Payload) -> None:
    if payload.bank < 0 or payload.bank > MAX_BANK:
        raise SystemExit(f"{payload.name} payload bank is outside 0-{MAX_BANK}: {payload.bank}")
    if payload.entry < 0 or payload.entry >= BANK_SIZE:
        raise SystemExit(f"{payload.name} payload entry is outside bank address space: {payload.entry:04X}h")
    if payload.kind not in ("boot", "romdisk", "data"):
        raise SystemExit(f"Unknown ROM page kind: {payload.kind}")
    if payload.bank == 0:
        raise SystemExit("ROM page 0 is reserved for the common boot image")
    if payload.kind != "boot" and payload.ram_bank is not None:
        raise SystemExit("Only boot pages may specify an initial SRAM destination")
    if payload.end_exclusive > BANK_SIZE:
        raise SystemExit(
            f"{payload.name} payload exceeds physical ROM page: "
            f"entry={payload.entry:04X}h size={payload.size} "
            f"end={payload.end_exclusive:04X}h limit={BANK_SIZE:04X}h"
        )


def parse_symbols(path: Path | None) -> set[str]:
    if path is None:
        return set()
    if not path.is_file():
        raise SystemExit(f"Missing symbol/listing file: {path}")

    symbols: set[str] = set()
    pattern = re.compile(r"\b([A-Za-z_.$][A-Za-z0-9_.$]*)\b")
    for line in path.read_text(errors="replace").splitlines():
        for match in pattern.finditer(line):
            symbols.add(match.group(1).upper())
    return symbols


def validate_symbols(symbols_path: Path | None) -> dict[str, str]:
    if symbols_path is None:
        return {symbol: "not_checked" for symbol in REQUIRED_SYMBOLS}

    found = parse_symbols(symbols_path)
    status: dict[str, str] = {}
    missing: list[str] = []
    for symbol in REQUIRED_SYMBOLS:
        if symbol in found:
            status[symbol] = "present"
        else:
            status[symbol] = "missing"
            missing.append(symbol)

    if missing:
        raise SystemExit("Missing required banking symbols: " + ", ".join(missing))
    return status


def place_payload(image: bytearray, payload: Payload) -> None:
    start = payload.bank * BANK_SIZE + payload.entry
    end = start + payload.size
    if end > len(image):
        raise SystemExit(f"{payload.name} payload exceeds image size")
    image[start:end] = payload.data


def write_manifest(
    path: Path,
    output: Path,
    firmware: Path,
    payloads: list[Payload],
    symbol_status: dict[str, str],
    console: str,
    storage_a: str,
) -> None:
    lines = [
        f"image.name={output.name}",
        "image.status=valid",
        f"firmware.path={firmware}",
        f"common.base={COMMON_BASE:04X}h",
        f"console.backend={console}",
        f"storage.backend={storage_a}",
        "boot.page0.ram_bank=0",
        "boot.copy_bytes=65536",
        "romdisk.trampoline=ROM_ACCESS_BASE:ROM_ACCESS_SIZE",
    ]
    for payload in payloads:
        lines.extend(
            [
                f"payload.{payload.key}.name={payload.name}",
                f"payload.{payload.key}.kind={payload.kind}",
                f"payload.{payload.key}.ram_bank={payload.ram_bank if payload.ram_bank is not None else 'none'}",
                f"payload.{payload.key}.path={payload.path}",
                f"payload.{payload.key}.bank={payload.bank}",
                f"payload.{payload.key}.entry={payload.entry:04X}h",
                f"payload.{payload.key}.size={payload.size}",
                f"payload.{payload.key}.end={payload.end_exclusive:04X}h",
            ]
        )
    for symbol, status in symbol_status.items():
        lines.append(f"symbol.{symbol}={status}")
    lines.extend(["validation.payloads=pass"])
    path.write_text("\n".join(lines) + "\n")


def write_report(
    path: Path,
    output: Path,
    firmware: Path,
    payloads: list[Payload],
    symbol_status: dict[str, str],
    console: str,
    storage_a: str,
) -> None:
    lines = [
        "# Zephyr-80 Image Layout Report",
        "",
        f"- Image: `{output}`",
        f"- Firmware input: `{firmware}`",
        f"- Common memory base: `{COMMON_BASE:04X}h`",
        f"- Console backend: `{console}`",
        f"- Drive A backend: `{storage_a}`",
        "",
        "## Payloads",
        "",
        "| Payload | ROM page | Role | Entry | Size | End | Source |",
        "|---|---:|---|---:|---:|---:|---|",
    ]
    for payload in payloads:
        lines.append(
            f"| {payload.name} | {payload.bank} | {payload.kind}"
            f"{f' -> SRAM bank {payload.ram_bank}' if payload.ram_bank is not None else ' (not copied)'} | "
            f"`{payload.entry:04X}h` | "
            f"{payload.size} | `{payload.end_exclusive:04X}h` | `{payload.path}` |"
        )
    rom_disk = [payload for payload in payloads
                if payload.key.startswith("romdisk_page")]
    if rom_disk:
        banks = ", ".join(str(payload.bank) for payload in rom_disk)
        total = sum(payload.size for payload in rom_disk)
        storage = (
            f"- Drive A is a read-only CP/M volume in ROM pages {banks} "
            f"({total} bytes); each page contributes 48 KiB of filesystem data. "
            "The unused tail carries only the ROM-read primitive, never a bootstrap."
        )
    else:
        storage = (
            "- No ROM disk payload is embedded; drive A comes from whichever "
            "backend was linked (see STORAGE_A in the Makefile)."
        )
    lines.extend(["", "## Storage", "", storage])
    lines.extend(
        [
            "",
            "## Banking Symbols",
            "",
            "| Symbol | Status |",
            "|---|---|",
        ]
    )
    for symbol, status in symbol_status.items():
        lines.append(f"| `{symbol}` | {status} |")
    lines.extend(
        [
            "",
            "## Notes",
            "",
            "- No RAM disk seed image is embedded; the banked RAM disk backend is retained but not linked by default.",
            "- `../CPM` is context only and is not a build dependency.",
            "",
        ]
    )
    path.write_text("\n".join(lines))


def main() -> int:
    args = parse_args()
    require_file(args.firmware, "firmware image")

    if args.payload_config:
        payloads = payloads_from_config(args.payload_config)
    elif args.monitor and args.bbcbasic:
        payloads = legacy_payloads(args)
    else:
        payloads = []
    if args.payload_config and config_has_section(args.payload_config, "ramdisk"):
        raise SystemExit("The RAM disk backend was retired; remove the [ramdisk] section")
    for payload in payloads:
        require_file(payload.path, f"{payload.name} payload")
        validate_payload(payload)

    symbol_status = validate_symbols(args.symbols)

    firmware = args.firmware.read_bytes()
    max_payload_bank = max((payload.bank for payload in payloads), default=-1)
    image_size = max(BANK_SIZE * IMAGE_BANK_COUNT, BANK_SIZE * (max_payload_bank + 1), len(firmware))
    image = bytearray([0x00] * image_size)
    image[: len(firmware)] = firmware
    for payload in payloads:
        place_payload(image, payload)
    # Classify by declared role, never by a coincident SRAM bank number.
    defs = constants([args.defs])
    boot_page = value(defs, "BOOT_OS_ROM_PAGE")
    boot_limit = value(defs, "BOOTSTRAP_LIMIT")
    access = value(defs, "ROM_ACCESS_BASE")
    access_size = value(defs, "ROM_ACCESS_SIZE")
    disk_bytes = value(defs, "ROMDISK_PAGE_BYTES")
    disk_pages = set(range(value(defs, "ROMDISK_FIRST_PAGE"),
                           value(defs, "ROMDISK_FIRST_PAGE") + value(defs, "ROMDISK_PAGE_COUNT")))
    if len(firmware) != BANK_SIZE:
        raise SystemExit("Page-0 firmware must be exactly 64 KiB")
    boots = [x for x in payloads if x.kind == "boot"]
    if len(boots) != 1 or (boots[0].bank, boots[0].ram_bank) != (boot_page, value(defs, "OS_BANK")):
        raise SystemExit("Boot page/destination configuration differs from the assembled bootstrap")
    for payload in boots:
        if payload.entry != 0 or payload.size != BANK_SIZE:
            raise SystemExit("Boot source must be a complete 64 KiB image at offset zero")
        if payload.data[:boot_limit] != firmware[:boot_limit]:
            raise SystemExit("Boot pages do not have identical zero-page bootstraps")
    disks = [x for x in payloads if x.kind == "romdisk"]
    if args.storage_a == "rom" and {x.bank for x in disks} != disk_pages:
        raise SystemExit("ROM disk pages differ from BIOS geometry")
    if not disk_bytes <= access < access + access_size <= BANK_SIZE:
        raise SystemExit("ROM-access primitive overlaps filesystem data or exceeds the page")
    primitive = firmware[access:access + access_size]
    if primitive != bytes([0x01, 0x80, 0x00, 0xed, 0xb0, 0xd3, 0x00]):
        raise SystemExit("Unexpected ROM primitive; review its stackless/latch contract")
    for payload in disks:
        if payload.bank not in disk_pages or payload.entry != 0 or payload.size != disk_bytes:
            raise SystemExit("ROM disk payload differs from BIOS page format")
        start = payload.bank * BANK_SIZE
        image[start + access:start + access + access_size] = primitive
        if image[start:start + disk_bytes] != payload.data:
            raise SystemExit("ROM primitive changed filesystem bytes")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    write_manifest(
        args.manifest,
        args.output,
        args.firmware,
        payloads,
        symbol_status,
        args.console,
        args.storage_a,
    )
    write_report(
        args.report,
        args.output,
        args.firmware,
        payloads,
        symbol_status,
        args.console,
        args.storage_a,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
