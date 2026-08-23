#!/usr/bin/env python3
"""Build the Zephyr-80 paged CP/M image."""

from __future__ import annotations

import argparse
import configparser
from dataclasses import dataclass
from pathlib import Path
import re
import sys


APP_BASE = 0x0100
COMMON_BASE = 0xC000
BANK_SIZE = 0x10000
MAX_BANK = 7
IMAGE_BANK_COUNT = 2  # bank 0 = firmware/CP/M; banks 1-7 empty
REQUIRED_SYMBOLS = ("MOVE", "XMOVE", "SELMEM", "SETBNK")
DEFAULT_DEFS_PATH = Path("src/cbios_defs.inc")


@dataclass(frozen=True)
class Payload:
    key: str
    name: str
    bank: int
    path: Path
    entry: int = APP_BASE

    @property
    def data(self) -> bytes:
        return self.path.read_bytes()

    @property
    def size(self) -> int:
        return self.path.stat().st_size

    @property
    def end_exclusive(self) -> int:
        return self.entry + self.size


@dataclass(frozen=True)
class RamDiskGeometry:
    first_bank: int
    last_bank: int
    bank_base: int
    bank_limit: int
    bank_bytes: int

    @property
    def bank_count(self) -> int:
        return self.last_bank - self.first_bank + 1

    @property
    def total_bytes(self) -> int:
        return self.bank_count * self.bank_bytes


@dataclass(frozen=True)
class RamDiskImage:
    name: str
    path: Path
    fill: int
    data: bytes
    geometry: RamDiskGeometry

    @property
    def size(self) -> int:
        return len(self.data)

    @property
    def pad_size(self) -> int:
        return self.geometry.total_bytes - self.size

    @property
    def prepared(self) -> bytes:
        return self.data + bytes([self.fill]) * self.pad_size


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


def parse_asm_int(value: str, label: str, raw_values: dict[str, str], seen: set[str] | None = None) -> int:
    seen = seen or set()
    raw = value.split(";", 1)[0].strip()
    if not raw:
        raise SystemExit(f"Invalid empty assembly value for {label}")
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", raw):
        if raw in seen:
            raise SystemExit(f"Recursive assembly constant reference: {raw}")
        if raw not in raw_values:
            raise SystemExit(f"Unknown assembly constant in {label}: {raw}")
        return parse_asm_int(raw_values[raw], raw, raw_values, seen | {raw})
    if re.fullmatch(r"[0-9A-Fa-f]+h", raw):
        return int(raw[:-1], 16)
    if re.fullmatch(r"0x[0-9A-Fa-f]+|[0-9]+", raw):
        return int(raw, 0)

    parts = re.split(r"(\+|-)", raw)
    total = parse_asm_int(parts[0], label, raw_values, seen)
    index = 1
    while index < len(parts):
        op = parts[index]
        rhs = parse_asm_int(parts[index + 1], label, raw_values, seen)
        total = total + rhs if op == "+" else total - rhs
        index += 2
    return total


def parse_ramdisk_geometry(path: Path) -> RamDiskGeometry:
    require_file(path, "CBIOS definitions")

    raw_values: dict[str, str] = {}
    equate_pattern = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$")
    for line in path.read_text().splitlines():
        match = equate_pattern.match(line)
        if match:
            raw_values[match.group(1)] = match.group(2).split(";", 1)[0].strip()

    required = (
        "RAMDISK_FIRST_BANK",
        "RAMDISK_LAST_BANK",
        "RAMDISK_BANK_BASE",
        "RAMDISK_BANK_LIMIT",
        "RAMDISK_BANK_BYTES",
    )
    missing = [name for name in required if name not in raw_values]
    if missing:
        raise SystemExit("Missing RAM disk geometry constants: " + ", ".join(missing))

    geometry = RamDiskGeometry(
        first_bank=parse_asm_int(raw_values["RAMDISK_FIRST_BANK"], "RAMDISK_FIRST_BANK", raw_values),
        last_bank=parse_asm_int(raw_values["RAMDISK_LAST_BANK"], "RAMDISK_LAST_BANK", raw_values),
        bank_base=parse_asm_int(raw_values["RAMDISK_BANK_BASE"], "RAMDISK_BANK_BASE", raw_values),
        bank_limit=parse_asm_int(raw_values["RAMDISK_BANK_LIMIT"], "RAMDISK_BANK_LIMIT", raw_values),
        bank_bytes=parse_asm_int(raw_values["RAMDISK_BANK_BYTES"], "RAMDISK_BANK_BYTES", raw_values),
    )
    if geometry.first_bank < 0 or geometry.last_bank > MAX_BANK or geometry.first_bank > geometry.last_bank:
        raise SystemExit(
            "RAM disk bank range is outside supported banks: "
            f"{geometry.first_bank}-{geometry.last_bank}, supported 0-{MAX_BANK}"
        )
    if geometry.bank_base < 0 or geometry.bank_limit > COMMON_BASE or geometry.bank_base >= geometry.bank_limit:
        raise SystemExit(
            "RAM disk bank address range overlaps common memory or is invalid: "
            f"{geometry.bank_base:04X}h-{geometry.bank_limit:04X}h"
        )
    if geometry.bank_bytes != geometry.bank_limit - geometry.bank_base:
        raise SystemExit(
            "RAMDISK_BANK_BYTES does not match RAMDISK_BANK_LIMIT - RAMDISK_BANK_BASE: "
            f"{geometry.bank_bytes} != {geometry.bank_limit - geometry.bank_base}"
        )
    return geometry


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
        payload = Payload(key=key, name=name, bank=bank, path=Path(values["path"]), entry=entry)
        if key in seen_keys:
            raise SystemExit(f"Duplicate payload section key: {key}")
        if bank in seen_banks:
            raise SystemExit(f"Multiple payloads configured for bank {bank}")
        seen_keys.add(key)
        seen_banks.add(bank)
        payloads.append(payload)

    return payloads


