# CP/M BIOS Debug and Test Code Review

Status: **carried out.** This document is the classification the cleanup was
built from; `docs/bios-realignment-plan.md` records what was actually done,
package by package, with measurements and hardware results.

Read this for the reasoning — why a given item is Keep, Productionize or Remove.
Read the plan for the outcome. Where the two differ, the plan is what shipped:
several items turned out differently once measured, and those departures are
recorded there rather than edited into the classification below.

This review separates temporary bring-up instrumentation from the small amount
of observability and recovery that remains useful on a hobby computer. The goal
is a clean, understandable BIOS memory map, not a larger TPA. Any removal or
relocation described here is a later implementation task and must be followed by
the normal image build, overlap checks, map inspection, and generated memory
documentation update.

## Classification

| Class | Meaning |
|---|---|
| **Keep** | Required for normal operation, integrity, recovery, or compatibility. |
| **Productionize** | Retain a smaller, stable diagnostic surface; remove detailed bring-up traces. |
| **Diagnostic build** | Keep the source and build target, but do not link or install it in the normal image. |
| **Remove** | One-question instrumentation whose question has been answered. |
| **Historical documentation** | Keep the investigation record, but do not treat it as runtime design. |

“Production” here means the normal hobby-system build. It does not imply that
all diagnostics should disappear. A ROM-backed rescue drive, a hardware monitor,
and compact status reporting are valuable on a machine that may be modified and
debugged again years later.

## Executive recommendation

The eventual normal BIOS should retain:

- the BIOS jump table and all existing extended entry positions;
- `IOCALL`, `IOCBULK`, and `IOCBULKW` while the SD/HID design uses them;
- CRC, sequence, length, type, status, and transfer-ID validation;
- bounded timeouts and distinct transport/storage error codes;
- `LINK_SYNC` bring-up and explicit resynchronization;
- the SD media-selection probe and fallback to drive A;
- `ZBIOS_XPORT_LEVEL`, plus the controller firmware-level comparison performed
  by `PING.COM`;
- enough last-failure state to distinguish “no controller,” “bad link,” “no SD
  card,” and “SD card or bus failure.”

The normal BIOS should eventually lose:

- byte-by-byte command marker history;
- raw Bulk rejection windows and full decoded-header snapshots;
- counters that are never used for control or recovery;
- VDrip SIO0/B diagnostics when VDrip itself is removed;
- fixed-address diagnostic layouts used only by obsolete bring-up utilities.

The normal ROM disk should keep recovery and provisioning utilities, but soak,
benchmark, raw electrical, and destructive verification programs should move to
a separately built diagnostic disk or explicit diagnostic ROM profile.

## Resident BIOS inventory

### Keep

| Item | Source | Reason |
|---|---|---|
| SD selection probe and fallback | `src/cbios_storage.asm`, `src/cbios_storage_sd.asm` | This is normal failure handling. It prevents an absent or failed non-A drive from trapping CP/M in a retry loop. The current four fragments total 49 bytes; fragmentation should be fixed later, but the behavior stays. |
| Transport integrity checks | `src/cbios_ioc_command.asm`, `src/cbios_iocall.asm` | Marker, length, class, sequence, status, and CRC checks prevent corrupted storage data from being accepted. |
| Bounded waits and error exits | IOC and VDrip transports | A timeout is not debug code. Every hardware wait must remain bounded and return a useful status. |
| `ioc_link_bringup` / `LINK_SYNC` | `src/cbios_boot.asm`, `src/cbios_ioc_command.asm` | Required to establish and recover persistent External Sync. |
| Bulk DONE identity and status | IOC Bulk routines | Transfer ID and final status are required, especially for writes where receiving bytes does not prove that the card committed them. |
| `ZBIOS_XPORT_LEVEL` | `src/cbios_defs.inc` | This is the BIOS half of the compatibility contract. `PING.COM` compares it with its expected BIOS level and compares the controller’s reported `IOC_FW_LEVEL` with its expected firmware level. Current controller level 68 is printed as hexadecimal `44h`. |
| SD and SIO error distinctions used by control flow | storage and transport code | “No card,” “no response,” “CRC,” “bus,” and timeout conditions support recovery and meaningful reporting. Do not collapse them into a generic debug code. |
| Build-time checks | `tools/check_overlap.py`, `tools/check_reachable.py`, image verification and memory-doc generator | These cost no resident BIOS bytes and protect the memory map and difficult control-flow paths. |

