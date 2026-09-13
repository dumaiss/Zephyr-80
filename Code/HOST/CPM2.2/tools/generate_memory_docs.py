#!/usr/bin/env python3
"""Generate and validate the Zephyr-80 banked-OS memory map and symbol map.

The OS runs from SRAM bank 7, mapped at 2000h-DFFFh only in latch mode 11, and
keeps what both modes must see in common memory, E000h-FFFFh.  One link builds
both halves, so addresses alone decide which is which.  This reads that link --
the assembler listing for symbol addresses and emitted bytes, cbios_defs.inc for
constants the listing does not show -- and:

  - checks every declared region against the limit cbios_defs.inc gives it
  - checks the layout invariants the design depends on (docs/
    Zephyr-80_OS_Execution_Memory_Architecture.md, section 28)
  - writes docs/memory-map.md and docs/symbol-map.md

A failed check stops the build with every error found, not just the first.
tools/check_overlap.py already catches bytes emitted twice; this checks what the
bytes are allowed to be.
"""

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
EMIT_PATTERN = re.compile(r"^\s+0000([0-9A-Fa-f]{4}) ((?:[0-9A-Fa-f]{2} )+)")
# A line with more bytes than fit wraps onto lines with no address, indented to
# the byte column.
EMIT_CONTINUATION = re.compile(r"^ {13}((?:[0-9A-Fa-f]{2} ?)+)\s*$")
DEFS_PATTERN = re.compile(
    r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(0x[0-9A-Fa-f]+|[0-9]+)\s*(?:;|$)", re.MULTILINE
)

OS_BODY_START = 0x2000
OS_IMAGE_LIMIT = 0xC000        # shadow/copy mode loads only 0000h-BFFFh of a page
OS_BODY_LIMIT = 0xE000
COMMON_START = 0xE000
CCP_SLOT = 0x0800
BIOS_TABLE_ENTRIES = 17
EXT_TABLE_ENTRIES = 8
EXT_FIRST_FUNCTION = 210
IM2_PAGE_SIZE = 0x100

BIOS_ENTRY_NAMES = [
    "BOOT", "WBOOT", "CONST", "CONIN", "CONOUT", "LIST", "PUNCH", "READER",
    "HOME", "SELDSK", "SETTRK", "SETSEC", "SETDMA", "READ", "WRITE", "LISTST",
    "SECTRAN",
]
EXT_ENTRY_NAMES = [
    "MOVE", "XMOVE", "SELMEM", "SETBNK", "IOCALL", "VIDEO_SEND", "IOCBULK", "IOCBULKW",
]


class Region:
    """A declared region: code from start_sym to end_sym, bounded by limit_sym.

    end_sym None means the region has no end label; its end is the last emitted
    byte below the limit.
    """

    def __init__(self, name: str, start_sym: str, end_sym: str | None, limit_sym: str,
                 notes: str, optional: bool = False):
        self.name = name
        self.start_sym = start_sym
        self.end_sym = end_sym
        self.limit_sym = limit_sym
        self.notes = notes
        self.optional = optional


COMMON_REGIONS = [
    Region("BDOS facade", "FACADE_CODE_START", "FACADE_CODE_END", "FACADE_CODE_LIMIT",
           "`CALL 5`: serial number, `FBASE`, argument staging, Zephyr functions 200-217, system information block."),
    Region("BIOS tables, ROM copy, boot", "BIOS_CODE_START", None, "CBIOS_BANKING_CODE_BASE",
           "CP/M BIOS table, Zephyr extension table, reset copy, cold boot, warm boot, CCP restore, page zero."),
    Region("Banking services", "BANKING_CODE_START", "BANKING_CODE_END", "CBIOS_SPARE_CODE_BASE",
           "`SELMEM`, `SETBNK`, `XMOVE`, `MOVE`."),
    Region("CTC reset", "CBIOS_SPARE_CODE_BASE", None, "CBIOS_IOC_DIAG_BASE",
           "`ctc_disable_interrupts`: CTC reset and vector base."),
    Region("IOC link failure record", "CBIOS_IOC_DIAG_BASE", "IOC_DIAG_RECORD_END", "CBIOS_BOOT_BANNER_CODE_BASE",
           "Read by the CP/M tools through BDOS function 203."),
    Region("Boot banner printer", "BOOT_BANNER_CODE_START", "BOOT_BANNER_CODE_END", "CBIOS_SIO_CORE_CODE_BASE",
           "Prints the banner text kept in bank 7."),
    Region("SIO core", "SIO_CORE_CODE_START", "SIO_CORE_CODE_END", "CBIOS_XING_CODE_BASE",
           "SIO0/B and SIO1 initialization, receive sinks, SIO interrupt body."),
    Region("Crossing layer", "XING_CODE_START", "XING_CODE_END", "CBIOS_XING_CODE_LIMIT",
           "`xing_isr`, the SIO IM2 entry, and mode-preserving bank select."),
    Region("Transport level", "ZBIOS_XPORT_LEVEL_ADDR", None, "CBIOS_GATE_CODE_BASE",
           "The BIOS IO Controller transport level byte."),
    Region("Crossing gates", "GATE_CODE_START", "GATE_CODE_END", "CBIOS_GATE_CODE_LIMIT",
           "Console and IOC/video gates into bank 7, inert disk entries, warm-boot trap, ROM-disk copy window, bank 7 check."),
    Region("Interrupt dispatch", "IRQ_CODE_START", "IRQ_CODE_END", "CBIOS_IRQ_CODE_LIMIT",
           "CTC entries, callback dispatcher, registration."),
    Region("Serial console", "SERCON_CODE_START", "SERCON_CODE_END", "CBIOS_SERCON_CODE_LIMIT",
           "Serial console tee and input switch.", optional=True),
]

