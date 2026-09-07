# IOController Debug and Test Code Review

Status: **carried out.** This document is the classification the cleanup was
built from; `../../HOST/CPM2.2/docs/bios-realignment-plan.md` records what was
actually done, and `docs/XC8-PATCHES.md` records the TinyUSB patch audit this
review asked for.

Read this for the reasoning. Read the plan for the outcome. Two of this
document's own recommendations turned out to need correcting once measured, and
both are recorded in the plan rather than edited away here:

- "Remove the trace-only `usbh_xc8_*` variables" would have deleted seven
  symbols that are live state, not telemetry. They are now named `xc8_saved_*`.
- The `uprof_*` removal would have taken `uprof_now()` with it, which is the
  microsecond time source backing the Bulk lane's bounded wait, not a profiler.

This review classifies the live diagnostic surface in the IOController firmware.
The objective is a dependable normal hobby-system build with useful failure
reporting, plus a separate diagnostic build for electrical bring-up, soak tests,
profiling, and deep USB-stack traces.

The current capability level is `IOC_FW_LEVEL = 68` decimal, printed by the CP/M
tools as hexadecimal `44h`. The CP/M side also checks its expected BIOS transport
level. That version contract is production functionality and must survive the
cleanup.

## Classification

| Class | Meaning |
|---|---|
| **Keep** | Required for normal operation, data integrity, recovery, or compatibility. |
| **Productionize** | Retain a compact passive status interface; remove invasive or detailed bring-up data. |
| **Diagnostic build** | Keep the source behind an explicit build profile, absent from normal firmware. |
| **Remove** | Trace-only scaffolding whose original question has been answered. |
| **Functional XC8 patch** | A compiler/overlay workaround that changes correctness; retain even if its counters are removed. |

## Executive recommendation

The normal firmware should expose a small command set centered on:

- `PING`, including actual firmware level and a compact health snapshot;
- `RESET`;
- record-addressed SD read/write/flush;
- Bulk transfer DONE identity/status required by record writes;
- `LINK_SYNC` recovery;
- HID input dequeue;
- one passive HID/controller status page;
- the existing SD media probe until the BIOS and controller agree on a smaller
  explicit probe operation.

The normal firmware should not contain:

- the synthetic Bulk ramp generator;
- raw block Bulk read/write handlers used only by test programs;
- phase-profiler accumulation and the `PROFILE` benchmark command;
- active multi-rate MAX3421E revision/GPOUT/interrupt electrical probes;
- HIDSTATUS detail pages 1–5;
- the dozens of `usbh_xc8_*` trace variables and their write sites;
- raw Bulk-window exposure through `XFER_STATUS`;
- physical command-clock edge counters once link timing is stable.

The project tree itself should also stop presenting the unused root `main.c`
stub and the optional controller-latch counter as if they were normal runtime
behavior.

Some removals change the private diagnostic protocol. Coordinate them with the
CP/M utilities and bump the firmware capability level. Do not silently reuse an
old command number for different semantics.

## Command inventory