def ramdisk_from_config(path: Path, geometry: RamDiskGeometry) -> RamDiskImage:
    require_file(path, "payload configuration")

    config = configparser.ConfigParser()
    config.optionxform = str
    config.read(path)

    if "ramdisk" not in config:
        raise SystemExit(f"Missing required [ramdisk] section in {path}")

    values = config["ramdisk"]
    if "path" not in values:
        raise SystemExit("Missing path in [ramdisk] section")

    name = values.get("name", "RAM disk").strip()
    image_path = Path(values["path"])
    fill = parse_int(values.get("fill", "E5h"), "ramdisk.fill")
    if fill < 0 or fill > 0xFF:
        raise SystemExit(f"RAM disk fill byte is outside 00h-FFh: {fill}")
    require_file(image_path, "RAM disk image")

    data = image_path.read_bytes()
    if len(data) > geometry.total_bytes:
        raise SystemExit(
            f"RAM disk image is too large: {len(data)} bytes, "
            f"capacity is {geometry.total_bytes} bytes"
        )
    return RamDiskImage(name=name, path=image_path, fill=fill, data=data, geometry=geometry)


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
    if payload.end_exclusive > COMMON_BASE:
        raise SystemExit(
            f"{payload.name} payload overlaps common memory: "
            f"entry={payload.entry:04X}h size={payload.size} "
            f"end={payload.end_exclusive:04X}h limit={COMMON_BASE:04X}h"
        )


def validate_ramdisk_conflicts(payloads: list[Payload], ramdisk: RamDiskImage | None) -> None:
    if ramdisk is None:
        return
    reserved = set(range(ramdisk.geometry.first_bank, ramdisk.geometry.last_bank + 1))
    conflicts = [payload for payload in payloads if payload.bank in reserved]
    if conflicts:
        names = ", ".join(f"{payload.name} bank {payload.bank}" for payload in conflicts)
        raise SystemExit(f"Payload bank conflicts with RAM disk reserved banks: {names}")


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


def place_ramdisk(image: bytearray, ramdisk: RamDiskImage) -> None:
    prepared = ramdisk.prepared
    offset = 0
    for bank in range(ramdisk.geometry.first_bank, ramdisk.geometry.last_bank + 1):
        start = bank * BANK_SIZE + ramdisk.geometry.bank_base
        end = start + ramdisk.geometry.bank_bytes
        if end > len(image):
            raise SystemExit(f"RAM disk bank {bank} exceeds image size")
        image[start:end] = prepared[offset : offset + ramdisk.geometry.bank_bytes]
        offset += ramdisk.geometry.bank_bytes


