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
    ("0Ch", "IOCALL"),
    ("0Fh", "VIDEO_SEND"),
    ("12h", "IOCBULK"),
]

IMPLEMENTATION_SYMBOLS = [
    (("cpm_rom_entry_high", "shadow_copy_rom_to_ram"), "Reset copy routine in high firmware memory."),
    (("shadow_copy_rom_to_ram_done",), "Shadow-copy completion branch point."),
    (("cbios_boot_after_rom_copy",), "Stack setup and cold boot handoff."),
    (("BANK_HELPERS_START",), "Low-level bank helper code start."),
    (("bank_select_internal",), "Selects RAM bank and records current bank."),
    (("select_ram_bank0",), "Selects RAM bank 0."),
    (("BANK_HELPERS_END",), "Low-level bank helper code end."),
    (("sio_init",), "Compatibility entry that jumps to `sio_core_init`."),
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
    (("home",), "Storage HOME facade; routes to VDrip storage backend."),
    (("settrk",), "Storage SETTRK facade; records selected track."),
    (("setsec",), "Storage SETSEC facade; records selected sector."),
    (("seldsk",), "Storage SELDSK facade; returns drive A DPH or no disk."),
    (("setdma",), "Records DMA address."),
    (("read",), "Storage READ facade; transfers from VDrip proxy storage."),
    (("write",), "Storage WRITE facade; transfers to VDrip proxy storage."),
    (("sectran",), "Returns untranslated 0-based logical sector for no-skew media."),
    (("STORAGE_STUB_CODE_END",), "Storage BIOS facade end."),
    (("VDRIP_TRANSPORT_CODE_START",), "Shared Virtual Drip transport start."),
    (("vdrip_send_frame",), "Current no-CRC Virtual Drip frame sender."),
    (("vdrip_rx_sink",), "Single SIO0/B Virtual Drip receive sink."),
    (("VDRIP_TRANSPORT_CODE_END",), "Shared Virtual Drip transport end."),
    (("VDRIP_STORAGE_CODE_START",), "VDrip storage backend code start."),
    (("vdrip_storage_seldsk",), "Selects CP/M drive A and returns its DPH."),
    (("vdrip_storage_read",), "Reads one 128-byte record from VDrip proxy storage."),
    (("vdrip_storage_write",), "Writes one 128-byte record to VDrip proxy storage."),
    (("VDRIP_STORAGE_DPH",), "Drive A disk parameter header."),
    (("VDRIP_STORAGE_DPB",), "Drive A disk parameter block."),
    (("VDRIP_STORAGE_CODE_END",), "VDrip storage backend code end."),
    (("SIO_CORE_CODE_START",), "BIOS-owned SIO core code start in core BIOS."),
    (("CONSOLE_IM2_VECTOR_ENTRY",), "SIO core exact IM2 vector table entry address."),
    (("CONSOLE_IM2_VECTOR_TABLE_START",), "SIO core exact IM2 vector table start."),
    (("CONSOLE_IM2_VECTOR_TABLE_END",), "SIO core exact IM2 vector table end."),
    (("sio_core_init",), "Initializes BIOS-owned SIO services, SIO0/B async mode, and SIO1/A sync mode."),
    (("sio1_ioc_init",), "Initializes SIO1/A synchronous external-clock/external-sync IO Controller mode."),
    (("sio_core_enable_interrupts",), "Enables BIOS-owned SIO/IM2 interrupts."),
    (("sio_core_disable_interrupts",), "Disables BIOS-owned SIO interrupts."),
    (("sio_register_rx_sink",), "Registers one RX byte sink for a BIOS-owned SIO channel."),
    (("sio_send_byte",), "Blocking send-byte API for BIOS-owned SIO channels."),
    (("sio_recv_byte",), "Polling receive-byte API for BIOS-owned SIO channels."),
    (("sio0b_rts_assert",), "Asserts SIO0/B RTS for software-managed console RX flow control."),
    (("sio0b_rts_release",), "Releases SIO0/B RTS for software-managed console RX flow control."),
    (("sio1_ioc_rts_assert",), "Asserts SIO1/A RTS as an IO Controller service request."),
    (("sio1_ioc_rts_release",), "Releases SIO1/A RTS after an IO Controller transaction."),
    (("sio1_ioc_put_byte",), "SIO1/A IO Controller byte transmit helper."),
    (("sio1_ioc_get_byte",), "SIO1/A IO Controller byte receive helper."),
    (("sio_rx_kick",), "Foreground RX poll/dispatch helper."),
    (("sio_core_isr",), "BIOS-owned SIO interrupt service routine."),
    (("sio_console_isr",), "Compatibility label that jumps to `sio_core_isr`."),
    (("SIO_CORE_CODE_END",), "BIOS-owned SIO core code end."),
    (("IOCTRL_CODE_START",), "IOCALL transaction code start in core BIOS."),
    (("IOCALL",), "Zephyr extended BIOS IO Controller transaction call."),
    (("IOCTRL_CODE_END",), "IOCALL transaction code end."),
    (("VDRIP_CONSOLE_CODE_START",), "Virtual Drip console driver code start."),
    (("vdrip_console_driver",), "Virtual Drip console driver dispatch table."),
    (("vdrip_console_init",), "Virtual Drip console init, proxy handshake, VDP setup."),
    (("VDRIP_CONSOLE_CODE_END",), "Virtual Drip console driver code end."),
    (("BANKING_CODE_START",), "Banking extension implementation start."),
    (("SELMEM",), "Select RAM bank."),
    (("SETBNK",), "Record future DMA bank."),
    (("XMOVE",), "Set source/destination banks for next `MOVE`."),
    (("MOVE",), "Same-bank or cross-bank memory move."),
    (("BANKING_CODE_END",), "Banking extension implementation end."),
    (("VIDEO_SEND",), "Extended BIOS call: raw VDrip display/VDP packet send."),
    (("IOCBULK",), "Extended BIOS call: bulk-lane receive on SIO1/A; owns the RTS handshake."),
    (("BIOS_EXT_CODE_START",), "BIOS extension code start."),
    (("BIOS_EXT_CODE_END",), "BIOS extension code end."),
    (("BIOS_CODE_END",), "End of core BIOS code."),
]