| Command | Current role | Disposition |
|---|---|---|
| `CMD_PING` | Echo test, firmware level, power/link snapshot, service counters, and physical clock-edge counts | **Keep / productionize.** Keep echo, `IOC_FW_LEVEL`, power pins, link-synced state, and preferably a compact request/abort or last-error summary. Remove the temporary RX/TX physical edge counts. |
| `CMD_RESET` | Resets host and controller | **Keep.** It is deliberate recovery, not a test stub. |
| `CMD_SD_READ` | Reads block 0 and returns 16 bytes | **Keep for now.** The CP/M drive-selection probe currently uses command `03h`. Later replace it with an explicitly named, non-destructive media probe if that allows the standalone 512-byte buffer and legacy response data to disappear. |
| `CMD_BULK_TEST` | Generates a known ramp for lane throughput/integrity testing | **Diagnostic build.** No normal storage or HID path depends on it. |
| `CMD_SD_READ_BULK` | Raw 512-byte card read | **Diagnostic build.** The CP/M filesystem uses record reads. |
| `CMD_SD_WRITE_BULK` | Raw 512-byte card write | **Diagnostic build.** Destructive test/benchmark path; the filesystem uses record writes. |
| `CMD_XFER_STATUS` | DONE identity/status plus de-shifted peek, raw capture slice, and sync snapshots | **Keep / productionize.** Keep transfer ID and final status. Remove raw-window, peek, and sync-decision fields from the normal build after transport stabilization. |
| `CMD_SD_READ_REC` | Production 128-byte CP/M record read through cache | **Keep.** |
| `CMD_SD_WRITE_REC` | Production 128-byte CP/M record write through cache | **Keep.** |
| `CMD_SD_FLUSH` | Commits dirty cache state | **Keep.** |
| `CMD_PROFILE` | Phase timing, Bulk subphase timing, counters, and SD trace transport | **Diagnostic build or remove.** Preserve any compact SD failure trace through a smaller passive status mechanism. |
| `CMD_LINK_SYNC` | Explicitly re-establishes both persistent-sync lanes | **Keep.** Idempotent recovery is production behavior. |
| `CMD_HID_STATUS` | Active electrical probes plus five pages of USB/TinyUSB internal state | **Productionize heavily.** Keep one passive page: controller state/revision, USB interrupt level, mounted-device/keyboard state, report count, queue depth/drop count, and perhaps last failure. Move active probes and pages 1–5 to the diagnostic build. |
| `CMD_HID_INPUT` | Nonblocking terminal-input queue | **Keep.** This is the production HID console-input API. |
| Unknown-command response | Rejects unsupported classes explicitly | **Keep.** |

## Transport and storage diagnostics

### Keep

| Item | Source | Reason |
|---|---|---|
| Common packet validation | `src/external_sync.c`, `src/bulk_channel.c` | Marker search, length/type/sequence/status validation, and CRC prevent silent corruption. |
| Bounded SPI and handshake waits | transport and SD modules | A stalled device must return an error rather than hang the controller. |
| Persistent-sync state and explicit resync | `src/external_sync.c`, `src/bulk_channel.c` | Required protocol state, not instrumentation. |
| Bulk receive capture buffer | `src/bulk_channel.c` | Although it looks like a trace buffer, the raw window is part of the current functional arbitrary-bit-phase receive/de-shift algorithm. Remove only the APIs that expose it diagnostically, not the buffer itself. |
| Transfer ID and final status | `src/bulk_channel.c` | Required to associate READY/DONE and to report whether an SD write actually committed. |
| SD error taxonomy | `src/sd_card.c`, `src/handlers.c` | No card, no response, unusable, not ready, token, CRC, bus, rejected write, and busy timeout point to different actions. |
| SD retries and cached-state invalidation | `src/sd_card.c` | Enables card removal/reinsertion and recovery from transient read failure. |
| SD CRC verification | `src/sd_card.c` | Data-integrity feature; never classify it as diagnostic overhead. |
| Eight-byte SD failure trace | `src/sd_card.c` | Very small and currently distinguishes electrical silence, misalignment, and the initialization stage that failed. Keep it, but capture primarily on failure and report it through a compact status path. |
| Shared 10 ms timebase | `src/timebase.c` | Used for HID repeat, cache flush timing, power debounce, and other normal behavior. |

### Productionize or remove