### Productionize

| Item | Current form | Recommended normal-build form |
|---|---|---|
| Command-lane failure snapshot | `CBIOS_IOC_DIAG_BASE` at `DCC0h`: 36 bytes of data, followed by the 34-byte `ioc_diag_capture` routine | Retain only a compact last-error record: transport status, RR0/RR1, sync/ready flags, and perhaps the last accepted class/sequence. Remove the eight-byte marker history, index, and remaining scan budget after the link is stable. |
| Bulk rejection diagnostics | `IOC_BULK_DIAG_RESET`, `IOC_BULK_DIAG_HEADER`, and `IOC_BULK_DIAG_FINISH` occupy 69 bytes, plus stores in rejection paths | Retain last transfer ID, final status, and a compact reason code. Remove the raw scan bytes, copied five-byte header, expected header tuple, and detailed SIO snapshots from the normal build. |
| SIO interrupt accounting | `SIO_CORE_IRQ_COUNT` and update code | Remove if it is not read by a production health utility or recovery decision. A monotonically increasing ISR count answered a bring-up question but does not improve console operation. |
| Last SIO0/B RR1 and RX error | `SIO0B_LAST_RR1`, `SIO0B_LAST_RX_ERROR` | Keep while VDrip transport uses the error latch to abort a failed receive. Remove with the SIO0/B VDrip path, not before it. |
| Firmware health display | `PING.COM` currently prints extensive link information | Keep a concise default report: BIOS transport level, actual/expected controller firmware level, link state, controller power state, and last compact failure. Put detailed traces behind an optional argument or diagnostic build. |
| Boot banner/version metadata | `src/cbios_boot.asm` inline banner | Not debug code. Move the string and version metadata into an explicit read-only-data region when the BIOS is repacked; do not continue filling incidental instruction gaps. |

The directly identifiable IOC trace blocks account for about 139 bytes before
counting embedded capture stores and ISR-counter code. A compact last-failure
record should recover roughly 100–180 resident bytes. This is a planning range,
not a promise: exact savings must come from a build with the selected fields
removed.

### Remove with VDrip, not independently

The following are tightly coupled to the VDrip implementation rather than the
IOC transport:

- SIO0/B async receive setup and ISR dispatch;
- VDrip READY/parser history and reply routing;
- proxy keyboard flow-control state and SIO0/B RX diagnostics;
- VDrip packet sender and proxy display command transport;
- `VIDEO_SEND` implementation details, while preserving its jump-table entry
  as a compatibility adapter or defined stub.

Removing these before the direct V9958/HID replacement is complete would break
the current console. They belong to the V9958 transition, not the first
diagnostic cleanup pass.

### Keep as source, but do not confuse with resident debug code

`cbios_console_sio.asm`, the RAM-disk backend, and the alternative VDrip storage
backend are selectable or historical platform implementations. If they are not
linked, they consume no BIOS bytes. Decide their long-term support separately;
deleting them is not required to clean the resident memory map.

## CP/M utility inventory

The ROM-disk manifest is in `tools/build_rom_disk.py`. These `.COM` programs use
ROM-disk capacity, not BIOS driver slots. Some of them also require diagnostic
commands in the IOController, so removing a utility and removing its controller
handler should be coordinated.

### Recommended on the normal ROM rescue disk