def write_manifest(
    path: Path,
    output: Path,
    firmware: Path,
    payloads: list[Payload],
    ramdisk: RamDiskImage | None,
    symbol_status: dict[str, str],
) -> None:
    lines = [
        f"image.name={output.name}",
        "image.status=valid",
        f"firmware.path={firmware}",
        f"common.base={COMMON_BASE:04X}h",
    ]
    for payload in payloads:
        lines.extend(
            [
                f"payload.{payload.key}.name={payload.name}",
                f"payload.{payload.key}.path={payload.path}",
                f"payload.{payload.key}.bank={payload.bank}",
                f"payload.{payload.key}.entry={payload.entry:04X}h",
                f"payload.{payload.key}.size={payload.size}",
                f"payload.{payload.key}.end={payload.end_exclusive:04X}h",
            ]
        )
    if ramdisk is not None:
        lines.extend(
            [
                f"ramdisk.name={ramdisk.name}",
                f"ramdisk.path={ramdisk.path}",
                f"ramdisk.fill={ramdisk.fill:02X}h",
                f"ramdisk.first_bank={ramdisk.geometry.first_bank}",
                f"ramdisk.last_bank={ramdisk.geometry.last_bank}",
                f"ramdisk.bank_base={ramdisk.geometry.bank_base:04X}h",
                f"ramdisk.bank_limit={ramdisk.geometry.bank_limit:04X}h",
                f"ramdisk.bank_bytes={ramdisk.geometry.bank_bytes}",
                f"ramdisk.total_bytes={ramdisk.geometry.total_bytes}",
                f"ramdisk.image_size={ramdisk.size}",
                f"ramdisk.pad_size={ramdisk.pad_size}",
            ]
        )
    else:
        lines.append("storage.backend=vdrip_proxy")
    for symbol, status in symbol_status.items():
        lines.append(f"symbol.{symbol}={status}")
    lines.extend(["validation.payloads=pass"])
    path.write_text("\n".join(lines) + "\n")


def write_report(
    path: Path,
    output: Path,
    firmware: Path,
    payloads: list[Payload],
    ramdisk: RamDiskImage | None,
    symbol_status: dict[str, str],
) -> None:
    lines = [
        "# Zephyr-80 Image Layout Report",
        "",
        f"- Image: `{output}`",
        f"- Firmware input: `{firmware}`",
        f"- Common memory base: `{COMMON_BASE:04X}h`",
        "",
        "## Payloads",
        "",
        "| Payload | Bank | Entry | Size | End | Source |",
        "|---|---:|---:|---:|---:|---|",
    ]
    for payload in payloads:
        lines.append(
            f"| {payload.name} | {payload.bank} | `{payload.entry:04X}h` | "
            f"{payload.size} | `{payload.end_exclusive:04X}h` | `{payload.path}` |"
        )
    if ramdisk is not None:
        lines.extend(
            [
                "",
                "## RAM Disk",
                "",
                "| Name | Banks | Range per Bank | Image Size | Capacity | Pad | Fill | Source |",
                "|---|---:|---:|---:|---:|---:|---:|---|",
                (
                    f"| {ramdisk.name} | {ramdisk.geometry.first_bank}-{ramdisk.geometry.last_bank} | "
                    f"`{ramdisk.geometry.bank_base:04X}h-{ramdisk.geometry.bank_limit - 1:04X}h` | "
                    f"{ramdisk.size} | {ramdisk.geometry.total_bytes} | {ramdisk.pad_size} | "
                    f"`{ramdisk.fill:02X}h` | `{ramdisk.path}` |"
                ),
            ]
        )
    else:
        lines.extend(
            [
                "",
                "## Storage",
                "",
                "- Drive A is backed by VDrip proxy storage; no RAM disk image is embedded in ROM banks.",
            ]
        )
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
            "- Drive A is backed by VDrip proxy storage; banks 2-7 are not populated with a RAM disk seed image.",
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
        raise SystemExit("RAM disk embedding has been replaced by VDrip proxy storage; remove [ramdisk]")
    ramdisk = None
    for payload in payloads:
        require_file(payload.path, f"{payload.name} payload")
        validate_payload(payload)
    validate_ramdisk_conflicts(payloads, ramdisk)

    symbol_status = validate_symbols(args.symbols)

    firmware = args.firmware.read_bytes()
    max_payload_bank = max((payload.bank for payload in payloads), default=-1)
    image_size = max(BANK_SIZE * IMAGE_BANK_COUNT, BANK_SIZE * (max_payload_bank + 1), len(firmware))
    if ramdisk is not None:
        image_size = max(image_size, BANK_SIZE * (ramdisk.geometry.last_bank + 1))
    image = bytearray([0x00] * image_size)
    image[: len(firmware)] = firmware
    for payload in payloads:
        place_payload(image, payload)
    if ramdisk is not None:
        place_ramdisk(image, ramdisk)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    write_manifest(args.manifest, args.output, args.firmware, payloads, ramdisk, symbol_status)
    write_report(args.report, args.output, args.firmware, payloads, ramdisk, symbol_status)
    return 0


if __name__ == "__main__":
    sys.exit(main())