| Item | Current cost/behavior | Recommendation |
|---|---|---|
| Timer1 physical edge counter | `last_rx_edges`, `last_tx_edges`, Timer1 setup/start/stop around every command | **Remove from normal build.** It measured PPS/gate clock glitches during transport bring-up. Keep only in diagnostic firmware if future board revisions need it. |
| Service calls/aborts | Two 16-bit counters in `src/main.c` | **Keep compactly** if they remain useful for detecting rejected requests. Saturating counters or a last-error reason may be more valuable than unbounded totals. |
| Microsecond phase profiler | Ten 32-bit accumulators, Timer3 ownership, reset state, brackets across main/transport/Bulk, and `CMD_PROFILE` | **Diagnostic build.** The ordinary timebase remains; remove only `uprof_*` and its call sites from normal firmware. |
| Record-read/cache-miss/retry counters | `rec_reads`, `cache_misses`, `read_retries`, and `reinits` are currently incremented, but their accessors are not used by the live handlers; legacy PING offset names remain | **Remove from the normal build unless the compact health reply deliberately adopts them.** Do not pay for counters with no consumer, and do not let legacy aliases force temporary PING field meanings forever. |
| XFER_STATUS raw/peek fields | Exposes transfer destination bytes, caller-selected raw-window slice, and sync-decision flags | **Remove from normal protocol** after the lane is stable. Keep DONE ID/status. Raw window remains internally functional. |
| Standalone `xfer_block[512]` | Used by raw block commands, ramp test, and current block-zero probe | **Revisit after defining a smaller media-probe command.** Do not remove while `CMD_SD_READ` needs it. A later probe may be able to reuse existing storage/cache memory, but that requires a deliberate design and RAM-map verification. |
| `SD_CMD0_LOOP` | Compile-time firmware that loops on CMD0 forever | **Keep source, diagnostic build only.** It is excluded when `SD_CMD0_LOOP=0`, so it need not burden normal firmware. |
| `SD_BUSY_LED` and conservative SD knobs | Hardware options and reliability settings | **Keep.** A disabled compile-time option is not resident debug overhead. Relax timings only one at a time with hardware tests. |

## Project and build scaffolding

| Item | Current state | Disposition |
|---|---|---|
| Root `main.c` | Empty generated-style infinite-loop stub. The hand Makefile builds `src/main.c`; the MPLAB `iocontroller` hook explicitly removes the root stub. | **Remove or clearly quarantine as generated scaffolding.** It is not firmware functionality and having two apparent entry points is a maintenance trap. Verify both supported build configurations before deleting it. |
| `controller_latch_write()` and initialization | Real 74HC595 output driver; initialization parks the outputs at zero | **Keep.** This is the future controller-output path, not merely a test. |
| `CONTROLLER_LATCH_COUNTER_TEST` | Optional `(n,n+1)` pattern every 500 ms; disabled by default | **Diagnostic build only.** Keep the guarded source, but omit the empty `controller_latch_tick()` call from a normal build or guard the call itself. |
| CMake comments calling `controller_latch.c` a diagnostic driver | Stale description in the persistent user hooks | **Correct during cleanup.** The driver is real; only the counter pattern is diagnostic. |
| `-gdwarf-3` | Adds source-debug information to the ELF/debug artifacts | **Keep.** Debug metadata is not programmed into the normal HEX and does not consume MCU runtime memory. |
| `README.md` controller-latch behavior | Says the incrementing pair runs every 500 ms even though the default flag is zero | **Correct during cleanup.** Document normal zero initialization separately from the optional counter-test profile. |

The Makefile currently has a placeholder `test` target that reports there are
no host tests. Removing embedded diagnostics increases the value of adding host
tests for CRC, frame decode, command dispatch, SD status mapping, key
translation, and queue behavior. Such tests cost no firmware bytes and should
be preferred over retaining counters in the target image.

## HID and MAX3421E diagnostics

The HID bring-up accumulated the largest diagnostic surface. The existing
investigation already identifies approximately 35 `usbh_xc8_*` counters/traces
and many `__XC8` guarded blocks across the vendored TinyUSB files. These guards
are not all equivalent.

### Keep a compact passive production status

Useful normal-build fields are:

- controller initialization state and detected revision;
- raw `/USB_INT` level;
- mounted-device count and keyboard address/speed;
- keyboard report count or last-report age;
- HID input queue depth and saturating dropped-input count;
- a compact last enumeration/controller failure code;
- attach/remove counts only if they help diagnose hot-plug behavior.