BANK7_REGIONS = [
    Region("ZSDOS's BIOS table", "BIOS7_TABLE", "BIOS7_TABLE_END", "CBIOS_CONSOLE_CODE_BASE",
           "The table ZSDOS calls, and the `BANK7OS1` image marker."),
    Region("Console facade", "CONSOLE_CODE_START", "CONSOLE_CODE_END", "CBIOS_STORAGE_CODE_BASE",
           "CP/M console entries; dispatch on the console stack."),
    Region("Storage facade", "STORAGE_STUB_CODE_START", "STORAGE_STUB_CODE_END", "CBIOS_BIOS_EXT_CODE_BASE",
           "CP/M disk entries; jumps into the drive dispatcher."),
    Region("VIDEO_SEND", "BIOS_EXT_CODE_START", "BIOS_EXT_CODE_END", "CBIOS_IOCTRL_CODE_BASE",
           "Raw video request through the selected console backend."),
    Region("IOCALL", "IOCTRL_CODE_START", "IOCTRL_CODE_END", "CBIOS_IOC_COMMAND_CODE_BASE",
           "32-byte mailbox transaction."),
    Region("IOC command lane", "IOC_CMD_CODE_START", "IOC_CMD_CODE_END", "CBIOS_XPORT_SHIM_CODE_BASE",
           "Common-packet command-lane transport."),
    Region("Bulk entries", "XPORT_SHIM_CODE_START", "XPORT_SHIM_CODE_END", "CBIOS_IOC_BULK_CODE_BASE",
           "`IOCBULK` and `IOCBULKW`."),
    Region("IOC bulk lane", "IOC_BULK_CODE_START", "IOC_BULK_CODE_END", "CBIOS_HID_INPUT_CODE_BASE",
           "Common-packet bulk-lane transport and link bring-up."),
    Region("USB keyboard input", "HID_INPUT_CODE_START", "HID_INPUT_CODE_END", "CBIOS_HID_INPUT_STATE_BASE",
           "Doorbell-gated keyboard fetch."),
    Region("USB keyboard state", "HID_INPUT_STATE_START", "HID_INPUT_STATE_END", "CBIOS_STORAGE_SD_CODE_BASE",
           "Mailboxes and keyboard queue."),
    Region("SD-card backend", "SD_STORAGE_CODE_START", "SD_STORAGE_CODE_END", "CBIOS_STORAGE_SD_CODE_LIMIT",
           "Record read and write through the IO Controller cache."),
    Region("B: select probe", "SD_PROBE_CODE_START", "SD_PROBE_CODE_END", "CBIOS_STORAGE_A_CODE_BASE",
           "Card availability, then the B: DPH."),
    Region("Drive A: backend", "STORAGE_A_CODE_START", "STORAGE_A_CODE_END", "CBIOS_SD_PROBE2_CODE_BASE",
           "The build-selected A: backend."),
    Region("Drive dispatcher", "CBIOS_SD_PROBE2_CODE_BASE", "SD_PROBE2_CODE_END", "CBIOS_V9958_CONSOLE_CODE_BASE",
           "Routes A: to its backend and B:/C: to SD units; C: select probe."),
]

CONSOLE_REGIONS = {
    "v9958": Region("V9958 console", "V9958_CONSOLE_CODE_START", "V9958_CONSOLE_CODE_END",
                    "VDRIP_STORAGE_DPHDPB_BASE",
                    "Direct LunchCrema V9958 console: parser, renderer, cursor and state."),
    "vdrip": Region("Virtual Drip console", "VDRIP_CONSOLE_CODE_START", "VDRIP_CONSOLE_CODE_END",
                    "VDRIP_STORAGE_DPHDPB_BASE",
                    "Retained Virtual Drip console."),
}

COMMON_IMPLEMENTATION = [
    (("reset_vector",), "ROM reset entry."),
    (("cpm_rom_entry_high", "shadow_copy_rom_to_ram"), "ROM-to-RAM copy of every page."),
    (("cbios_boot_after_rom_copy",), "Cold boot handoff after the copy."),
    (("boot",), "Cold boot: enters mode 11, checks bank 7, initializes, enters the CCP in mode 10."),
    (("wboot",), "Warm boot trampoline."),
    (("wboot_resident",), "Warm boot: resets the CTC, clears registrations, restores the CCP."),
    (("restore_ccp_from_rom",), "Copies `CBASE` through `FBASE-1` from ROM page 0."),
    (("prepare_runnable_bank",), "Page zero and default DMA."),
    (("init_page_zero",), "Installs `JP WBOOT` and `JP FBASE`."),
    (("ctc_disable_interrupts",), "Resets the CTC and programs its vector base."),
    (("boot_print_banner",), "Prints the boot banner."),
    (("SELMEM",), "Selects a program bank, keeping the RAM mode."),
    (("SETBNK",), "Records the next disk DMA bank."),
    (("XMOVE",), "Arms a cross-bank `MOVE`."),
    (("MOVE",), "Same-bank or cross-bank move through the staging buffer."),
    (("sio_core_init",), "Initializes SIO0/B and clears receive sinks."),
    (("sio1_ioc_init",), "Initializes SIO1 for the IO Controller link; cold boot only."),
    (("sio_core_enable_interrupts",), "Loads `I`, enters IM2, programs SIO0/B WR2."),
    (("sio_register_rx_sink",), "Registers a receive sink for a BIOS-owned SIO channel."),
    (("sio_send_byte",), "Blocking send on a BIOS-owned SIO channel."),
    (("sio_core_isr",), "SIO interrupt body, called on the ISR stack."),
    (("xing_isr",), "SIO IM2 entry: ISR stack, `sio_core_isr`, `EI`/`RETI`."),
    (("xing_select_ram_bank",), "Selects a RAM bank while keeping mode 10 or mode 11."),
    (("xing_os_call_ix",), "Calls a bank 7 routine in mode 11 and restores the latch."),
    (("gate_const",), "`CONST` gate for programs."),
    (("gate_conin",), "`CONIN` gate for programs."),
    (("gate_conout",), "`CONOUT` gate for programs."),
    (("gate_iocall",), "`IOCALL` gate; stages both mailboxes."),
    (("gate_iocbulk",), "`IOCBULK` gate; delivers from the staging buffer."),
    (("gate_iocbulkw",), "`IOCBULKW` gate; stages the payload first."),
    (("gate_video_send",), "`VIDEO_SEND` gate; stages frames, chunks data blocks."),
    (("bios_inert_seldsk",), "Inert `SELDSK`: returns `HL = 0`."),
    (("bios_inert_error",), "Inert `READ`/`WRITE`: returns an error."),
    (("wbtrap",), "Warm-boot trap: common stack, mode 10, `JP 0000h`."),
    (("xing_rom_copy_record",), "Drive A: shadow/copy window; keeps its state in common variables."),
    (("bank7_check",), "Verifies the `BANK7OS1` marker at cold boot."),
    (("ctc0_isr",), "CTC channel 0 entry."),
    (("irq_register",), "BDOS function 200."),
    (("irq_unregister",), "BDOS function 201."),
    (("irq_program_exit",), "BDOS function 202; ZCPR2 calls it when a transient returns."),
    (("irq_reset",), "Clears every registration; cold and warm boot."),
    (("irq_unexpected",), "`EI`/`RETI` stub for unprogrammed vectors."),
    (("irq_ctc_slots",), "Callback entry per CTC channel; zero is unregistered."),
    (("facade_entry",), "BDOS facade entry, reached from `FBASE`."),
    (("facade_reset",), "Resets the facade's DMA tracking."),
    (("zephyr_sysinfo",), "System information block returned by function 203."),
]

