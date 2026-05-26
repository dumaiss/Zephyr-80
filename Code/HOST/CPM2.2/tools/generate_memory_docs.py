#!/usr/bin/env python3
"""Generate synchronized Zephyr-80 firmware symbol and memory maps."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


LABEL_PATTERN = re.compile(
    r"^\s*([0-9A-F]{8})\b.*?\b\d+\s+([A-Za-z_][A-Za-z0-9_]*)\s*:",
    re.IGNORECASE,
)
EQU_PATTERN = re.compile(
    r"^\s*([0-9A-F]{8})\s+\d+\s+([A-Za-z_][A-Za-z0-9_]*)\s*=",
    re.IGNORECASE,
)


BIOS_TABLE = [
    ("BOOT", "boot"),
    ("WBOOT", "wboot"),
    ("CONST", "const"),
    ("CONIN", "conin"),
    ("CONOUT", "conout"),
    ("LIST", "list"),
    ("PUNCH", "punch"),
    ("READER", "reader"),
    ("HOME", "home"),
    ("SELDSK", "seldsk"),
    ("SETTRK", "settrk"),
    ("SETSEC", "setsec"),
    ("SETDMA", "setdma"),
    ("READ", "read"),
    ("WRITE", "write"),
    ("LISTST", "listst"),
    ("SECTRAN", "sectran"),
]

EXTENDED_TABLE = [
    ("00h", "MOVE"),
    ("03h", "XMOVE"),
    ("06h", "SELMEM"),
    ("09h", "SETBNK"),
    ("0Ch", "LAUNCH"),
]

IMPLEMENTATION_SYMBOLS = [
    (("cpm_rom_entry_high", "shadow_copy_rom_to_ram"), "Reset copy routine in high firmware memory."),
    (("shadow_copy_rom_to_ram_done",), "Shadow-copy completion branch point."),
    (("cbios_boot_after_rom_copy",), "Stack setup and cold boot handoff."),
    (("BANK_HELPERS_START",), "Low-level bank helper code start."),
    (("bank_select_internal",), "Selects RAM bank and records current bank."),
    (("select_ram_bank0",), "Selects RAM bank 0."),
    (("BANK_HELPERS_END",), "Low-level bank helper code end."),
    (("sio_init",), "Boot-time SIO channel B initialization."),
    (("boot",), "Cold boot implementation; starts the CP/M CCP."),
    (("wboot",), "Warm boot trampoline."),
    (("wboot_resident",), "Protected warm boot implementation; returns to the CP/M CCP."),
    (("WBOOT_RESIDENT_START",), "Resident warm boot body start."),
    (("WBOOT_RESIDENT_END",), "Resident warm boot body end."),
    (("restore_ccp_from_rom",), "Warm boot helper that restores `CBASE` through `FBASE-1` from ROM page 0."),
    (("ctc_disable_interrupts",), "CTC interrupt disable helper."),
    (("prepare_runnable_bank",), "Page-zero and DMA preparation helper."),
    (("init_page_zero",), "Installs `JP WBOOT` and `JP FBASE`."),
    (("runtime_set_default_dma",), "Sets default DMA to `0080h`."),
    (("runtime_clear_default_dma",), "Clears command tail/default DMA area."),
    (("CONSOLE_CODE_START",), "Console BIOS facade start."),
    (("console_init",), "Installs and initializes the default console driver."),
    (("console_set_driver",), "Installs an alternate console driver table."),
    (("const",), "Console status facade."),
    (("conin",), "Blocking console input facade."),
    (("conout",), "Blocking console output facade."),
    (("list",), "No-op list implementation."),
    (("punch",), "No-op punch implementation."),
    (("reader",), "EOF reader implementation."),
    (("listst",), "Ready list-status implementation."),
    (("CONSOLE_CODE_END",), "Console BIOS facade end."),
    (("STORAGE_STUB_CODE_START",), "Storage BIOS facade start."),
    (("home",), "Storage HOME facade; routes to RAM disk backend."),
    (("settrk",), "Storage SETTRK facade; records selected track."),
    (("setsec",), "Storage SETSEC facade; records selected sector."),
    (("seldsk",), "Storage SELDSK facade; returns drive A DPH or no disk."),
    (("setdma",), "Records DMA address."),
    (("read",), "Storage READ facade; transfers from RAM disk."),
    (("write",), "Storage WRITE facade; transfers to RAM disk."),
    (("sectran",), "Returns untranslated 0-based logical sector for no-skew media."),
    (("STORAGE_STUB_CODE_END",), "Storage BIOS facade end."),
    (("RAMDISK_CODE_START",), "RAM disk backend code start."),
    (("ramdisk_seldsk",), "Selects CP/M drive A and returns its DPH."),
    (("ramdisk_read",), "Reads one 128-byte record from RAM disk storage."),
    (("ramdisk_write",), "Writes one 128-byte record to RAM disk storage."),
    (("RAMDISK_DPH",), "Drive A disk parameter header."),
    (("RAMDISK_DPB",), "Drive A disk parameter block."),
    (("RAMDISK_CODE_END",), "RAM disk backend code end."),
    (("CONSOLE_IM2_VECTOR_TABLE_START",), "Console IM2 vector table start."),
    (("CONSOLE_IM2_VECTOR_TABLE_END",), "Console IM2 vector table end."),
    (("CONSOLE_DRIVER_CODE_START",), "Default SIO console driver code start."),
    (("sio_console_driver",), "Default console driver dispatch table."),
    (("sio_console_init",), "Default SIO console driver initialization."),
    (("sio_console_enable_interrupts",), "Enables the SIO/IM2 console interrupt path after boot."),
    (("sio_console_disable_interrupts",), "Disables SIO console interrupts."),
    (("sio_console_isr",), "SIO console interrupt service routine."),
    (("CONSOLE_DRIVER_CODE_END",), "Default SIO console driver code end."),
    (("BANKING_CODE_START",), "Banking extension implementation start."),
    (("SELMEM",), "Select RAM bank."),
    (("SETBNK",), "Record future DMA bank."),
    (("XMOVE",), "Set source/destination banks for next `MOVE`."),
    (("MOVE",), "Same-bank or cross-bank memory move."),
    (("LAUNCH",), "Launch application bank from high memory."),
    (("BANKING_CODE_END",), "Banking extension implementation end."),
    (("BIOS_CODE_END",), "End of generated BIOS code."),
]

RUNTIME_STATE = [
    ("CURRENT_BANK", 1),
    ("cbios_dma_addr", 2),
    ("CONSOLE_DRIVER", 2),
    ("CONOUT_SOFT_COUNT", 2),
    ("SAVED_BANK", 1),
    ("DMA_BANK", 1),
    ("XMOVE_SRC_BANK", 1),
    ("XMOVE_DST_BANK", 1),
    ("XMOVE_PENDING", 1),
    ("APP_LAUNCH_BANK", 1),
    ("MOVE_SRC_PTR", 2),
    ("MOVE_DST_PTR", 2),
    ("MOVE_REMAIN", 2),
    ("MOVE_CHUNK_LEN", 2),
    ("ramdisk_selected_drive", 1),
    ("ramdisk_track", 2),
    ("ramdisk_sector", 2),
    ("RAMDISK_CSV", 16),
    ("RAMDISK_ALV", 18),
    ("CONSOLE_RX_HEAD", 1),
    ("CONSOLE_RX_TAIL", 1),
    ("CONSOLE_RX_COUNT", 1),
    ("CONSOLE_TX_HEAD", 1),
    ("CONSOLE_TX_TAIL", 1),
    ("CONSOLE_TX_COUNT", 1),
    ("CONSOLE_TX_ACTIVE", 1),
    ("CONSOLE_IRQ_ENABLED", 1),
    ("CONSOLE_IRQ_COUNT", 2),
    ("CONSOLE_RX_BUFFER", 16),
    ("CONSOLE_TX_BUFFER", 16),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listing", required=True, type=Path)
    parser.add_argument("--map", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--firmware-bin", required=True, type=Path)
    parser.add_argument("--pre-swap-image", required=True, type=Path)
    parser.add_argument("--final-image", required=True, type=Path)
    parser.add_argument("--symbol-map", required=True, type=Path)
    parser.add_argument("--memory-map", required=True, type=Path)
    return parser.parse_args()


def parse_listing(path: Path) -> dict[str, int]:
    if not path.is_file():
        raise SystemExit(f"Missing assembler listing: {path}")

    symbols: dict[str, int] = {}
    for line in path.read_text(errors="replace").splitlines():
        match = LABEL_PATTERN.match(line) or EQU_PATTERN.match(line)
        if match:
            address = int(match.group(1), 16)
            name = match.group(2)
            symbols.setdefault(name, address)
    return symbols


def parse_manifest(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise SystemExit(f"Missing layout manifest: {path}")

    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def require_file(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"Missing input artifact: {path}")


def require_symbol(symbols: dict[str, int], name: str) -> int:
    try:
        return symbols[name]
    except KeyError as exc:
        raise SystemExit(f"Missing required symbol in listing: {name}") from exc


def h4(value: int) -> str:
    return f"{value:04X}h"


def h2(value: int) -> str:
    return f"{value:02X}h"


def span(start: int, end: int) -> str:
    if end < start:
        return f"{h4(start)}-{h4(end)}"
    if start == end:
        return h4(start)
    return f"{h4(start)}-{h4(end)}"


def artifact_size(path: Path) -> int:
    require_file(path)
    return path.stat().st_size


def manifest_int(values: dict[str, str], key: str) -> int:
    value = values[key]
    if value.lower().endswith("h"):
        return int(value[:-1], 16)
    return int(value, 10)


def symbol_row(symbols: dict[str, int], names: tuple[str, ...], notes: str) -> str:
    address = require_symbol(symbols, names[0])
    for alias in names[1:]:
        alias_address = require_symbol(symbols, alias)
        if alias_address != address:
            raise SystemExit(f"Symbol aliases do not share an address: {', '.join(names)}")
    label = " / ".join(f"`{name}`" for name in names)
    return f"| {label} | `{h4(address)}` | {notes} |"


def value_row(symbols: dict[str, int], name: str, notes: str) -> str:
    return f"| `{name}` | `{h2(require_symbol(symbols, name))}` | {notes} |"


def range_row(range_text: str, use: str, notes: str) -> str:
    return f"| `{range_text}` | {use} | {notes} |"


def runtime_range(symbols: dict[str, int]) -> tuple[int, int]:
    starts = [
        require_symbol(symbols, "RUNTIME_WORK_AREA_START"),
        require_symbol(symbols, "CONSOLE_STATE_START"),
        require_symbol(symbols, "BANKING_STATE_START"),
        require_symbol(symbols, "STORAGE_STATE_START"),
        require_symbol(symbols, "CONSOLE_DRIVER_STATE_START"),
    ]
    ends = [
        require_symbol(symbols, "RUNTIME_WORK_AREA_END"),
        require_symbol(symbols, "CONSOLE_STATE_END"),
        require_symbol(symbols, "BANKING_STATE_END"),
        require_symbol(symbols, "STORAGE_STATE_END"),
        require_symbol(symbols, "CONSOLE_DRIVER_STATE_END"),
    ]
    return min(starts), max(ends) - 1


def protected_tpa_effective_range(symbols: dict[str, int]) -> tuple[int, int]:
    """Return the portion of the protected TPA marker below the CCP."""
    start = require_symbol(symbols, "PROTECTED_TPA_START")
    end = require_symbol(symbols, "PROTECTED_TPA_END")
    cbase = require_symbol(symbols, "CBASE")
    return start, min(end, cbase - 1)


def payload_rows(values: dict[str, str]) -> list[str]:
    payload_ids = sorted(
        {
            key.split(".")[1]
            for key in values
            if key.startswith("payload.") and len(key.split(".")) >= 3
        },
        key=lambda payload_id: manifest_int(values, f"payload.{payload_id}.bank"),
    )
    rows: list[str] = []
    for payload_id in payload_ids:
        name = values.get(f"payload.{payload_id}.name", payload_id)
        rows.append(
            f"| {name} | {values[f'payload.{payload_id}.bank']} | "
            f"`{values[f'payload.{payload_id}.entry']}` | "
            f"{values[f'payload.{payload_id}.size']} | "
            f"`{values[f'payload.{payload_id}.end']}` | "
            f"`{values[f'payload.{payload_id}.path']}` |"
        )
    if not rows:
        raise SystemExit("No payload entries found in layout manifest")
    return rows


def ramdisk_rows(values: dict[str, str]) -> list[str]:
    if "ramdisk.name" not in values:
        raise SystemExit("No RAM disk entry found in layout manifest")
    bank_base = manifest_int(values, "ramdisk.bank_base")
    bank_limit = manifest_int(values, "ramdisk.bank_limit")
    return [
        (
            f"| {values['ramdisk.name']} | "
            f"{values['ramdisk.first_bank']}-{values['ramdisk.last_bank']} | "
            f"`{h4(bank_base)}-{h4(bank_limit - 1)}` | "
            f"{values['ramdisk.image_size']} | {values['ramdisk.total_bytes']} | "
            f"{values['ramdisk.pad_size']} | `{values['ramdisk.fill']}` | "
            f"`{values['ramdisk.path']}` |"
        )
    ]


def write_symbol_map(args: argparse.Namespace, symbols: dict[str, int], manifest: dict[str, str]) -> None:
    lines = [
        "# Zephyr-80 CP/M 2.2 Symbol Map",
        "",
        "Generated by `tools/generate_memory_docs.py` from `build/firmware.lst`, `build/firmware.map`, and `build/layout.manifest`.",
        "",
        "The complete ASxxxx symbol output is available at `build/firmware.map`. This file records stable project-facing symbols because ASxxxx truncates long names in its summary table.",
        "",
        "## Build Artifacts",
        "",
        "| Artifact | Path | Size |",
        "|---|---|---:|",
        f"| Firmware binary | `{args.firmware_bin}` | {artifact_size(args.firmware_bin)} bytes |",
        f"| Firmware symbol map | `{args.map}` | {artifact_size(args.map)} bytes |",
        f"| Pre-swap image | `{args.pre_swap_image}` | {artifact_size(args.pre_swap_image)} bytes |",
        f"| Final burnable image | `{args.final_image}` | {artifact_size(args.final_image)} bytes |",
        f"| Layout manifest | `{args.manifest}` | {artifact_size(args.manifest)} bytes |",
        "",
        "## Reset And CP/M Common Symbols",
        "",
        "| Symbol | Address | Notes |",
        "|---|---:|---|",
        symbol_row(symbols, ("reset_vector",), "ROM reset entry."),
        symbol_row(symbols, ("bdos_entry_shim",), "High BIOS BDOS compatibility shim; jumps to stock BDOS."),
        symbol_row(symbols, ("CBASE",), "CP/M CCP base for the configured memory size."),
        symbol_row(symbols, ("FBASE",), "CP/M BDOS entry in this assembled image."),
        symbol_row(symbols, ("CCP_ENTRY",), "CCP command processor entry alias for `CBASE`."),
        symbol_row(symbols, ("CCP_CLEARBUF_ENTRY",), "CCP warm-entry target after clearing the command buffer."),
        symbol_row(symbols, ("PROTECTED_TPA_START",), "Start marker for the non-banked protected TPA window."),
        symbol_row(symbols, ("PROTECTED_TPA_END",), "End marker for the non-banked protected TPA window."),
        "",
        "## Banking Latch Constants",
        "",
        "| Symbol | Value | Notes |",
        "|---|---:|---|",
        value_row(symbols, "BANK_PORT", "Memory banking latch I/O port."),
        value_row(symbols, "SHADOW_BIT", "Enables ROM-to-RAM shadow/copy mode while ROM remains visible."),
        value_row(symbols, "ROMDIS_BIT", "Disables ROM and selects RAM-only operation."),
        value_row(symbols, "ROM_VISIBLE_BANK0", "Normal ROM-visible mode for ROM page 0 / RAM bank 0; used when restoring high-common CCP bytes."),
        value_row(symbols, "COPY_LATCH0", "Shadow/copy mode for ROM page 0 / RAM bank 0; reads ROM only below `C000h`."),
        value_row(symbols, "RAM_ONLY_BANK0", "RAM-only mode for bank 0 after ROM-copy operations."),
        "",
        "## BIOS Jump Table",
        "",
        "| Entry | Address | Target |",
        "|---|---:|---|",
    ]
    for entry, target in BIOS_TABLE:
        lines.append(f"| `{entry}` | `{h4(require_symbol(symbols, entry))}` | `{target}` |")

    ext_base = require_symbol(symbols, "ZBIOS_EXT_BASE")
    lines.append(f"| `ZBIOS_EXT_BASE` | `{h4(ext_base)}` | Extended BIOS jump table base. |")
    for offset_text, target in EXTENDED_TABLE:
        offset = int(offset_text[:-1], 16)
        lines.append(f"| `ZBIOS_EXT_BASE + {offset_text}` | `{h4(ext_base + offset)}` | `{target}` |")

    lines.extend(
        [
            "",
            "## BIOS Implementation Symbols",
            "",
            "| Symbol | Address | Notes |",
            "|---|---:|---|",
        ]
    )
    for names, notes in IMPLEMENTATION_SYMBOLS:
        lines.append(symbol_row(symbols, names, notes))

    lines.extend(
        [
            "",
            "## Runtime State Symbols",
            "",
            "| Symbol | Address | Notes |",
            "|---|---:|---|",
            symbol_row(symbols, ("RUNTIME_WORK_AREA_START",), "Runtime work area start."),
            symbol_row(symbols, ("CURRENT_BANK",), "Active RAM bank record."),
            symbol_row(symbols, ("cbios_dma_addr",), "Current DMA address."),
            symbol_row(symbols, ("RUNTIME_WORK_AREA_END",), "Runtime work area end."),
            symbol_row(symbols, ("CONSOLE_STATE_START",), "Console state start."),
            symbol_row(symbols, ("CONSOLE_DRIVER",), "Active console driver table pointer."),
            symbol_row(symbols, ("CONOUT_SOFT_COUNT",), "Reserved console facade word."),
            symbol_row(symbols, ("CONSOLE_STATE_END",), "Console state end."),
            symbol_row(symbols, ("BANKING_STATE_START",), "Banking state start."),
            symbol_row(symbols, ("SAVED_BANK",), "Saved active bank for cross-bank moves."),
            symbol_row(symbols, ("DMA_BANK",), "Recorded DMA bank."),
            symbol_row(symbols, ("XMOVE_SRC_BANK",), "Source bank for pending cross-bank move."),
            symbol_row(symbols, ("XMOVE_DST_BANK",), "Destination bank for pending cross-bank move."),
            symbol_row(symbols, ("XMOVE_PENDING",), "Pending cross-bank move flag."),
            symbol_row(symbols, ("APP_LAUNCH_BANK",), "Target bank for `LAUNCH`."),
            symbol_row(symbols, ("MOVE_SRC_PTR",), "Cross-bank move source pointer."),
            symbol_row(symbols, ("MOVE_DST_PTR",), "Cross-bank move destination pointer."),
            symbol_row(symbols, ("MOVE_REMAIN",), "Cross-bank move remaining byte count."),
            symbol_row(symbols, ("MOVE_CHUNK_LEN",), "Current cross-bank chunk length."),
            symbol_row(symbols, ("BANKING_STATE_END",), "Banking state end."),
            symbol_row(symbols, ("STORAGE_STATE_START",), "Storage state start."),
            symbol_row(symbols, ("ramdisk_selected_drive",), "Selected storage drive, or `FFh` for unsupported."),
            symbol_row(symbols, ("ramdisk_track",), "Selected CP/M track."),
            symbol_row(symbols, ("ramdisk_sector",), "Selected 0-based CP/M sector."),
            symbol_row(symbols, ("RAMDISK_CSV",), "RAM disk check vector."),
            symbol_row(symbols, ("RAMDISK_ALV",), "RAM disk allocation vector."),
            symbol_row(symbols, ("STORAGE_STATE_END",), "Storage state end."),
            symbol_row(symbols, ("CONSOLE_DRIVER_STATE_START",), "Console driver state start."),
            symbol_row(symbols, ("CONSOLE_RX_HEAD",), "Receive buffer head index."),
            symbol_row(symbols, ("CONSOLE_RX_TAIL",), "Receive buffer tail index."),
            symbol_row(symbols, ("CONSOLE_RX_COUNT",), "Receive buffer byte count."),
            symbol_row(symbols, ("CONSOLE_TX_HEAD",), "Transmit buffer head index."),
            symbol_row(symbols, ("CONSOLE_TX_TAIL",), "Transmit buffer tail index."),
            symbol_row(symbols, ("CONSOLE_TX_COUNT",), "Transmit buffer byte count."),
            symbol_row(symbols, ("CONSOLE_TX_ACTIVE",), "Transmit byte active flag."),
            symbol_row(symbols, ("CONSOLE_IRQ_ENABLED",), "SIO console IRQ mode flag."),
            symbol_row(symbols, ("CONSOLE_IRQ_COUNT",), "SIO ISR entry counter."),
            symbol_row(symbols, ("CONSOLE_RX_BUFFER",), "Receive ring buffer."),
            symbol_row(symbols, ("CONSOLE_TX_BUFFER",), "Transmit ring buffer."),
            symbol_row(symbols, ("CONSOLE_DRIVER_STATE_END",), "Console driver state end."),
            "",
        ]
    )
    args.symbol_map.write_text("\n".join(lines))


def write_memory_map(args: argparse.Namespace, symbols: dict[str, int], manifest: dict[str, str]) -> None:
    common_base = manifest_int(manifest, "common.base")
    cbios_base = require_symbol(symbols, "CBIOS_BASE")
    bios_code_end = require_symbol(symbols, "BIOS_CODE_END")
    code_limit = require_symbol(symbols, "CBIOS_CODE_LIMIT")
    stack_guard = require_symbol(symbols, "CBIOS_STACK_GUARD")
    stack_top = require_symbol(symbols, "CBIOS_STACK_TOP")
    area_end = require_symbol(symbols, "CBIOS_AREA_END")
    runtime_start, runtime_end = runtime_range(symbols)
    protected_tpa_start = require_symbol(symbols, "PROTECTED_TPA_START")
    protected_tpa_end = require_symbol(symbols, "PROTECTED_TPA_END")
    protected_tpa_effective_start, protected_tpa_effective_end = protected_tpa_effective_range(symbols)
    banked_tpa_end = min(require_symbol(symbols, "CBASE") - 1, protected_tpa_start - 1)

    lines = [
        "# Zephyr-80 CP/M 2.2 Memory Map",
        "",
        "Generated by `tools/generate_memory_docs.py` from `build/firmware.lst`, `build/layout.manifest`, and image artifacts.",
        "",
        "## Address Space Overview",
        "",
        "| Range | Use | Notes |",
        "|---|---|---|",
        range_row(span(0x0000, 0x00FF), "Page zero and default DMA area", "Runtime code installs `JP WBOOT` at `0000h` and `JP FBASE` at `0005h`; default DMA/command tail starts at `0080h`."),
        range_row(span(0x0100, banked_tpa_end), "CP/M banked TPA", "Runnable programs may use this banked low-memory range."),
        range_row(
            span(protected_tpa_effective_start, protected_tpa_effective_end),
            "CP/M protected TPA",
            f"Non-banked marker range is `{span(protected_tpa_start, protected_tpa_end)}`; the effective TPA portion stops before `CBASE`.",
        ),
        range_row(span(require_symbol(symbols, "CBASE"), require_symbol(symbols, "CCPSTACK")), "CP/M CCP", f"`CBASE` is `{h4(require_symbol(symbols, 'CBASE'))}`."),
        range_row(span(require_symbol(symbols, "FBASE"), cbios_base - 1), "CP/M BDOS and state", f"`FBASE` is `{h4(require_symbol(symbols, 'FBASE'))}` in the current assembled image."),
        range_row(span(cbios_base, bios_code_end - 1), "Zephyr BIOS code", "BIOS jump table, boot, console facade and driver, storage facade, RAM disk backend, banking, and launch routines."),
        range_row(span(bios_code_end, code_limit - 1), "Reserved high BIOS/code space", "Available within the current firmware map for later BIOS code or validation reservations."),
        range_row(span(require_symbol(symbols, "CBIOS_SCRATCH_BASE"), require_symbol(symbols, "CBIOS_SCRATCH_END")), "Protected BIOS scratch buffers", f"`MOVE_BUFFER` is at `{h4(require_symbol(symbols, 'MOVE_BUFFER'))}`; `RAMDISK_DIRBUF` is at `{h4(require_symbol(symbols, 'RAMDISK_DIRBUF'))}`."),
        range_row(span(runtime_start, runtime_end), "BIOS runtime state", "Current bank, DMA address, console driver state, storage state, and banking state."),
        range_row(span(stack_guard, area_end), "Protected firmware stack and work window", f"Stack top is `{h4(stack_top)}`; stack guard is `{h4(stack_guard)}`."),
        "",
        "## Firmware Code Layout",
        "",
        "| Range | Component |",
        "|---|---|",
        f"| `{span(require_symbol(symbols, 'reset_vector'), require_symbol(symbols, 'reset_vector') + 2)}` | Reset vector: `JP cpm_rom_entry_high`. |",
        f"| `{span(require_symbol(symbols, 'CBASE'), require_symbol(symbols, 'CCPSTACK'))}` | CP/M CCP area through `CCPSTACK`. |",
        f"| `{span(require_symbol(symbols, 'FBASE'), cbios_base - 1)}` | CP/M BDOS, BDOS work variables, and CP/M tables. |",
        f"| `{span(require_symbol(symbols, 'CBIOS_JUMP_TABLE'), require_symbol(symbols, 'bdos_entry_shim') - 1)}` | Standard BIOS jump table plus `ZBIOS_EXT_BASE`. |",
        f"| `{span(require_symbol(symbols, 'bdos_entry_shim'), require_symbol(symbols, 'bdos_entry_shim') + 2)}` | `bdos_entry_shim`: compatibility jump to `FBASE`. |",
        f"| `{span(require_symbol(symbols, 'cpm_rom_entry_high'), require_symbol(symbols, 'BANK_HELPERS_START') - 1)}` | ROM-to-RAM shadow-copy boot code. |",
        f"| `{span(require_symbol(symbols, 'BANK_HELPERS_START'), require_symbol(symbols, 'BANK_HELPERS_END') - 1)}` | Low-level bank selection helpers. |",
        f"| `{span(require_symbol(symbols, 'sio_init'), require_symbol(symbols, 'boot') - 1)}` | SIO channel B initialization. |",
        f"| `{span(require_symbol(symbols, 'boot'), require_symbol(symbols, 'CONSOLE_CODE_START') - 1)}` | Cold boot, warm boot, CCP restore, page-zero, DMA, CTC helpers, and alignment gap. |",
        f"| `{span(require_symbol(symbols, 'CONSOLE_CODE_START'), require_symbol(symbols, 'CONSOLE_CODE_END') - 1)}` | Console BIOS facade. |",
        f"| `{span(require_symbol(symbols, 'STORAGE_STUB_CODE_START'), require_symbol(symbols, 'STORAGE_STUB_CODE_END') - 1)}` | Storage BIOS facade. |",
        f"| `{span(require_symbol(symbols, 'RAMDISK_CODE_START'), require_symbol(symbols, 'RAMDISK_CODE_END') - 1)}` | RAM disk backend, Drive A DPH, and DPB. |",
        f"| `{span(require_symbol(symbols, 'CONSOLE_DRIVER_CODE_START'), require_symbol(symbols, 'CONSOLE_DRIVER_CODE_END') - 1)}` | Default SIO console driver. |",
        f"| `{span(require_symbol(symbols, 'CONSOLE_IM2_VECTOR_TABLE_START'), require_symbol(symbols, 'CONSOLE_IM2_VECTOR_TABLE_END') - 1)}` | Console IM2 vector table. |",
        f"| `{span(require_symbol(symbols, 'BANKING_CODE_START'), bios_code_end - 1)}` | Banking and high-memory `LAUNCH` implementation. |",
        "",
        "## BIOS Jump Table Layout",
        "",
        "| Address | Entry |",
        "|---:|---|",
    ]
    for entry, target in BIOS_TABLE:
        lines.append(f"| `{h4(require_symbol(symbols, entry))}` | `JP {target}` |")
    ext_base = require_symbol(symbols, "ZBIOS_EXT_BASE")
    for offset_text, target in EXTENDED_TABLE:
        offset = int(offset_text[:-1], 16)
        lines.append(f"| `{h4(ext_base + offset)}` | `JP {target}` |")

    lines.extend(
        [
            "",
            "## Runtime State Layout",
            "",
            "| Range | State |",
            "|---|---|",
        ]
    )
    for name, size in RUNTIME_STATE:
        start = require_symbol(symbols, name)
        lines.append(f"| `{span(start, start + size - 1)}` | `{name}` |")

    lines.extend(
        [
            "",
            "## Image Payload Layout",
            "",
            "| Payload | Bank | Entry | Size | End | Source |",
            "|---|---:|---:|---:|---:|---|",
            *payload_rows(manifest),
            "",
            "## RAM Disk Layout",
            "",
            "| Name | Banks | Range per Bank | Image Size | Capacity | Pad | Fill | Source |",
            "|---|---:|---:|---:|---:|---:|---:|---|",
            *ramdisk_rows(manifest),
            "",
            "## Image Artifacts",
            "",
            "| Artifact | Size | Notes |",
            "|---|---:|---|",
            f"| `{args.firmware_bin}` | {artifact_size(args.firmware_bin)} bytes | Firmware image before payload attachment. |",
            f"| `{args.pre_swap_image}` | {artifact_size(args.pre_swap_image)} bytes | Logical image after payload attachment and before CPU-board bit swap. |",
            f"| `{args.final_image}` | {artifact_size(args.final_image)} bytes | Final burnable image after `tools/swapbits.py`. |",
            "",
            "## Validation Notes",
            "",
            "- CP/M drive A is backed by RAM banks 2-7 across `0000h-BFFFh` in each bank.",
            "- The RAM disk seed image is copied from ROM to RAM during boot shadow-copy, then writes mutate RAM only.",
            f"- The protected TPA marker is `{span(protected_tpa_start, protected_tpa_end)}`; for this build, the application-usable protected TPA subrange is `{span(protected_tpa_effective_start, protected_tpa_effective_end)}` because `CBASE` starts at `{h4(require_symbol(symbols, 'CBASE'))}`.",
            f"- WBOOT restores the CCP range `{span(require_symbol(symbols, 'CBASE'), require_symbol(symbols, 'FBASE') - 1)}` from ROM page 0 using `ROM_VISIBLE_BANK0` (`{h2(require_symbol(symbols, 'ROM_VISIBLE_BANK0'))}`) before returning to `CCP_CLEARBUF_ENTRY`.",
            f"- `CBIOS_BASE` is `{h4(cbios_base)}`; CBIOS layout constants are derived from this base.",
            f"- `LAUNCH` code resides at `{h4(require_symbol(symbols, 'LAUNCH'))}`, inside protected high BIOS memory.",
            f"- `WBOOT` resident code starts at `{h4(require_symbol(symbols, 'WBOOT_RESIDENT_START'))}`, inside protected high BIOS memory.",
            f"- `ZBIOS_EXT_BASE` is at `{h4(ext_base)}` and exposes `MOVE`, `XMOVE`, `SELMEM`, `SETBNK`, and `LAUNCH`.",
            f"- The final bit-swapped image is `{args.final_image}`.",
            "",
        ]
    )
    args.memory_map.write_text("\n".join(lines))


def main() -> int:
    args = parse_args()
    require_file(args.map)
    symbols = parse_listing(args.listing)
    manifest = parse_manifest(args.manifest)

    args.symbol_map.parent.mkdir(parents=True, exist_ok=True)
    args.memory_map.parent.mkdir(parents=True, exist_ok=True)
    write_symbol_map(args, symbols, manifest)
    write_memory_map(args, symbols, manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