Reading this status must not acknowledge interrupts, run `tuh_task()`, alter
MAX3421E registers, change SPI speed, or restart enumeration.

### Move to diagnostic build

- 64-read revision bursts at 125 kHz, 1 MHz, and 4 MHz;
- GPOUT pattern write/read-back tests;
- `/USB_INT` active drive/polarity test;
- HIDSTATUS USB, transfer, hub, enumeration, and HID-class detail pages;
- last SETUP packet, endpoint table internals, branch IDs, raw retained-object
  dumps, and per-layer transfer counters;
- `hid_host_probe()` and the structures/accessors used only to format those
  pages.

The active probes were appropriate when the MAX3421E link was unknown. They are
not appropriate for a passive health command because they write controller
registers and deliberately exercise the bus.

### Remove trace-only TinyUSB scaffolding

Remove variables and write sites whose only effect is populating HIDSTATUS
detail pages, including the families currently named:

- `usbh_xc8_hxfrdn`, `usbh_xc8_xferdone`, `usbh_xc8_epnull`, and the
  `usbh_xc8_d_*` decision snapshot;
- `usbh_xc8_hub_trace`, hub lifecycle counters, and raw hub-object copies;
- enumeration milestone, bind, setup, endpoint-allocation, and endpoint-map
  trace fields that do not participate in control flow;
- HID class set-config/open/arm/completion breadcrumbs;
- local report callback breadcrumbs retained only for HIDSTATUS formatting.

Delete the corresponding structs, handler pages, protocol offsets, and external
declarations in the same change so dead diagnostic ABI does not remain.

## Functional XC8 patches that must remain

Do not delete a guarded block merely because it contains `XC8` or currently
shares storage with a trace variable. Retain every branch that changes program
correctness under XC8, including:

| Area | Functional workaround to preserve |
|---|---|
| TinyUSB weak defaults | Compile out weak stubs where XC8 does not honor weak linkage, allowing the IOController’s real callbacks to link. |
| Event queue | Copy an event into dedicated storage before the nested FIFO call so XC8 static-auto overlay cannot corrupt the live event. |
| Control transfers | Refuse unsupported callback-less blocking control transfers cleanly instead of entering a path XC8 cannot implement correctly. The counter can go; the safe refusal stays. |
| Interface binding | Preserve `desc_itf` and other live values across `driver->open()`, and retain the proven open-coded binding path where nested inline helpers were miscompiled. |
| Hub open | Preserve endpoint address and device address across `tuh_edpt_open()` before updating the retained hub object. |
| HID open | Preserve the HID object pointer, endpoint descriptor fields, next descriptor, and report-descriptor fields across nested endpoint-open calls; retain the valid boot-report packet-size fallback. |
| MAX3421E endpoint parsing | Keep byte-offset descriptor decoding and XC8-compatible structure definitions that avoid unsupported bit-field bases and miscompiled inline helpers. |
| Time delay | Keep the IOController-provided delay implementation and the guard that excludes TinyUSB’s weak default; enumeration depends on delays that do not complete early on the 10 ms tick. |
| XC8 type compatibility | Keep FIFO/endpoint structure changes and pointer/cast changes required for this compiler. |

The cleanup should rename dedicated correctness storage away from
`usbh_xc8_*` where practical—for example, `xc8_saved_hub_ep`—so future reviews
do not mistake it for removable telemetry.

## Vendored TinyUSB maintenance

The functional patches currently live as scattered edits inside
`third_party/tinyusb`. Before deleting the traces:

1. Separate correctness changes from instrumentation in the diff.
2. Record the correctness delta as an auditable patch file or a dedicated
   `XC8-PATCHES.md` with file/function/reason and the hardware test that proved
   it necessary.
3. Make the build fail loudly if a TinyUSB update no longer accepts the patch.
4. Remove diagnostic variables only after the functional patch set can be
   reviewed independently.