COMMON_OPTIONAL = [
    (("sercon_init",), "Arms the serial console fallback at cold boot."),
    (("sercon_install",), "Rebinds the serial console after warm boot."),
]

BANK7_IMPLEMENTATION = [
    (("BIOS7_TABLE",), "ZSDOS's BIOS jump table."),
    (("BIOS7_MAGIC",), "`BANK7OS1` image marker."),
    (("console_init",), "Installs the console driver table."),
    (("const",), "Console status."),
    (("conin",), "Console input."),
    (("conout",), "Console output."),
    (("seldsk",), "Storage `SELDSK` entry."),
    (("read",), "Storage `READ` entry."),
    (("write",), "Storage `WRITE` entry."),
    (("stg_seldsk",), "Drive dispatcher."),
    (("stg_a_seldsk",), "Drive A: select."),
    (("stg_a_read",), "Drive A: record read."),
    (("sd_storage_probe",), "B: select probe."),
    (("sd_storage_probe2",), "C: select probe."),
    (("VIDEO_SEND",), "Raw video request."),
    (("IOCALL",), "IO Controller command/reply."),
    (("IOCBULK",), "IO Controller bulk receive."),
    (("IOCBULKW",), "IO Controller bulk transmit."),
    (("ioc_link_bringup",), "Establishes command-lane sync at cold boot."),
    (("console_backend_cold_init",), "Selected console backend cold init."),
    (("STORAGE_A_DPH",), "Drive A: DPH."),
    (("SD_STORAGE_DPH",), "B: DPH."),
    (("SD_STORAGE_DPH2",), "C: DPH."),
    (("CBIOS_STORAGE_DIRBUF",), "Shared directory buffer."),
    (("CONSOLE_FONT_ROM_BASE",), "Console font."),
    (("BOOT_BANNER_TEXT",), "Boot banner text."),
]

BANK7_OPTIONAL = [
    (("v9958_console_driver",), "V9958 console driver table."),
    (("v9958_console_init",), "V9958 warm initialization."),
    (("vdrip_console_driver",), "Virtual Drip console driver table."),
    (("vdrip_console_init",), "Virtual Drip console initialization."),
]

RUNTIME_STATE = [
    (("CURRENT_BANK",), "Running or suspended program bank; not the bank executing below `E000h`."),
    (("cbios_dma_addr",), "BIOS DMA address."),
    (("CONSOLE_DRIVER",), "Active console driver table."),
    (("CONSOLE_CALLER_SP",), "Caller SP while the console backend runs on its stack."),
    (("SAVED_BANK",), "Saved bank for a cross-bank move."),
    (("DMA_BANK",), "Recorded DMA bank."),
    (("XMOVE_SRC_BANK",), "Pending move source bank."),
    (("XMOVE_DST_BANK",), "Pending move destination bank."),
    (("XMOVE_PENDING",), "Cross-bank move armed."),
    (("MOVE_SRC_PTR",), "Cross-bank move source pointer."),
    (("MOVE_DST_PTR",), "Cross-bank move destination pointer."),
    (("MOVE_REMAIN",), "Cross-bank move bytes left."),
    (("MOVE_CHUNK_LEN",), "Current cross-bank chunk."),
    (("SAVED_LATCH",), "Latch as found by a cross-bank move."),
    (("stg_drive",), "Drive the dispatcher routes to."),
    (("storage_caller_sp",), "Caller SP while a storage backend runs on its stack."),
    (("SIO0B_RX_SINK",), "SIO0/B receive sink."),
    (("SIO1_RX_SINK",), "SIO1 receive sink."),
    (("SIO_CORE_IRQ_ENABLED",), "SIO interrupt mode flag."),
    (("SERCON_FLAGS",), "Serial console flags; programs find it through function 203."),
    (("IOC_DIAG_STATUS",), "IOC link failure record; programs find it through function 203."),
]