RUNTIME_STATE = [
    ("CURRENT_BANK", 1),
    ("cbios_dma_addr", 2),
    ("CONSOLE_DRIVER", 2),
    ("CONSOLE_CALLER_SP", 2),
    ("SAVED_BANK", 1),
    ("DMA_BANK", 1),
    ("XMOVE_SRC_BANK", 1),
    ("XMOVE_DST_BANK", 1),
    ("XMOVE_PENDING", 1),
    ("MOVE_SRC_PTR", 2),
    ("MOVE_DST_PTR", 2),
    ("MOVE_REMAIN", 2),
    ("MOVE_CHUNK_LEN", 2),
    ("vdrip_storage_selected_drive", 1),
    ("vdrip_storage_track", 2),
    ("vdrip_storage_sector", 2),
    ("VDRIP_STORAGE_SAVED_BANK", 1),
    ("vdrip_storage_seq", 1),
    ("vdrip_storage_active_seq", 1),
    ("vdrip_storage_lba", 2),
    ("vdrip_rx_mode", 1),
    ("vdrip_idle_mode", 1),
    ("vdrip_proxy_online", 1),
    ("vdrip_raw_callback", 2),
    ("vdrip_rx_state", 1),
    ("vdrip_declared_len", 2),
    ("vdrip_payload_len", 1),
    ("vdrip_rx_type", 1),
    ("vdrip_payload_remaining", 1),
    ("vdrip_payload_index", 1),
    ("vdrip_pending_type", 1),
    ("vdrip_pending_seq", 1),
    ("vdrip_reply_ready", 1),
    ("vdrip_reply_error", 1),
    ("vdrip_reply_status", 1),
    ("storage_caller_sp", 2),
    ("SIO0B_RX_SINK", 2),
    ("SIO1_RX_SINK", 2),
    ("SIO_CORE_IRQ_ENABLED", 1),
    ("SIO_CORE_IRQ_COUNT", 2),
    ("SIO0B_LAST_RR1", 1),
    ("SIO0B_LAST_RX_ERROR", 1),
]

DRIVER_SLOT_OWNERS = {
    0: "Virtual Drip console driver",
    1: "Virtual Drip console driver",
    2: "Virtual Drip console driver",
    3: "Virtual Drip console driver",
    4: "Virtual Drip console driver",
    5: "VDrip transport and storage",
}

DRIVER_DECLARATIONS = [
    ("Virtual Drip console driver", "VDRIP_CONSOLE_CODE_START", "VDRIP_CONSOLE_CODE_END", 0, 5),
    ("Shared VDrip transport", "VDRIP_TRANSPORT_CODE_START", "VDRIP_TRANSPORT_CODE_END", 5, 5),
    ("VDrip storage backend", "VDRIP_STORAGE_CODE_START", "VDRIP_STORAGE_CODE_END", 5, 5),
]

CORE_RANGES = [
    ("BIOS jump table and boot glue", "BIOS_CODE_START", "CONSOLE_CODE_START"),
    ("console facade", "CONSOLE_CODE_START", "CONSOLE_CODE_END"),
    ("storage facade", "STORAGE_STUB_CODE_START", "STORAGE_STUB_CODE_END"),
    ("banking/XMOVE", "BANKING_CODE_START", "BANKING_CODE_END"),
    ("SIO core", "SIO_CORE_CODE_START", "SIO_CORE_CODE_END"),
    ("BIOS extensions", "BIOS_EXT_CODE_START", "BIOS_EXT_CODE_END"),
]