This is more important than retaining every counter: losing a compiler
workaround during a vendor update would reintroduce intermittent enumeration
failures that are much harder to rediscover than to document.

## CP/M diagnostic relationship

Coordinate controller cleanup with these host-side utilities:

| Controller feature | CP/M consumer | Normal-build recommendation |
|---|---|---|
| `PING` and firmware level | `PING.COM` and several diagnostic utilities | Keep and simplify together. |
| `RESET` | `RESET.COM` | Keep. |
| `CMD_SD_READ` | BIOS SD selection probe and `SDREAD.COM` | Keep until replaced by an explicit compatible media probe. |
| `CMD_BULK_TEST` | `BULK.COM` | Diagnostic profile only. |
| Raw block Bulk read/write | `SDBLK.COM`, `SDWRITE.COM`, `SDBENCH.COM`, parts of soak tests | Diagnostic profile only. |
| Record read/write/flush | BIOS SD driver, `SDFMT.COM`, record diagnostics | Keep. |
| Detailed `XFER_STATUS` fields | `BULK.COM`, `SDREC.COM`, `SDSOAK.COM` | Remove from normal protocol with those tools; keep DONE ID/status. |
| `PROFILE` | `BULK.COM`, `SDBENCH.COM`, detailed PING reporting | Diagnostic profile only. |
| Full `HID_STATUS` pages | `HIDSTAT.COM` | Replace with compact passive status in normal build; retain full pages only in diagnostic profile. |
| HID input | BIOS HID path and `HIDKEY.COM` | Keep. |

## Historical documents

Keep `docs/max3421-bring-up-debug.md`, SD startup diagnoses, and transport root-
cause reports as historical engineering records. They explain why the
functional XC8, SD, and sync workarounds exist. Mark resolved investigations as
historical rather than deleting them; they cost no firmware memory.

## Recommended cleanup sequence

1. Define two build profiles: normal and diagnostic. Start by changing only
   inclusion/feature guards, not transport behavior.
2. Freeze the compact normal `PING`, HID status, SD failure, and DONE contracts.
3. Extract and document the functional TinyUSB/XC8 patch set.
4. Remove HIDSTATUS pages 1–5 and their trace-only TinyUSB variables from the
   normal build.
5. Remove `CMD_PROFILE`, `uprof_*`, and normal-path profiling brackets.
6. Gate synthetic Bulk and raw block test commands to the diagnostic build.
7. Replace the current block-zero diagnostic command with an explicit media
   probe only after coordinating the BIOS command and verifying hot insertion,
   removal, and failure fallback.
8. Shrink `XFER_STATUS` to transfer ID/final status in the normal build.
9. Update `IOC_FW_LEVEL`, `ioc_levels.inc`, CP/M utilities, and protocol docs
   together.
10. Build both profiles and run cold boot, repeated warm boot, PING version
    mismatch, SD absent/insert/reinsert, read/write/flush, HID enumeration,
    keyboard input, link resync, CRC rejection, and timeout recovery tests.

## Acceptance criteria for the eventual normal firmware

- CP/M reads/writes records and flushes the SD cache correctly.
- Card removal and reinsertion recover without resetting the controller.
- A missing or failed card returns a specific status quickly enough for BIOS
  fallback to drive A.
- HID input, hot unplug/replug, repeat, lock LEDs, and escape sequences work.
- PING reports actual firmware level and a compact passive health snapshot.
- No passive diagnostic command changes MAX3421E, SD, sync, or interrupt state.
- CRC, sequence, transfer identity, timeouts, and resynchronization remain.
- The normal build contains no profiler, active electrical probe, raw stack
  trace page, synthetic ramp handler, or trace-only `usbh_xc8_*` family.
- The diagnostic build retains the tools needed for future board revisions and
  difficult regressions.
- Functional XC8 workarounds are reviewable independently of diagnostics and
  survive a TinyUSB refresh.