VALIDATION_NOTES = [
    "Every declared region starts at its base symbol and ends at or below its limit.",
    "Declared regions do not overlap.",
    "Nothing is assembled into the caller window `0003h-1FFFh`, the ZSDOS slot, bank 7's runtime-only `C000h-DFFFh`, the program reservation, or the CCP slot.",
    "The bank 7 image ends below `C000h`, the end of what shadow/copy mode loads.",
    "`FBASE` is six bytes into the facade, which follows the 2 KiB CCP slot; the facade ends below `CBIOS_BASE`.",
    "ZSDOS's BIOS table is at `ZSDOS_ORG + ZSDOS_SIZE`, and ends with the `BANK7OS1` marker.",
    "The CP/M BIOS table and the Zephyr extension table are jumps, in order.",
    "The IM2 vector page is 256 bytes at `I * 100h`, and every entry points into common memory.",
    "Staging buffers stay inside the shared buffer, and the returned copies do not overlap each other or the IM2 page.",
    "Runtime state blocks stay inside `FE00h-FE7Fh` without overlapping.",
    "The interrupt, gate and facade stacks are ordered, disjoint and common; the BIOS private stacks and SD scratch lie in bank 7's `C000h-DFFFh`.",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--listing", required=True, type=Path)
    parser.add_argument("--map", required=True, type=Path)
    parser.add_argument("--defs", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--firmware-bin", required=True, type=Path)
    parser.add_argument("--bank7-bin", required=True, type=Path)
    parser.add_argument("--final-image", required=True, type=Path)
    parser.add_argument("--symbol-map", required=True, type=Path)
    parser.add_argument("--memory-map", required=True, type=Path)
    return parser.parse_args()


def require_file(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"Missing input artifact: {path}")


def parse_listing(path: Path) -> tuple[dict[str, int], dict[int, int]]:
    """Symbol addresses, and every byte the listing shows emitted."""
    require_file(path)
    symbols: dict[str, int] = {}
    emitted: dict[int, int] = {}
    next_address: int | None = None
    for line in path.read_text(errors="replace").splitlines():
        match = EMIT_PATTERN.match(line)
        if match:
            next_address = int(match.group(1), 16)
            for byte in match.group(2).split():
                emitted[next_address] = int(byte, 16)
                next_address += 1
        elif next_address is not None and (cont := EMIT_CONTINUATION.match(line)):
            for byte in cont.group(1).split():
                emitted[next_address] = int(byte, 16)
                next_address += 1
        elif line.strip() and not line.startswith("ASxxxx") and not line.startswith("Hexadecimal"):
            next_address = None
        match = LABEL_PATTERN.match(line) or EQU_PATTERN.match(line)
        if match:
            symbols.setdefault(match.group(2), int(match.group(1), 16))
    return symbols, emitted


def add_defs(symbols: dict[str, int], path: Path) -> None:
    """Numeric constants the listing does not show, from cbios_defs.inc."""
    require_file(path)
    for name, value in DEFS_PATTERN.findall(path.read_text(errors="replace")):
        symbols.setdefault(name, int(value, 0))


def parse_manifest(path: Path) -> dict[str, str]:
    require_file(path)
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def h4(value: int) -> str:
    return f"{value:04X}h"


def h2(value: int) -> str:
    return f"{value:02X}h"


def span(start: int, end: int) -> str:
    return h4(start) if start == end else f"{h4(start)}-{h4(end)}"


def xspan(start: int, limit: int) -> str:
    return span(start, limit - 1) if limit > start else f"{h4(start)} (empty)"


class Layout:
    def __init__(self, symbols: dict[str, int], emitted: dict[int, int], manifest: dict[str, str]):
        self.symbols = symbols
        self.emitted = emitted
        self.manifest = manifest
        self.errors: list[str] = []
        self.by_address: dict[int, list[str]] = {}
        for name, address in symbols.items():
            self.by_address.setdefault(address, []).append(name)

    def sym(self, name: str) -> int:
        try:
            return self.symbols[name]
        except KeyError as exc:
            raise SystemExit(f"Missing required symbol: {name}") from exc

    def has(self, name: str) -> bool:
        return name in self.symbols

    def error(self, message: str) -> None:
        self.errors.append(f"ERROR: {message}")

    def emitted_in(self, start: int, limit: int) -> list[int]:
        return sorted(a for a in self.emitted if start <= a < limit)

    def region_bounds(self, region: Region) -> tuple[int, int, int] | None:
        """start, exclusive end, limit; None for an absent optional region."""
        if region.optional and not self.has(region.start_sym):
            return None
        start = self.sym(region.start_sym)
        limit = self.sym(region.limit_sym)
        if region.end_sym is None:
            inside = self.emitted_in(start, limit)
            end = inside[-1] + 1 if inside else start
        else:
            end = self.sym(region.end_sym)
        return start, end, limit

    def target_name(self, address: int) -> str:
        names = self.by_address.get(address, [])
        preferred = [n for n in names if not re.search(r"(_START|_BASE|_LIMIT|_END|_ADDR|_TOP)$", n)]
        lower = [n for n in preferred if n[0].islower()]
        pick = (lower or preferred or names or [None])[0]
        return f"`{pick}`" if pick else "*(no symbol)*"

    def jump_target(self, address: int) -> int | None:
        opcode = self.emitted.get(address)
        low = self.emitted.get(address + 1)
        high = self.emitted.get(address + 2)
        if opcode != 0xC3 or low is None or high is None:
            return None
        return low | (high << 8)

    def word(self, address: int) -> int | None:
        low = self.emitted.get(address)
        high = self.emitted.get(address + 1)
        if low is None or high is None:
            return None
        return low | (high << 8)


def check_regions(layout: Layout, regions: list[Region], area: str) -> list[tuple[Region, int, int, int]]:
    placed: list[tuple[Region, int, int, int]] = []
    for region in regions:
        bounds = layout.region_bounds(region)
        if bounds is None:
            continue
        start, end, limit = bounds
        if end < start:
            layout.error(f"{area} {region.name}: end {h4(end)} is below start {h4(start)}")
        if end > limit:
            layout.error(
                f"{area} {region.name}: {region.end_sym or 'last byte'} = {h4(end)} exceeds "
                f"{region.limit_sym} = {h4(limit)} by {end - limit} bytes"
            )
        placed.append((region, start, end, limit))
    ordered = sorted(placed, key=lambda item: item[1])
    for (left, l_start, l_end, _), (right, r_start, _, _) in zip(ordered, ordered[1:]):
        if l_end > r_start:
            layout.error(
                f"{area} {left.name} ({xspan(l_start, l_end)}) overlaps {right.name} starting {h4(r_start)}"
            )
    return placed


def check_invariants(layout: Layout, console: Region) -> dict[str, int]:
    s = layout.sym
    facts: dict[str, int] = {}

    for label, start, limit in [
        ("the caller window", 0x0003, OS_BODY_START),
        ("the ZSDOS slot", s("ZSDOS_ORG"), s("ZSDOS_ORG") + s("ZSDOS_SIZE")),
        ("bank 7's runtime-only range", OS_IMAGE_LIMIT, OS_BODY_LIMIT),
        ("the program reservation", s("PROGRAM_ISR_AREA"), s("PROGRAM_ISR_AREA") + 0x400),
        ("the CCP slot", s("CBASE"), s("CBASE") + CCP_SLOT),
    ]:
        inside = layout.emitted_in(start, limit)
        if inside:
            layout.error(f"{len(inside)} bytes assembled into {label} ({xspan(start, limit)}), first at {h4(inside[0])}")

    body = layout.emitted_in(OS_BODY_START, OS_BODY_LIMIT)
    image_end = body[-1] + 1 if body else OS_BODY_START
    facts["bank7_image_end"] = image_end
    if image_end > OS_IMAGE_LIMIT:
        layout.error(f"bank 7 image ends at {h4(image_end - 1)}, past what shadow/copy mode loads")

    if s("PROGRAM_ISR_AREA") != COMMON_START:
        layout.error(f"PROGRAM_ISR_AREA = {h4(s('PROGRAM_ISR_AREA'))}, expected {h4(COMMON_START)}")
    if s("CBASE") + CCP_SLOT != s("CBIOS_FACADE_BASE"):
        layout.error("the BDOS facade does not follow the 2 KiB CCP slot")
    if s("FACADE_CODE_START") != s("CBIOS_FACADE_BASE"):
        layout.error("FACADE_CODE_START is not CBIOS_FACADE_BASE")
    if s("FBASE") != s("CBIOS_FACADE_BASE") + 6:
        layout.error(f"FBASE = {h4(s('FBASE'))} is not six bytes into the facade")
    if s("FACADE_CODE_LIMIT") != s("CBIOS_BASE"):
        layout.error("FACADE_CODE_LIMIT is not CBIOS_BASE")
    if s("BIOS7_BASE") != s("ZSDOS_ORG") + s("ZSDOS_SIZE"):
        layout.error("BIOS7_BASE is not ZSDOS_ORG + ZSDOS_SIZE; ZSDOS computes its BIOS as ZSDOS+1000h")

    magic = bytes(layout.emitted.get(s("BIOS7_MAGIC") + i, 0) for i in range(8))
    if magic != b"BANK7OS1":
        layout.error(f"BIOS7_MAGIC holds {magic!r}, expected b'BANK7OS1'")

    for table, count, label in [
        (s("BIOS_CODE_START"), BIOS_TABLE_ENTRIES, "CP/M BIOS table"),
        (s("BIOS7_TABLE"), BIOS_TABLE_ENTRIES, "ZSDOS's BIOS table"),
        (s("ZBIOS_EXT_BASE"), EXT_TABLE_ENTRIES, "Zephyr extension table"),
    ]:
        for index in range(count):
            if layout.jump_target(table + 3 * index) is None:
                layout.error(f"{label} entry {index} at {h4(table + 3 * index)} is not a JP")
    if s("ZBIOS_EXT_BASE") != s("CBIOS_BASE") + 3 * BIOS_TABLE_ENTRIES:
        layout.error("ZBIOS_EXT_BASE does not follow the 17-entry CP/M BIOS table")
    if s("BIOS_CODE_START") != s("CBIOS_BASE"):
        layout.error("BIOS_CODE_START is not CBIOS_BASE")

    im2_start = s("IM2_VECTOR_TABLE_START")
    im2_end = s("IM2_VECTOR_TABLE_END")
    if im2_end - im2_start != IM2_PAGE_SIZE:
        layout.error(f"IM2 vector page is {im2_end - im2_start} bytes, expected 256")
    if im2_start != s("CBIOS_IM2_VECTOR_PAGE") << 8 or im2_start != s("CBIOS_IM2_VECTOR_TABLE"):
        layout.error(f"IM2 vector page {h4(im2_start)} is not CBIOS_IM2_VECTOR_PAGE * 100h")
    for vector in range(0, IM2_PAGE_SIZE, 2):
        target = layout.word(im2_start + vector)
        if target is None or target < COMMON_START:
            shown = "nothing" if target is None else h4(target)
            layout.error(f"IM2 vector {h2(vector)} points at {shown}, not common memory")

    bulk = s("FAC_BULK_BUF")
    bulk_end = bulk + s("FAC_BULK_SIZE")
    users = [
        ("FAC_DMA_BUF", s("FAC_DMA_BUF"), 128),
        ("FAC_FCB_BUF", s("FAC_FCB_BUF"), s("FCB_BYTES")),
        ("GATE_TX_BUF", s("GATE_TX_BUF"), s("IOC_FRAME_SIZE")),
        ("GATE_RX_BUF", s("GATE_RX_BUF"), s("IOC_FRAME_SIZE")),
        ("MOVE_XBUF", s("MOVE_XBUF"), s("MOVE_BUFFER_SIZE")),
    ]
    for name, start, size in users:
        if start < bulk or start + size > bulk_end:
            layout.error(f"{name} ({xspan(start, start + size)}) is outside the staging buffer ({xspan(bulk, bulk_end)})")
    for (a, a_start, a_size), (b, b_start, b_size) in [(users[0], users[1]), (users[2], users[3])]:
        if a_start < b_start + b_size and b_start < a_start + a_size:
            layout.error(f"{a} and {b} are used by the same call and overlap")
    copies = sorted([
        ("FAC_SFCB_BUF", s("FAC_SFCB_BUF"), s("FCB_BYTES")),
        ("FAC_DPB_COPY", s("FAC_DPB_COPY"), s("DPB_COPY_BYTES")),
        ("FAC_REGBLK", s("FAC_REGBLK"), 7),
        ("FAC_ALV_COPY", s("FAC_ALV_COPY"), s("ALV_COPY_BYTES")),
    ], key=lambda item: item[1])
    cursor, previous = bulk_end, "the staging buffer"
    for name, start, size in copies:
        if start < cursor:
            layout.error(f"{name} at {h4(start)} overlaps {previous}")
        cursor, previous = start + size, name
    if cursor > im2_start:
        layout.error(f"{previous} ends at {h4(cursor - 1)}, inside the IM2 vector page")
    facts["staging_end"] = cursor

    state_base = s("CBIOS_RUNTIME_STATE_BASE")
    state_limit = s("CBIOS_RUNTIME_STATE_LIMIT")
    blocks = sorted(
        (s(f"{name}_START"), s(f"{name}_END"), name)
        for name in ("RUNTIME_WORK_AREA", "CONSOLE_STATE", "BANKING_STATE", "STORAGE_STATE", "SIO_CORE_STATE")
    )
    cursor = state_base
    for start, end, name in blocks:
        if start < cursor or end > state_limit:
            layout.error(f"{name} ({xspan(start, end)}) overlaps another block or leaves {xspan(state_base, state_limit)}")
        cursor = end
    if im2_end > state_base:
        layout.error("the IM2 vector page runs into runtime state")

    isr_save = s("CBIOS_ISR_SP_SAVE")
    tops = [state_limit, isr_save, s("CBIOS_ISR_STACK_TOP"), s("GATE_STACK_TOP"), s("FAC_STACK_TOP")]
    if isr_save < state_limit or tops != sorted(tops) or s("FAC_STACK_TOP") > 0x10000:
        layout.error("common stacks are not ordered state < ISR SP save < ISR stack < gate stack < facade stack <= FFFFh")

    private = [OS_IMAGE_LIMIT, s("CBIOS_STACK_TOP"), s("CBIOS_CONSOLE_STACK_TOP"), s("CBIOS_XPORT_STACK_TOP")]
    if private != sorted(private):
        layout.error("BIOS private stacks are not ordered upward from C000h")
    scratch = s("MOVE_BUFFER")
    if scratch < s("CBIOS_XPORT_STACK_TOP") or scratch + s("MOVE_BUFFER_SIZE") > OS_BODY_LIMIT:
        layout.error(f"MOVE_BUFFER ({xspan(scratch, scratch + s('MOVE_BUFFER_SIZE'))}) is not above the stacks in C000h-DFFFh")

    return facts


def region_rows(layout: Layout, placed: list[tuple[Region, int, int, int]]) -> list[str]:
    rows = []
    for region, start, end, limit in sorted(placed, key=lambda item: item[1]):
        rows.append(
            f"| `{xspan(start, limit)}` | {region.name} | {end - start} | {limit - end} | {region.notes} |"
        )
    return rows


def symbol_rows(layout: Layout, entries, optional: bool = False) -> list[str]:
    rows = []
    for names, notes in entries:
        if optional and names[0] not in layout.symbols:
            continue
        address = layout.sym(names[0])
        for alias in names[1:]:
            if layout.sym(alias) != address:
                raise SystemExit(f"Symbol aliases do not share an address: {', '.join(names)}")
        label = " / ".join(f"`{name}`" for name in names)
        rows.append(f"| {label} | `{h4(address)}` | {notes} |")
    return rows


def artifact_row(label: str, path: Path) -> str:
    require_file(path)
    return f"| {label} | `{path}` | {path.stat().st_size} bytes |"


def im2_rows(layout: Layout) -> list[str]:
    start = layout.sym("IM2_VECTOR_TABLE_START")
    runs: list[tuple[int, int, int]] = []
    for vector in range(0, IM2_PAGE_SIZE, 2):
        target = layout.word(start + vector) or 0
        if runs and runs[-1][2] == target and runs[-1][1] == vector - 2:
            runs[-1] = (runs[-1][0], vector, target)
        else:
            runs.append((vector, vector, target))
    rows = []
    for first, last, target in runs:
        vectors = h2(first) if first == last else f"{h2(first)}-{h2(last)}"
        rows.append(f"| {vectors} | `{h4(start + first)}` | `{h4(target)}` {layout.target_name(target)} |")
    return rows


def jump_table_rows(layout: Layout, base: int, names: list[str], functions: bool = False) -> list[str]:
    rows = []
    for index, name in enumerate(names):
        address = base + 3 * index
        target = layout.jump_target(address)
        shown = f"`{h4(target)}` {layout.target_name(target)}" if target is not None else "*(not a JP)*"
        prefix = f"| {EXT_FIRST_FUNCTION + index} " if functions else ""
        rows.append(f"{prefix}| `{name}` | `{h4(address)}` | {shown} |")
    return rows


def write_symbol_map(args: argparse.Namespace, layout: Layout) -> None:
    s = layout.sym
    lines = [
        "# Zephyr-80 CP/M 2.2 Symbol Map",
        "",
        "Generated by `tools/generate_memory_docs.py` from `build/firmware.lst`, `src/cbios_defs.inc` and `build/layout.manifest`. Do not edit by hand.",
        "",
        "Programs must not use these addresses. The program interface is `CALL 5` and the CP/M BIOS boot and console entries; this map is for BIOS maintenance and debugging.",
        "",
        "## Build Artifacts",
        "",
        "| Artifact | Path | Size |",
        "|---|---|---:|",
        artifact_row("ROM page 0: reset vector and common memory", args.firmware_bin),
        artifact_row("Bank 7 payload", args.bank7_bin),
        artifact_row("Burnable image", args.final_image),
        artifact_row("Assembler listing", args.listing),
        artifact_row("Linker symbol map", args.map),
        artifact_row("Layout manifest", args.manifest),
        "",
        "## System Addresses",
        "",
        "| Symbol | Address | Notes |",
        "|---|---:|---|",
        *symbol_rows(layout, [
            (("PROGRAM_ISR_AREA",), "Program reservation for interrupt callbacks, `E000h-E3FFh`."),
            (("CBASE", "CCP_ENTRY"), "CCP (ZCPR2), 2 KiB."),
            (("CCP_CLEARBUF_ENTRY",), "CCP entry used by cold and warm boot, `C` = drive."),
            (("FBASE",), "BDOS entry: the facade's jump."),
            (("CBIOS_BASE",), "CP/M BIOS jump table."),
            (("ZBIOS_EXT_BASE",), "Zephyr extension table, reached through BDOS functions 210-217."),
            (("ZSDOS_ORG",), "ZSDOS, bank 7."),
            (("ZSDOS_ENTRY",), "ZSDOS entry the facade calls in mode 11."),
            (("BIOS7_BASE",), "ZSDOS's BIOS table, bank 7."),
        ]),
        "",
        "## Banking Latch Constants",
        "",
        "| Symbol | Value | Notes |",
        "|---|---:|---|",
    ]
    for name, notes in [
        ("BANK_PORT", "Banking latch I/O port."),
        ("SHADOW_BIT", "D3: shadow/copy with ROM enabled, operating-system mode with ROM disabled."),
        ("ROMDIS_BIT", "D4: disables ROM."),
        ("ROM_VISIBLE_BANK0", "Boot mode, ROM page 0 over bank 0; the warm-boot CCP restore."),
        ("COPY_LATCH0", "Shadow/copy mode, page 0 into bank 0."),
        ("RAM_ONLY_BANK0", "Application mode, bank 0."),
        ("OS_EXEC_LATCH", "Operating-system mode, bank 0."),
        ("OS_BANK", "The operating system's SRAM bank."),
    ]:
        lines.append(f"| `{name}` | `{h2(s(name))}` | {notes} |")

    lines += ["", "## CP/M BIOS Jump Table (common)", "",
              "Only `BOOT`, `WBOOT`, `CONST`, `CONIN` and `CONOUT` are live; the rest are inert.", "",
              "| Entry | Address | Target |", "|---|---:|---|",
              *jump_table_rows(layout, s("CBIOS_BASE"), BIOS_ENTRY_NAMES)]
    lines += ["", "## Zephyr Extension Table (common)", "",
              "| BDOS function | Entry | Address | Target |", "|---:|---|---:|---|",
              *jump_table_rows(layout, s("ZBIOS_EXT_BASE"), EXT_ENTRY_NAMES, functions=True)]
    lines += ["", "## ZSDOS's BIOS Jump Table (bank 7)", "",
              "| Entry | Address | Target |", "|---|---:|---|",
              *jump_table_rows(layout, s("BIOS7_TABLE"), BIOS_ENTRY_NAMES)]
    lines += ["", "## IM2 Vector Page", "",
              f"`I` = `{h2(s('CBIOS_IM2_VECTOR_PAGE'))}`. The BIOS programs the CTC vector base `{h2(s('CTC_VECTOR_BASE'))}` and SIO0/B WR2 `{h2(s('CBIOS_SIO_VECTOR'))}`.", "",
              "| Vectors | Entry | Target |", "|---|---:|---|", *im2_rows(layout)]
    lines += ["", "## Common Implementation Symbols", "",
              "| Symbol | Address | Notes |", "|---|---:|---|",
              *symbol_rows(layout, COMMON_IMPLEMENTATION),
              *symbol_rows(layout, COMMON_OPTIONAL, optional=True)]
    lines += ["", "## Bank 7 Implementation Symbols", "",
              "Visible at these addresses only in operating-system mode.", "",
              "| Symbol | Address | Notes |", "|---|---:|---|",
              *symbol_rows(layout, BANK7_IMPLEMENTATION),
              *symbol_rows(layout, BANK7_OPTIONAL, optional=True)]
    lines += ["", "## Runtime State Symbols", "",
              "| Symbol | Address | Notes |", "|---|---:|---|",
              *symbol_rows(layout, RUNTIME_STATE), ""]
    args.symbol_map.write_text("\n".join(lines))


def write_memory_map(args: argparse.Namespace, layout: Layout, console: Region,
                     common: list, bank7: list, facts: dict[str, int]) -> None:
    s = layout.sym
    manifest = layout.manifest
    cbase, fbase = s("CBASE"), s("FBASE")
    im2 = s("IM2_VECTOR_TABLE_START")
    state_base, state_limit = s("CBIOS_RUNTIME_STATE_BASE"), s("CBIOS_RUNTIME_STATE_LIMIT")
    isr_save = s("CBIOS_ISR_SP_SAVE")
    bulk, bulk_size = s("FAC_BULK_BUF"), s("FAC_BULK_SIZE")
    last_common_code = max(end for _, _, end, _ in common)

    lines = [
        "# Zephyr-80 CP/M 2.2 Memory Map",
        "",
        "Generated by `tools/generate_memory_docs.py` from `build/firmware.lst`, `src/cbios_defs.inc`, `build/layout.manifest` and the image artifacts. Do not edit by hand; `make` regenerates it and fails if the layout breaks a rule below.",
        "",
        "The operating system runs from SRAM bank 7, visible at `2000h-DFFFh` only in latch mode 11. Common memory, `E000h-FFFFh`, is SRAM bank 0 in both modes. See `docs/Zephyr-80_OS_Execution_Memory_Architecture.md` for the design.",
        "",
        "## What a Program Sees (mode 10)",
        "",
        "| Range | Use |",
        "|---|---|",
        "| `0000h-00FFh` | Page zero, default FCBs and default DMA, in the program's bank |",
        f"| `0100h-{h4(COMMON_START - 1)}` | Banked transient program area |",
        f"| `{xspan(s('PROGRAM_ISR_AREA'), s('PROGRAM_ISR_AREA') + 0x400)}` | Program reservation: interrupt callbacks and their data |",
        f"| `{xspan(cbase, cbase + CCP_SLOT)}` | CCP (ZCPR2), restored on warm boot |",
        f"| `{xspan(s('CBIOS_FACADE_BASE'), fbase)}` | BDOS serial number |",
        f"| `{h4(fbase)}` | `FBASE`, the BDOS entry |",
        f"| `{h4(s('CBIOS_BASE'))}-FFFFh` | System common memory |",
        "",
        f"Page zero's `0006h` holds `{h4(fbase)}`: the transient program area is `0100h-{h4(fbase - 1)}`, {fbase - 0x100} bytes ({(fbase - 0x100) / 1024:.1f} KiB).",
        "",
        "## Common Memory",
        "",
        "Code regions, each bounded by the limit `cbios_defs.inc` declares for it. Used and free are bytes.",
        "",
        "| Region | Owner | Used | Free | Contents |",
        "|---|---|---:|---:|---|",
        *region_rows(layout, common),
        "",
        "Data and stacks:",
        "",
        "| Range | Use | Notes |",
        "|---|---|---|",
        f"| `{xspan(bulk, bulk + bulk_size)}` | Staging buffer | {bulk_size} bytes, shared by facade DMA/FCB/console/time staging, gate mailboxes and payloads, and cross-bank `MOVE` chunks. Users never overlap in time. |",
        f"| `{xspan(s('FAC_SFCB_BUF'), facts['staging_end'])}` | Facade copies | Search-first FCB, DPB copy (function 31), register block (functions 210-217), ALV copy (function 27). |",
        f"| `{xspan(facts['staging_end'], im2)}` | Unallocated | |",
        f"| `{xspan(im2, im2 + IM2_PAGE_SIZE)}` | IM2 vector page | `I` = `{h2(s('CBIOS_IM2_VECTOR_PAGE'))}`; every entry points into common memory. |",
        f"| `{xspan(state_base, state_limit)}` | BIOS runtime state | Bank, DMA, console, banking, storage, SIO and serial console state. |",
        f"| `{xspan(isr_save, isr_save + 2)}` | Interrupted SP | Saved by every interrupt entry. |",
        f"| `{xspan(isr_save + 2, s('CBIOS_ISR_STACK_TOP'))}` | ISR stack | SIO and CTC interrupts; registered callbacks run here. |",
        f"| `{xspan(s('CBIOS_ISR_STACK_TOP'), s('GATE_STACK_TOP'))}` | Gate stack | Program calls through the crossing gates. |",
        f"| `{xspan(s('GATE_STACK_TOP'), s('FAC_STACK_TOP'))}` | Facade stack | BDOS facade, warm-boot trap, final boot switch to mode 10. |",
        f"| `{xspan(s('FAC_STACK_TOP'), 0x10000)}` | Unallocated | |",
        "",
        f"System common code ends at `{h4(last_common_code - 1)}`.",
        "",
        "## SRAM Bank 7 (mode 11 only)",
        "",
        "| Region | Owner | Used | Free | Contents |",
        "|---|---|---:|---:|---|",
        f"| `{xspan(s('ZSDOS_ORG'), s('ZSDOS_ORG') + s('ZSDOS_SIZE'))}` | ZSDOS | — | — | Installed from `build/bdos-zsdos.bin` by `tools/split_banked_image.py`. |",
        *region_rows(layout, bank7),
        "",
        "Data:",
        "",
        "| Range | Use | Notes |",
        "|---|---|---|",
        f"| `{h4(s('STORAGE_A_DPH'))}` | Drive A: DPH and DPB | Build-selected A: backend. |",
        f"| `{h4(s('SD_STORAGE_DPH'))}` | B: DPH and DPB | SD unit 0. |",
        f"| `{h4(s('CBIOS_STORAGE_DIRBUF'))}` | Directory buffer | Shared by every drive. |",
        f"| `{h4(s('STORAGE_A_ALV'))}` | Drive A: allocation vector | |",
        f"| `{h4(s('SD_STORAGE_ALV_BUFFER'))}` | B: allocation vector | |",
        f"| `{h4(s('SD_STORAGE_ALV2_BUFFER'))}` | C: allocation vector | |",
        f"| `{h4(s('SD_STORAGE_DPH2'))}` | C: DPH and DPB | SD unit 1. |",
        f"| `{xspan(s('CONSOLE_FONT_ROM_BASE'), s('CONSOLE_FONT_ROM_BASE') + s('FONT_CP850_6X8_SIZE'))}` | Console font | CP850 6x8. |",
        f"| `{xspan(s('BOOT_BANNER_TEXT'), s('BOOT_BANNER_TEXT_END'))}` | Boot banner text | |",
        "",
        f"The bank 7 image ends at `{h4(facts['bank7_image_end'] - 1)}`; shadow/copy mode loads `0000h-{h4(OS_IMAGE_LIMIT - 1)}`, so `{xspan(facts['bank7_image_end'], OS_IMAGE_LIMIT)}` is free for image growth.",
        "",
        "Runtime only, never loaded from ROM:",
        "",
        "| Range | Use |",
        "|---|---|",
        f"| `{xspan(OS_IMAGE_LIMIT, s('CBIOS_STACK_TOP'))}` | Boot and warm-boot stack |",
        f"| `{xspan(s('CBIOS_STACK_TOP'), s('CBIOS_CONSOLE_STACK_TOP'))}` | Console and storage dispatch stack |",
        f"| `{xspan(s('CBIOS_CONSOLE_STACK_TOP'), s('CBIOS_XPORT_STACK_TOP'))}` | IO Controller transport stack |",
        f"| `{xspan(s('MOVE_BUFFER'), s('MOVE_BUFFER') + s('MOVE_BUFFER_SIZE'))}` | SD transaction scratch (`MOVE_BUFFER`) |",
        f"| `{xspan(s('MOVE_BUFFER') + s('MOVE_BUFFER_SIZE'), OS_BODY_LIMIT)}` | Unallocated |",
        "",
        "## Image",
        "",
        "| Bank / page | Payload | Size | Source |",
        "|---:|---|---:|---|",
        f"| 0 | Reset vector and common memory | {args.firmware_bin.stat().st_size} | `{args.firmware_bin}` |",
    ]
    payloads = sorted(
        {key.split(".")[1] for key in manifest if key.startswith("payload.") and key.count(".") >= 2},
        key=lambda pid: int(manifest[f"payload.{pid}.bank"]),
    )
    for pid in payloads:
        lines.append(
            f"| {manifest[f'payload.{pid}.bank']} | {manifest.get(f'payload.{pid}.name', pid)} | "
            f"{manifest[f'payload.{pid}.size']} | `{manifest[f'payload.{pid}.path']}` |"
        )
    lines += [
        "",
        f"The burnable image `{args.final_image}` is {args.final_image.stat().st_size} bytes. "
        f"Console backend: `{manifest.get('console.backend')}`. Drive A: backend: `{manifest.get('storage.backend')}`.",
        "",
        "## Validation Report",
        "",
        "Status: PASS.",
        "",
        "Checked:",
        "",
        *(f"- {note}" for note in VALIDATION_NOTES),
        "",
    ]
    args.memory_map.write_text("\n".join(lines))


def main() -> int:
    args = parse_args()
    for path in (args.map, args.firmware_bin, args.bank7_bin, args.final_image):
        require_file(path)
    symbols, emitted = parse_listing(args.listing)
    add_defs(symbols, args.defs)
    manifest = parse_manifest(args.manifest)
    layout = Layout(symbols, emitted, manifest)

    backend = manifest.get("console.backend")
    if backend not in CONSOLE_REGIONS:
        raise SystemExit(f"Unknown or missing console backend in layout manifest: {backend}")
    console = CONSOLE_REGIONS[backend]

    common = check_regions(layout, COMMON_REGIONS, "common")
    bank7 = check_regions(layout, BANK7_REGIONS + [console], "bank 7")
    facts = check_invariants(layout, console)
    if layout.errors:
        raise SystemExit("\n".join(layout.errors))

    args.symbol_map.parent.mkdir(parents=True, exist_ok=True)
    args.memory_map.parent.mkdir(parents=True, exist_ok=True)
    write_symbol_map(args, layout)
    write_memory_map(args, layout, console, common, bank7, facts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