VALIDATION_NOTES = [
    "BIOS core must stay inside CBIOS_CORE_BASE-CBIOS_CORE_END.",
    "Core BIOS component ranges must not overlap.",
    "Each declared driver must stay inside its declared fixed slot range.",
    "Virtual Drip console driver must stay inside slots 0-5.",
    "Shared VDrip transport must stay inside slot 5.",
    "VDrip storage backend must stay inside slot 5.",
    "SIO core and its exact IM2 vector entry must stay inside core BIOS.",
    "Scratch buffers and the storage allocation vector must not overlap resident code.",
    "Runtime state must not overlap scratch, stack, or the SIO-owned IM2 table.",
    "Stack guard must remain above runtime state.",
    "Protected/common TPA C000h-C3FFh is application-owned and must not be used by BIOS.",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listing", required=True, type=Path)
    parser.add_argument("--map", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--firmware-bin", required=True, type=Path)
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


def exclusive_span(start: int, limit: int) -> str:
    return span(start, limit - 1)


def slot_range(symbols: dict[str, int], slot: int) -> tuple[int, int]:
    return (
        require_symbol(symbols, f"CBIOS_DRIVER_SLOT{slot}_BASE"),
        require_symbol(symbols, f"CBIOS_DRIVER_SLOT{slot}_LIMIT"),
    )


def ranges_overlap(left_start: int, left_limit: int, right_start: int, right_limit: int) -> bool:
    return left_start < right_limit and right_start < left_limit


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
        require_symbol(symbols, "SIO_CORE_STATE_START"),
    ]
    ends = [
        require_symbol(symbols, "RUNTIME_WORK_AREA_END"),
        require_symbol(symbols, "CONSOLE_STATE_END"),
        require_symbol(symbols, "BANKING_STATE_END"),
        require_symbol(symbols, "STORAGE_STATE_END"),
        require_symbol(symbols, "SIO_CORE_STATE_END"),
    ]
    return min(starts), max(ends) - 1


def scratch_buffer_ranges(symbols: dict[str, int]) -> list[tuple[str, int, int, str]]:
    move_start = require_symbol(symbols, "MOVE_BUFFER")
    move_limit = move_start + require_symbol(symbols, "MOVE_BUFFER_SIZE")
    dphdpb_start = require_symbol(symbols, "VDRIP_STORAGE_DPHDPB_BASE")
    dphdpb_limit = dphdpb_start + require_symbol(symbols, "VDRIP_STORAGE_DPHDPB_SIZE")
    dirbuf_start = require_symbol(symbols, "VDRIP_STORAGE_DIRBUF")
    dirbuf_limit = dirbuf_start + require_symbol(symbols, "DEFAULT_DMA_LEN")
    alv_start = require_symbol(symbols, "VDRIP_STORAGE_ALV")
    alv_limit = alv_start + require_symbol(symbols, "VDRIP_STORAGE_ALV_SIZE")
    return [
        ("MOVE_BUFFER", move_start, move_limit, "Cross-bank MOVE and VDrip storage transaction staging buffer."),
        ("VDRIP_STORAGE_DPHDPB", dphdpb_start, dphdpb_limit, "CP/M DPH/DPB constants for the VDrip storage disk."),
        ("VDRIP_STORAGE_DIRBUF", dirbuf_start, dirbuf_limit, "CP/M directory buffer referenced by the VDrip storage DPH."),
        ("VDRIP_STORAGE_ALV", alv_start, alv_limit, "CP/M allocation vector for the fixed 8 MiB VDrip work disk."),
    ]


def derived_free_scratch_ranges(symbols: dict[str, int]) -> list[tuple[int, int]]:
    scratch_start = require_symbol(symbols, "CBIOS_SCRATCH_BASE")
    scratch_limit = require_symbol(symbols, "CBIOS_SCRATCH_LIMIT")
    used = sorted((start, limit) for _, start, limit, _ in scratch_buffer_ranges(symbols))
    free: list[tuple[int, int]] = []
    cursor = scratch_start
    for start, limit in used:
        if cursor < start:
            free.append((cursor, start))
        cursor = max(cursor, limit)
    if cursor < scratch_limit:
        free.append((cursor, scratch_limit))
    return free


def validation_error(message: str) -> str:
    return f"ERROR: {message}"


def validate_within(
    errors: list[str],
    symbols: dict[str, int],
    label: str,
    start_sym: str,
    limit_sym: str,
    allowed_start: int,
    allowed_limit: int,
    allowed_name: str,
) -> tuple[int, int]:
    start = require_symbol(symbols, start_sym)
    limit = require_symbol(symbols, limit_sym)
    if start < allowed_start or start >= allowed_limit:
        errors.append(
            validation_error(
                f"{start_sym} = {h4(start)} is outside {allowed_name} "
                f"({exclusive_span(allowed_start, allowed_limit)}) for {label}"
            )
        )
    if limit > allowed_limit:
        errors.append(
            validation_error(
                f"{limit_sym} = {h4(limit)} exceeds {allowed_name} limit "
                f"{h4(allowed_limit)} (last byte {h4(allowed_limit - 1)}) for {label}"
            )
        )
    if limit < start:
        errors.append(validation_error(f"{limit_sym} = {h4(limit)} is below {start_sym} = {h4(start)}"))
    return start, limit


def validate_layout(symbols: dict[str, int]) -> list[str]:
    errors: list[str] = []
    warnings: list[str] = []

    cbios_base = require_symbol(symbols, "CBIOS_BASE")
    cbios_code_limit = require_symbol(symbols, "CBIOS_CODE_LIMIT")
    cbios_core_base = require_symbol(symbols, "CBIOS_CORE_BASE")
    cbios_core_limit = require_symbol(symbols, "CBIOS_CORE_LIMIT")
    scratch_start = require_symbol(symbols, "CBIOS_SCRATCH_BASE")
    scratch_limit = require_symbol(symbols, "CBIOS_SCRATCH_LIMIT")
    runtime_start = require_symbol(symbols, "CBIOS_RUNTIME_STATE_BASE")
    runtime_limit = require_symbol(symbols, "CBIOS_RUNTIME_STATE_LIMIT")
    stack_guard = require_symbol(symbols, "CBIOS_STACK_GUARD")
    im2_start = require_symbol(symbols, "CBIOS_IM2_VECTOR_TABLE")
    im2_limit = require_symbol(symbols, "CBIOS_IM2_VECTOR_LIMIT")

    # Validate core BIOS ranges against both the core region and overall code limit.
    core_component_ranges: list[tuple[str, int, int]] = []
    for label, start_sym, limit_sym in CORE_RANGES:
        start, limit = validate_within(
            errors, symbols, label, start_sym, limit_sym, cbios_core_base, cbios_core_limit, "CBIOS core"
        )
        core_component_ranges.append((label, start, limit))
    for index, (left_label, left_start, left_limit) in enumerate(core_component_ranges):
        for right_label, right_start, right_limit in core_component_ranges[index + 1 :]:
            if ranges_overlap(left_start, left_limit, right_start, right_limit):
                errors.append(
                    validation_error(
                        f"{left_label} ({exclusive_span(left_start, left_limit)}) overlaps "
                        f"{right_label} ({exclusive_span(right_start, right_limit)})"
                    )
                )
    bios_code_end = require_symbol(symbols, "BIOS_CODE_END")
    if bios_code_end > cbios_code_limit:
        errors.append(
            validation_error(
                f"BIOS_CODE_END = {h4(bios_code_end)} crosses CBIOS_CODE_LIMIT = {h4(cbios_code_limit)}"
            )
        )
    if cbios_base < require_symbol(symbols, "CBASE"):
        errors.append(validation_error("CBIOS_BASE is below CBASE; BIOS overlaps CP/M CCP/BDOS space"))

    # Validate declared driver ranges and check pairwise overlap.
    declared_ranges: list[tuple[str, int, int]] = []
    for label, start_sym, limit_sym, first_slot, last_slot in DRIVER_DECLARATIONS:
        allowed_start, _ = slot_range(symbols, first_slot)
        _, allowed_limit = slot_range(symbols, last_slot)
        start, limit = validate_within(
            errors,
            symbols,
            label,
            start_sym,
            limit_sym,
            allowed_start,
            allowed_limit,
            f"slot {first_slot}" if first_slot == last_slot else f"slots {first_slot}-{last_slot}",
        )
        if limit > cbios_code_limit:
            errors.append(
                validation_error(
                    f"{limit_sym} = {h4(limit)} crosses CBIOS_CODE_LIMIT = {h4(cbios_code_limit)}"
                )
            )
        declared_ranges.append((label, start, limit))

    for index, (left_label, left_start, left_limit) in enumerate(declared_ranges):
        for right_label, right_start, right_limit in declared_ranges[index + 1 :]:
            if ranges_overlap(left_start, left_limit, right_start, right_limit):
                errors.append(
                    validation_error(
                        f"{left_label} ({exclusive_span(left_start, left_limit)}) overlaps "
                        f"{right_label} ({exclusive_span(right_start, right_limit)})"
                    )
                )

    sio_core_start = require_symbol(symbols, "SIO_CORE_CODE_START")
    sio_core_end = require_symbol(symbols, "SIO_CORE_CODE_END")
    im2_entry = require_symbol(symbols, "CONSOLE_IM2_VECTOR_ENTRY")
    if im2_start < sio_core_start or im2_limit > sio_core_end:
        errors.append(
            validation_error(
                f"IM2 table {exclusive_span(im2_start, im2_limit)} is outside SIO core "
                f"({exclusive_span(sio_core_start, sio_core_end)})"
            )
        )
    if im2_start < cbios_core_base or im2_limit > cbios_core_limit:
        errors.append(
            validation_error(
                f"IM2 table {exclusive_span(im2_start, im2_limit)} exceeds CBIOS core "
                f"({exclusive_span(cbios_core_base, cbios_core_limit)})"
            )
        )
    if im2_entry != im2_start:
        errors.append(
            validation_error(
                f"CONSOLE_IM2_VECTOR_ENTRY = {h4(im2_entry)} must match CBIOS_IM2_VECTOR_TABLE = {h4(im2_start)}"
            )
        )

    for label, start, limit, _ in scratch_buffer_ranges(symbols):
        if start < scratch_start or limit > scratch_limit:
            errors.append(
                validation_error(
                    f"{label} {exclusive_span(start, limit)} is outside scratch "
                    f"({exclusive_span(scratch_start, scratch_limit)})"
                )
            )
        if start < cbios_code_limit:
            errors.append(
                validation_error(
                    f"{label} starts at {h4(start)} before CBIOS_CODE_LIMIT = {h4(cbios_code_limit)}"
                )
            )

    for left_name, left_start, left_limit, _ in scratch_buffer_ranges(symbols):
        for right_name, right_start, right_limit, _ in scratch_buffer_ranges(symbols):
            if left_name >= right_name:
                continue
            if ranges_overlap(left_start, left_limit, right_start, right_limit):
                errors.append(
                    validation_error(
                        f"{left_name} ({exclusive_span(left_start, left_limit)}) overlaps "
                        f"{right_name} ({exclusive_span(right_start, right_limit)})"
                    )
                )

    for name in ("CBIOS_SCRATCH_FREE0", "CBIOS_SCRATCH_FREE1"):
        limit_name = f"{name}_LIMIT"
        if name in symbols and limit_name in symbols:
            free_start = symbols[name]
            free_limit = symbols[limit_name]
            for buffer_name, buffer_start, buffer_limit, _ in scratch_buffer_ranges(symbols):
                if ranges_overlap(free_start, free_limit, buffer_start, buffer_limit):
                    warnings.append(
                        f"WARNING: declared {name} ({exclusive_span(free_start, free_limit)}) overlaps "
                        f"{buffer_name} ({exclusive_span(buffer_start, buffer_limit)}); derived scratch gaps are authoritative."
                    )

    if ranges_overlap(runtime_start, runtime_limit, scratch_start, scratch_limit):
        errors.append(
            validation_error(
                f"runtime state ({exclusive_span(runtime_start, runtime_limit)}) overlaps scratch "
                f"({exclusive_span(scratch_start, scratch_limit)})"
            )
        )
    if ranges_overlap(runtime_start, runtime_limit, im2_start, im2_limit):
        errors.append(
            validation_error(
                f"runtime state ({exclusive_span(runtime_start, runtime_limit)}) overlaps IM2 "
                f"({exclusive_span(im2_start, im2_limit)})"
            )
        )
    if runtime_limit > stack_guard:
        errors.append(
            validation_error(
                f"runtime state limit {h4(runtime_limit)} exceeds CBIOS_STACK_GUARD = {h4(stack_guard)}"
            )
        )
    if stack_guard < runtime_limit:
        errors.append(
            validation_error(
                f"CBIOS_STACK_GUARD = {h4(stack_guard)} is below runtime state limit {h4(runtime_limit)}"
            )
        )

    protected_effective_start, protected_effective_end = protected_tpa_effective_range(symbols)
    protected_effective_limit = protected_effective_end + 1
    for label, start, limit in declared_ranges + [("CBIOS core", cbios_core_base, cbios_core_limit)]:
        if ranges_overlap(start, limit, protected_effective_start, protected_effective_limit):
            errors.append(
                validation_error(
                    f"{label} ({exclusive_span(start, limit)}) overlaps protected/common TPA "
                    f"({span(protected_effective_start, protected_effective_end)})"
                )
            )

    if errors:
        raise SystemExit("\n".join(errors))
    return warnings


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
        rows = ["| *(none — firmware only, no bank payloads)* | | | | | |"]
    return rows


def ramdisk_rows(values: dict[str, str]) -> list[str]:
    if "ramdisk.name" not in values:
        return []
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


def storage_rows(values: dict[str, str]) -> list[str]:
    if "ramdisk.name" in values:
        return [
            (
                f"| Drive A | embedded RAM disk image | `{values['ramdisk.name']}` | "
                f"{values['ramdisk.total_bytes']} | {int(values['ramdisk.total_bytes']) // 128} | 128 |"
            )
        ]
    backend = values.get("storage.backend", "vdrip_proxy")
    if backend != "vdrip_proxy":
        raise SystemExit(f"Unknown storage backend in layout manifest: {backend}")
    return [
        "| Drive A | VDrip proxy flat image | `Zephyr VDrip CP/M 8M` | 8,388,608 | 65,536 | 128 |"
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
        f"| Burnable image | `{args.final_image}` | {artifact_size(args.final_image)} bytes |",
        f"| Layout manifest | `{args.manifest}` | {artifact_size(args.manifest)} bytes |",
        "",
        "## Reset And CP/M Common Symbols",
        "",
        "| Symbol | Address | Notes |",
        "|---|---:|---|",
        symbol_row(symbols, ("reset_vector",), "ROM reset entry."),
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
            symbol_row(symbols, ("CONSOLE_CALLER_SP",), "Saved caller stack pointer while console backends run on their private stack."),
            symbol_row(symbols, ("CONSOLE_STATE_END",), "Console state end."),
            symbol_row(symbols, ("BANKING_STATE_START",), "Banking state start."),
            symbol_row(symbols, ("SAVED_BANK",), "Saved active bank for cross-bank moves."),
            symbol_row(symbols, ("DMA_BANK",), "Recorded DMA bank."),
            symbol_row(symbols, ("XMOVE_SRC_BANK",), "Source bank for pending cross-bank move."),
            symbol_row(symbols, ("XMOVE_DST_BANK",), "Destination bank for pending cross-bank move."),
            symbol_row(symbols, ("XMOVE_PENDING",), "Pending cross-bank move flag."),
            symbol_row(symbols, ("MOVE_SRC_PTR",), "Cross-bank move source pointer."),
            symbol_row(symbols, ("MOVE_DST_PTR",), "Cross-bank move destination pointer."),
            symbol_row(symbols, ("MOVE_REMAIN",), "Cross-bank move remaining byte count."),
            symbol_row(symbols, ("MOVE_CHUNK_LEN",), "Current cross-bank chunk length."),
            symbol_row(symbols, ("BANKING_STATE_END",), "Banking state end."),
            symbol_row(symbols, ("STORAGE_STATE_START",), "Storage state start."),
            symbol_row(symbols, ("vdrip_storage_selected_drive",), "Selected storage drive, or `FFh` for unsupported."),
            symbol_row(symbols, ("vdrip_storage_track",), "Selected CP/M track."),
            symbol_row(symbols, ("vdrip_storage_sector",), "Selected 0-based CP/M sector."),
            symbol_row(symbols, ("VDRIP_STORAGE_SAVED_BANK",), "Saved active bank for DMA copies."),
            symbol_row(symbols, ("vdrip_storage_seq",), "VDrip storage sequence byte."),
            symbol_row(symbols, ("vdrip_storage_active_seq",), "Sequence byte for the active storage transaction."),
            symbol_row(symbols, ("vdrip_storage_lba",), "Computed little-endian 16-bit LBA for the active request."),
            symbol_row(symbols, ("VDRIP_TRANSPORT_STATE_START",), "Shared Virtual Drip transport state start."),
            symbol_row(symbols, ("vdrip_rx_mode",), "Current raw/readiness/storage/PTY receive mode."),
            symbol_row(symbols, ("vdrip_idle_mode",), "Console backend idle receive mode."),
            symbol_row(symbols, ("vdrip_proxy_online",), "Packetized PROXY_READY online flag."),
            symbol_row(symbols, ("vdrip_raw_callback",), "Selected console raw-byte callback."),
            symbol_row(symbols, ("vdrip_rx_state",), "Shared frame parser state."),
            symbol_row(symbols, ("vdrip_declared_len",), "Current 16-bit declared frame length."),
            symbol_row(symbols, ("vdrip_payload_len",), "Current decoded payload length."),
            symbol_row(symbols, ("vdrip_rx_type",), "Current received packet type."),
            symbol_row(symbols, ("vdrip_payload_remaining",), "Payload bytes remaining."),
            symbol_row(symbols, ("vdrip_payload_index",), "Payload staging index."),
            symbol_row(symbols, ("vdrip_pending_type",), "Expected storage reply type."),
            symbol_row(symbols, ("vdrip_pending_seq",), "Expected storage reply sequence."),
            symbol_row(symbols, ("vdrip_reply_ready",), "Matching storage reply completion flag."),
            symbol_row(symbols, ("vdrip_reply_error",), "Storage reply/protocol error flag."),
            symbol_row(symbols, ("vdrip_reply_status",), "Decoded storage or protocol status."),
            symbol_row(symbols, ("VDRIP_TRANSPORT_STATE_END",), "Shared Virtual Drip transport state end."),
            symbol_row(symbols, ("storage_caller_sp",), "Saved caller stack pointer while storage backends run on the BIOS stack."),
            symbol_row(symbols, ("VDRIP_STORAGE_CSV",), "Zero-length fixed-disk check vector label."),
            symbol_row(symbols, ("VDRIP_STORAGE_ALV",), "VDrip storage allocation vector."),
            symbol_row(symbols, ("STORAGE_STATE_END",), "Storage state end."),
            symbol_row(symbols, ("SIO_CORE_STATE_START",), "BIOS-owned SIO core state start."),
            symbol_row(symbols, ("SIO0B_RX_SINK",), "Registered RX byte sink for SIO_CH_CONSOLE / SIO0/B."),
            symbol_row(symbols, ("SIO1_RX_SINK",), "Registered RX byte sink slot for SIO_CH_IOCTRL / SIO1/A."),
            symbol_row(symbols, ("SIO_CORE_IRQ_ENABLED", "CONSOLE_IRQ_ENABLED"), "BIOS-owned SIO IRQ mode flag; legacy alias retained."),
            symbol_row(symbols, ("SIO_CORE_IRQ_COUNT", "CONSOLE_IRQ_COUNT"), "BIOS-owned SIO ISR entry counter; legacy alias retained."),
            symbol_row(symbols, ("SIO0B_LAST_RR1",), "Last SIO0/B RR1 value sampled after RX data read."),
            symbol_row(symbols, ("SIO0B_LAST_RX_ERROR",), "Last masked SIO0/B RR1 receive-error bits."),
            symbol_row(symbols, ("SIO_CORE_STATE_END",), "BIOS-owned SIO core state end."),
            "",
        ]
    )
    args.symbol_map.write_text("\n".join(lines))