| Utility | Disposition | Reason |
|---|---|---|
| `PING.COM` | **Keep / productionize** | Primary non-destructive version, transport, power, and controller-health check. |
| `RESET.COM` | **Keep** | Intentional recovery tool for resetting the host and controller together. Its disruptive behavior must remain explicit. |
| `SDREAD.COM` | **Keep for now** | Non-destructive, simple command-lane read used to distinguish controller/SD failure from CP/M filesystem failure. The BIOS media-selection probe currently uses the same controller command. |
| `HIDKEY.COM` | **Optional normal-ROM diagnostic** | Useful for separating IOC HID translation/queue behavior from BIOS `CONST`/`CONIN`. Once HID is very mature it may move to the diagnostic profile. |
| `PADSTAT.COM` | **Keep / productionize** | Passive normal-firmware USB/F310 enumeration, report-arm, report-count and latch state without the retired HID bring-up pages. |
| `SDFMT.COM` | **Keep as provisioning, with strong warning** | It is not a soak test: a fresh SD CP/M volume needs its directory initialized. It is destructive and should require explicit confirmation and name the SD backend, never a drive letter. |
| `MONITOR.COM` | **Keep** | Only recovery environment that remains useful when storage or higher-level software is unusable. |
| `PIP.COM`, `STAT.COM` | **Keep** | Required to provision and inspect the SD volume from the ROM disk. |
| `ZSID.COM`, `DUMP.COM` | **Keep if ROM space permits** | General Z80 diagnosis without adding BIOS instrumentation. |
| `NOWRAP.COM`, `WRAPON.COM` | **Keep if still required by the terminal setup** | User-facing console configuration, not hardware bring-up. |

### Diagnostic image/profile only

| Utility | Reason to remove from the normal ROM manifest |
|---|---|
| `BULK.COM` | Synthetic ramp throughput/transport test. Keep buildable for regression testing. |
| `SDBLK.COM` | Raw 512-byte Bulk path isolation; useful during transport diagnosis but redundant with the production record path in normal use. |
| `SDREC.COM` | Destructive cache verification that overwrites records 0–7, including the head of the CP/M directory. Test cards only. |
| `SDSOAK.COM` | Destructive addressing/interrupt stress test across multiple LBAs. Test cards only. |
| `SDWRITE.COM` | Overwrites block 0 and destroys the partition table. Test cards only. |
| `SDBENCH.COM` | Writes a fixed high LBA repeatedly and does not restore it. Benchmark build only. |
| `RTSPROBE.COM` | Writes SIO registers behind the BIOS and invalidates persistent sync. Electrical bring-up tool only. |
| Full `HIDSTAT.COM` pages | Retired from installed profiles. Pages 1–5 expose temporary TinyUSB/MAX3421E trace scaffolding; the historical source remains buildable. |

Existing copies under `images/A/0` may remain as development media inputs, but
the normal ROM manifest should be the authoritative rescue-disk policy.

## Historical documents

Keep the investigation and optimization documents. They record hardware facts,
failed hypotheses, timing constraints, and reasons for non-obvious code. Mark
them historical where appropriate rather than deleting them. Historical prose
does not consume BIOS space and helps prevent old failures from being
reintroduced.

## Recommended cleanup sequence

1. Freeze and document the compact production diagnostic record shared by the
   BIOS and `PING.COM`.
2. Remove command/Bulk raw trace fields and update diagnostic utilities that
   read `DCC0h` directly.
3. Split the ROM-disk manifest into normal and diagnostic profiles; do not
   delete the utility sources.
4. In the IOController, remove or gate the corresponding diagnostic-only
   commands before deleting their CP/M callers.
5. Complete the V9958/HID console transition, then remove the VDrip/SIO0/B
   diagnostics with the transport they observe.
6. Repack the surviving code into named contiguous regions. Consolidate the SD
   probe rather than deleting it.
7. Build the image, inspect the listing/map/manifest, run overlap and reachability
   checks, regenerate memory documentation through the existing generator, and
   perform cold boot, warm boot, ROM A:, SD B:, HID, and failure-fallback tests.

## Acceptance criteria for the eventual normal build

- No existing BIOS jump-table entry moves or changes calling convention.
- Drive A remains ROM-backed and always available.
- SD and HID support remain functional.
- A failed non-A drive selection returns to A instead of looping.
- CRC, status, transfer ID, bounded timeout, and link recovery remain intact.
- `PING.COM` reports both expected/actual controller firmware compatibility and
  the BIOS transport level without requiring fixed raw trace addresses.
- Destructive utilities are absent from the normal ROM profile or require an
  unmistakable confirmation.
- The generated memory map contains named regions with useful local headroom,
  not new fragments placed into incidental byte-sized gaps.