def write_memory_map(
    args: argparse.Namespace,
    symbols: dict[str, int],
    manifest: dict[str, str],
    validation_warnings: list[str],
) -> None:
    cbios_base = require_symbol(symbols, "CBIOS_BASE")
    bios_code_end = require_symbol(symbols, "BIOS_CODE_END")
    code_limit = require_symbol(symbols, "CBIOS_CODE_LIMIT")
    core_base = require_symbol(symbols, "CBIOS_CORE_BASE")
    core_end = require_symbol(symbols, "CBIOS_CORE_END")
    stack_guard = require_symbol(symbols, "CBIOS_STACK_GUARD")
    stack_top = require_symbol(symbols, "CBIOS_STACK_TOP")
    console_stack_top = require_symbol(symbols, "CBIOS_CONSOLE_STACK_TOP")
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
            "Protected/common TPA",
            f"Application-owned common TPA. The marker range is `{span(protected_tpa_start, protected_tpa_end)}`; the effective TPA portion stops before `CBASE`.",
        ),
        range_row(span(require_symbol(symbols, "CBASE"), require_symbol(symbols, "CCPSTACK")), "CP/M CCP", f"`CBASE` is `{h4(require_symbol(symbols, 'CBASE'))}`."),
        range_row(span(require_symbol(symbols, "FBASE"), cbios_base - 1), "CP/M BDOS and state", f"`FBASE` is `{h4(require_symbol(symbols, 'FBASE'))}` in the current assembled image."),
        range_row(span(core_base, core_end), "Core BIOS", "BIOS jump table, BOOT/WBOOT, page-zero setup, console facade, storage facade, banking, XMOVE, SIO core, VIDEO_SEND extension, and IOCALL transport."),
        range_row(span(require_symbol(symbols, "CBIOS_DRIVER_SLOT0_BASE"), require_symbol(symbols, "CBIOS_DRIVER_SLOT4_END")), "Driver slots 0-4", "Virtual Drip V9958 console driver (code, printable-run buffer, input queue, parser, and cursor state)."),
        range_row(span(require_symbol(symbols, "CBIOS_DRIVER_SLOT5_BASE"), require_symbol(symbols, "CBIOS_DRIVER_SLOT5_END")), "Driver slot 5", "VDrip storage backend."),
        range_row(span(require_symbol(symbols, "CBIOS_SCRATCH_BASE"), require_symbol(symbols, "CBIOS_SCRATCH_END")), "Protected BIOS scratch/storage buffers", f"`MOVE_BUFFER` is at `{h4(require_symbol(symbols, 'MOVE_BUFFER'))}`; `VDRIP_STORAGE_DPHDPB` is at `{h4(require_symbol(symbols, 'VDRIP_STORAGE_DPHDPB_BASE'))}`; `VDRIP_STORAGE_DIRBUF` is at `{h4(require_symbol(symbols, 'VDRIP_STORAGE_DIRBUF'))}`; `VDRIP_STORAGE_ALV` is at `{h4(require_symbol(symbols, 'VDRIP_STORAGE_ALV'))}`."),
        range_row(span(runtime_start, runtime_end), "BIOS runtime state", "Current bank, DMA address, banking state, storage state, SIO core state, and console driver state."),
        range_row(span(stack_guard, area_end), "Protected firmware stack and work window", f"Stack top is `{h4(stack_top)}`; console backend stack top is `{h4(console_stack_top)}`; stack guard is `{h4(stack_guard)}`."),
        "",
        "## Core BIOS Layout",
        "",
        "| Range | Component |",
        "|---|---|",
        f"| `{span(require_symbol(symbols, 'reset_vector'), require_symbol(symbols, 'reset_vector') + 2)}` | Reset vector: `JP cpm_rom_entry_high`. |",
        f"| `{span(require_symbol(symbols, 'CBASE'), require_symbol(symbols, 'CCPSTACK'))}` | CP/M CCP area through `CCPSTACK`. |",
        f"| `{span(require_symbol(symbols, 'FBASE'), cbios_base - 1)}` | CP/M BDOS, BDOS work variables, and CP/M tables. |",
        f"| `{span(require_symbol(symbols, 'CBIOS_JUMP_TABLE'), require_symbol(symbols, 'ZBIOS_EXT_BASE') + 0x14)}` | Standard BIOS jump table plus `ZBIOS_EXT_BASE`. |",
        f"| `{span(require_symbol(symbols, 'cpm_rom_entry_high'), require_symbol(symbols, 'BANK_HELPERS_START') - 1)}` | ROM-to-RAM shadow-copy boot code. |",
        f"| `{span(require_symbol(symbols, 'BANK_HELPERS_START'), require_symbol(symbols, 'BANK_HELPERS_END') - 1)}` | Low-level bank selection helpers. |",
        f"| `{span(require_symbol(symbols, 'boot'), require_symbol(symbols, 'CONSOLE_CODE_START') - 1)}` | Cold boot, warm boot, CCP restore, page-zero, DMA, CTC helpers, and alignment gap. |",
        f"| `{span(require_symbol(symbols, 'CONSOLE_CODE_START'), require_symbol(symbols, 'CONSOLE_CODE_END') - 1)}` | Console BIOS facade. |",
        f"| `{span(require_symbol(symbols, 'STORAGE_STUB_CODE_START'), require_symbol(symbols, 'STORAGE_STUB_CODE_END') - 1)}` | Storage BIOS facade. |",
        f"| `{span(require_symbol(symbols, 'BANKING_CODE_START'), require_symbol(symbols, 'BANKING_CODE_END') - 1)}` | Banking and XMOVE implementation. |",
        f"| `{span(require_symbol(symbols, 'SIO_CORE_CODE_START'), require_symbol(symbols, 'SIO_CORE_CODE_END') - 1)}` | SIO core and exact IM2 vector entry. |",
        f"| `{span(require_symbol(symbols, 'BIOS_EXT_CODE_START'), require_symbol(symbols, 'BIOS_EXT_CODE_END') - 1)}` | BIOS extension: `VIDEO_SEND`. |",
        f"| `{span(require_symbol(symbols, 'IOCTRL_CODE_START'), require_symbol(symbols, 'IOCTRL_CODE_END') - 1)}` | IOCALL IO Controller transport. |",
        "",
        "## Driver Slot Table",
        "",
        "| Slot | Start | End | Size | Owner | Current contents |",
        "|---:|---:|---:|---:|---|---|",
    ]
    for slot in range(6):
        slot_start, slot_limit = slot_range(symbols, slot)
        owner = DRIVER_SLOT_OWNERS[slot]
        if slot == 5:
            contents = (
                f"`{span(require_symbol(symbols, 'VDRIP_TRANSPORT_CODE_START'), require_symbol(symbols, 'VDRIP_TRANSPORT_CODE_END') - 1)}` shared transport; "
                f"`{span(require_symbol(symbols, 'VDRIP_STORAGE_CODE_START'), require_symbol(symbols, 'VDRIP_STORAGE_CODE_END') - 1)}` storage backend."
            )
        elif slot == 0:
            contents = f"`{span(require_symbol(symbols, 'VDRIP_CONSOLE_CODE_START'), require_symbol(symbols, 'VDRIP_CONSOLE_CODE_END') - 1)}` VDrip V9958 code, run/input queues, parser, and sprite-cursor state."
        else:
            contents = "Part of Virtual Drip console driver above."
        lines.append(
            f"| {slot} | `{h4(slot_start)}` | `{h4(slot_limit - 1)}` | "
            f"{slot_limit - slot_start} bytes | {owner} | {contents} |"
        )

    lines.extend(
        [
            "",
            "## Core SIO Layout",
            "",
            "| Range | Owner | Notes |",
            "|---|---|---|",
            f"| `{span(require_symbol(symbols, 'SIO_CORE_CODE_START'), require_symbol(symbols, 'SIO_CORE_CODE_END') - 1)}` | SIO core | BIOS-owned SIO0/B async setup with CTS-polled TX and software-managed RTS helpers, legacy SIO1/A sync setup, SIO IRQ control, RX sink registration, byte I/O APIs, IO Controller RTS helpers, RX diagnostics, RX kick, ISR, and compatibility labels. |",
            f"| `{span(require_symbol(symbols, 'CONSOLE_IM2_VECTOR_TABLE_START'), require_symbol(symbols, 'CONSOLE_IM2_VECTOR_TABLE_END') - 1)}` | SIO core | Exact two-byte IM2 vector table entry. |",
            "",
            "SIO_CH_CONSOLE is the BIOS-owned SIO0/B async console link used by the Virtual Drip console driver. RTS/CTS are connected, /DCD is tied active-low, and WR3 Auto Enables are enabled. The VDrip console driver also manages RTS through high/low watermarks for host-to-Zephyr backpressure and display-traffic gating.",
            "",
            "## VDrip Console Layout",
            "",
            "| Range | Owner | Notes |",
            "|---|---|---|",
            f"| `{span(require_symbol(symbols, 'VDRIP_CONSOLE_CODE_START'), require_symbol(symbols, 'VDRIP_CONSOLE_CODE_END') - 1)}` | Virtual Drip V9958 console driver | CP/M console semantics, G6 command streams, CP850 atlas upload, input queue, printable-run buffer, and sprite-cursor state. |",
            f"| `{span(require_symbol(symbols, 'VDRIP_TRANSPORT_CODE_START'), require_symbol(symbols, 'VDRIP_TRANSPORT_CODE_END') - 1)}` | Shared Virtual Drip transport | Current no-CRC frame sender, packetized readiness, single RX sink, parser, PTY dispatch, and storage reply dispatch. |",
            "",
            "SIO_CH_IOCTRL is the legacy BIOS-owned SIO1/A synchronous helper path. Phase 1 IOCALL uses the SIO1/B Command-channel External Sync transport; SIO1/A remains inactive for Bulk in this phase.",
            f"`IOCALL` code is at `{span(require_symbol(symbols, 'IOCTRL_CODE_START'), require_symbol(symbols, 'IOCTRL_CODE_END') - 1)}` in core BIOS.",
            "",
        "## BIOS Jump Table Layout",
        "",
        "| Address | Entry |",
        "|---:|---|",
        ]
    )
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
            "## Scratch Layout",
            "",
            "| Range | Use | Notes |",
            "|---|---|---|",
        ]
    )
    for name, start, limit, notes in scratch_buffer_ranges(symbols):
        lines.append(f"| `{exclusive_span(start, limit)}` | `{name}` | {notes} |")
    for start, limit in derived_free_scratch_ranges(symbols):
        lines.append(f"| `{exclusive_span(start, limit)}` | unused scratch window | Derived from active buffers and scratch bounds. |")

    im2_table = require_symbol(symbols, "CBIOS_IM2_VECTOR_TABLE")
    im2_limit = require_symbol(symbols, "CBIOS_IM2_VECTOR_LIMIT")
    im2_entry = require_symbol(symbols, "CBIOS_IM2_VECTOR_ENTRY")
    lines.extend(
        [
            "",
            "## IM2 Layout",
            "",
            "| Field | Value | Notes |",
            "|---|---:|---|",
            f"| Table base | `{h4(im2_table)}` | Start of the exact IM2 vector table entry. |",
            f"| Table range | `{exclusive_span(im2_table, im2_limit)}` | Exactly {im2_limit - im2_table} bytes; `CONSOLE_IM2_VECTOR_TABLE_END` is the exclusive end label. |",
            f"| Vector page | `{h2(require_symbol(symbols, 'CBIOS_IM2_VECTOR_PAGE'))}` | Loaded into the Z80 I register. |",
            f"| SIO0/B WR2 vector byte | `{h2(require_symbol(symbols, 'CBIOS_SIO_VECTOR'))}` | Selects the exact two-byte table entry. |",
            f"| Entry address | `{h4(im2_entry)}` | Contains the little-endian word `sio_core_isr`. |",
            f"| Owner | SIO core | The IM2 entry lives inside core BIOS with the SIO core. |",
            "",
            "Future devices that need additional IM2 vectors should allocate explicit table entries and program their vector bytes directly; this build no longer emits a 256-byte repeated table.",
        ]
    )

    lines.extend(
        [
            "",
            "## Image Payload Layout",
            "",
            "| Payload | Bank | Entry | Size | End | Source |",
            "|---|---:|---:|---:|---:|---|",
            *payload_rows(manifest),
            "",
            "## VDrip Storage Layout",
            "",
            "| Drive | Backend | Format | Bytes | Records | Record Bytes |",
            "|---|---|---|---:|---:|---:|",
            *storage_rows(manifest),
            "",
            "## Image Artifacts",
            "",
            "| Artifact | Size | Notes |",
            "|---|---:|---|",
            f"| `{args.firmware_bin}` | {artifact_size(args.firmware_bin)} bytes | Firmware image before payload attachment. |",
            f"| `{args.final_image}` | {artifact_size(args.final_image)} bytes | Burnable image after payload attachment. |",
            "",
            "## Validation Report",
            "",
            "Status: PASS. No fatal layout errors were found.",
            "",
        ]
    )
    if validation_warnings:
        lines.extend(["Warnings:", ""])
        lines.extend(f"- {warning}" for warning in validation_warnings)
        lines.append("")
    lines.extend(
        [
            "Validated expectations:",
            "",
            *(f"- {note}" for note in VALIDATION_NOTES),
            "",
            "Additional notes:",
            "",
            "- CP/M drive A is backed by VDrip proxy storage using a flat 8 MiB image; no RAM disk seed is embedded in ROM banks.",
            "- Storage READ/WRITE use framed Virtual Drip transactions and preserve the standard CP/M BIOS disk call model.",
            f"- The protected TPA marker is `{span(protected_tpa_start, protected_tpa_end)}`; for this build, the application-usable protected TPA subrange is `{span(protected_tpa_effective_start, protected_tpa_effective_end)}` because `CBASE` starts at `{h4(require_symbol(symbols, 'CBASE'))}`.",
            f"- WBOOT restores the CCP range `{span(require_symbol(symbols, 'CBASE'), require_symbol(symbols, 'FBASE') - 1)}` from ROM page 0 using `ROM_VISIBLE_BANK0` (`{h2(require_symbol(symbols, 'ROM_VISIBLE_BANK0'))}`) before returning to `CCP_CLEARBUF_ENTRY`.",
            f"- `CBIOS_BASE` is `{h4(cbios_base)}`; CBIOS layout constants are derived from this base.",
            f"- `CBIOS_CODE_LIMIT` is `{h4(code_limit)}`; no resident code may cross into scratch/staging.",
            f"- SIO core code starts at `{h4(require_symbol(symbols, 'SIO_CORE_CODE_START'))}` inside core BIOS; the Virtual Drip console driver starts at `{h4(require_symbol(symbols, 'VDRIP_CONSOLE_CODE_START'))}`, the shared transport starts at `{h4(require_symbol(symbols, 'VDRIP_TRANSPORT_CODE_START'))}`, and the VDrip storage backend starts at `{h4(require_symbol(symbols, 'VDRIP_STORAGE_CODE_START'))}`.",
            f"- `IOCALL` code is at `{h4(require_symbol(symbols, 'IOCTRL_CODE_START'))}` in core BIOS and uses the SIO1/B Command-channel External Sync transport.",
            f"- `VIDEO_SEND` code is at `{h4(require_symbol(symbols, 'BIOS_EXT_CODE_START'))}` in core BIOS; raw VDP/display writes may desynchronize the V9958 logical-cell state.",
            f"- `WBOOT` resident code starts at `{h4(require_symbol(symbols, 'WBOOT_RESIDENT_START'))}`, inside protected high BIOS memory.",
            f"- `ZBIOS_EXT_BASE` is at `{h4(ext_base)}` and exposes `MOVE`, `XMOVE`, `SELMEM`, `SETBNK`, `IOCALL`, `VIDEO_SEND`, and `IOCBULK`.",
            f"- The burnable image is `{args.final_image}`.",
            "",
        ]
    )
    args.memory_map.write_text("\n".join(lines))


def main() -> int:
    args = parse_args()
    require_file(args.map)
    symbols = parse_listing(args.listing)
    manifest = parse_manifest(args.manifest)
    validation_warnings = validate_layout(symbols)

    args.symbol_map.parent.mkdir(parents=True, exist_ok=True)
    args.memory_map.parent.mkdir(parents=True, exist_ok=True)
    write_symbol_map(args, symbols, manifest)
    write_memory_map(args, symbols, manifest, validation_warnings)
    for warning in validation_warnings:
        print(warning, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
