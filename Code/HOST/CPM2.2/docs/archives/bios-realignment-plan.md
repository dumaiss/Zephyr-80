# BIOS Realignment and Instrumentation Cleanup Plan

Status: **complete.** W1-W8 are done and hardware-verified. Each package
records its own outcome below; the summary is under Outcome.

This consolidates the cleanup and savings notes that were written across the
CPM2.2 and IOController projects into one ordered work plan. The goal stated for
this pass is **realignment**: put every resident BIOS part back inside the window
it was designed for, and delete the bring-up instrumentation that is no longer
answering a question. A larger TPA is not the goal and is not achievable — the
BIOS window is fixed at `DA00h-FFFFh`. The goal is a defragmented, legible memory
map with real per-region headroom.

## Source notes consolidated here

| Document | What it contributes |
|---|---|
| `docs/debug-test-code-review.md` | Keep/productionize/remove classification for resident BIOS instrumentation and the ROM-disk utility manifest. |
| `../../MCU/IOController/docs/debug-test-code-review.md` | The controller-side half: which commands and trace fields disappear, and which CP/M callers must change with them. |
| `docs/optimization_report.md` | The completed 341-byte console-driver pass and the deferred size targets it deliberately left behind. |
| `memory/project_size_optimization.md` | Same pass, recorded as project memory. |
| `docs/memory-map.md`, `docs/symbol-map.md`, `build/layout-report.md` | The generated current-state layout this plan measures against. |
| `docs/phase0-storage-restoration.md` | Why the drive-A backend sits at `F900h`/`F910h` — it was placed after the VDrip transport. |
| `docs/v9958-console-implementation-plan.md`, `docs/vdrip9958-console.md` | The console transition that already happened and freed the space this plan reclaims. |
| `docs/io_controller_bios_readiness.md` | Historical: the slack estimate that the IOC transport was originally budgeted against. |

## What already happened

Two prior passes are complete and must not be re-planned:

- The console driver slot was defragmented once, reclaiming 341 bytes
  (`VDRIP_CONSOLE_CODE_END` `F680h` → `F52Bh`). Dead framed-parser code and
  diagnostic counters went with it.
- The direct V9958 console shipped and is the default (`CONSOLE=v9958`,
  `STORAGE_A=rom`). The VDrip console, VDrip transport, and VDrip storage
  backend are **no longer linked** in the normal build.

That second change is what makes this pass possible, and it is also what created
the misalignment: several bases are still at their VDrip-era addresses.

## Current-state measurement

Baseline, taken from the generated `docs/memory-map.md` and `build/firmware.lst`
before W2. The instrumentation figures below are what W2 acted on; the dead-space
and fragmentation figures are what W4 still has to act on.

### Dead space created by the V9958 transition

| Range | Bytes | Why it is dead |
|---|---:|---|
| `F680h-F908h` | 649 | Head of driver slot 5. Reserved for the shared VDrip transport (`CBIOS_VDRIP_TRANSPORT_CODE_BASE = F680h`), which is not linked. `CBIOS_STORAGE_VDRIP_CODE_BASE = F910h` is commented "follows common VDrip transport" — a transport that is gone. |
| `F9B2h-FA73h` | 194 | Slot 5, between the drive-A backend tail and the SD probe result fragment. |
| `ECA6h-ECFFh` | 90 | Slot 3, between the V9958 console tail (`ECA5h`) and the IOC Bulk block (`ED00h`). |

Roughly **930 bytes** of resident window are currently unreachable to any
component, purely because of stale `.org` bases.

### Resident instrumentation

| Item | Location | Bytes |
|---|---|---:|
| `IOC_DIAG_*` command-lane block (data) | `DCC0h-DCE3h` | 36 |
| `ioc_diag_capture` routine | `DCE4h-DD05h` | 34 |
| `IOC_BULK_DIAG_RESET` / `_HEADER` / `_FINISH` | `EE91h-EED5h` (slot 3) | ~69 |
| Bulk-reject store sites calling the above | throughout `cbios_ioc_command.asm` | not yet counted |
| `SIO_CORE_IRQ_COUNT` + increment + init | `FE75h-FE76h`, `sio_core.asm` | ~12 |
| `SIO0B_LAST_RR1`, `SIO0B_LAST_RX_ERROR` + `sio0b_record_rx_diag` | `FE77h-FE78h`, `DF0Ch` | ~25 |

The BIOS review's estimate of "roughly 100-180 resident bytes" recovered from a
compact last-failure record is consistent with these measurements once the
embedded store sites are counted.

### Fragmentation

The SD selection probe is split across four separate `.org` sites totalling 49
bytes, each wedged into whatever gap existed at the time:

```
CBIOS_SD_PROBE_RECOVERY_BASE = DFEDh   (16 bytes, core BIOS tail)
CBIOS_SD_PROBE_REQUEST_BASE  = F41Bh   (20 bytes, packed extension)
CBIOS_SD_PROBE_SUCCESS_BASE  = F909h   ( 6 bytes, slot 5)
CBIOS_SD_PROBE_RESULT_BASE   = FA74h   ( 7 bytes, slot 5 tail)
```

The behaviour is **Keep** — it is normal failure handling that stops a failed
non-A drive from trapping CP/M in a retry loop. Only the placement is wrong.

## Work packages

Ordered by dependency. Each package ends at a buildable, testable state; do not
batch them into one commit.

### W1 — Freeze the compact diagnostic contract — **DONE**

**Before deleting anything**, write down the record that survives. Both reviews
make this the first step for the same reason: `PING.COM` and other utilities read
`DCC0h` as a fixed address, so the contract has to be agreed before the fields
move.

Delivered:

- `src/cbios_defs.inc` — the frozen 16-byte record: field offsets, size, lane
  codes, and the Bulk reason codes promoted from source-comment literals to
  named protocol values. The superseded 36-byte layout is retained alongside it
  and marked as still in force until W2.
- `../HelloWorld/src/ioc_diag_record.inc` — the mirror for CP/M tools, following
  the `ioc_levels.inc` convention of one definition tracked against a named
  authority.
- `docs/ioc-diagnostic-record.md` — the normative contract, its reading rules,
  and the migration table for the tools that open-code the layout privately.
  (W1 found three; W2 found a fourth, `ioc_bulk.asm`, that a truncated search
  had hidden.)

Decisions taken, carried into W2:

- **Base stays at `DCC0h`.** The record is 16 bytes, so it is one row of a hex
  dump and leaves the rest of the region contiguous for the W5 core repack.
- **`LANE` gets an explicit byte.** `IOC_XPORT_BAD_CRC` is reachable from both
  lanes, so the status code alone cannot say which SIO's `RR0`/`RR1` were
  captured. One byte to remove that ambiguity is worth spending.
- **Transfer identity is the `(TYPE, SEQ)` pair**, not a transfer ID. The BIOS
  has no one-byte ID; `ioc_bulk_rx_type`/`ioc_bulk_rx_seq` are what bind a data
  phase to its command, so they are what the record carries.
- **W2 must bump `ZBIOS_XPORT_LEVEL` `07h` → `08h`** and update
  `../HelloWorld/src/ioc_levels.inc` in the same commit. Tools gate their decode
  on `IOC_DIAG_RECORD_MIN_XPORT_LEVEL`; the record carries no version byte of
  its own.
- **The scan-budget field is genuinely redundant**, not merely low-value:
  `IOC_XPORT_TIMEOUT_REPLY_MARKER` versus `IOC_XPORT_TIMEOUT_REPLY_BODY` already
  encodes the exact distinction it was added to make.

**Finding — nine bytes of fabricated evidence.** The eight-byte command marker
history at `+05h`-`+0Ch` and its index at `+0Dh` have **no writer anywhere in the
BIOS**; the scan loop that filled them was rewritten and the storage was left
behind. `PING.COM` reads all nine unconditionally and prints them labelled as the
bytes the reply scan saw. They are always zero, so the one report consulted when
the link is dead states that the line was silent regardless of what happened on
the wire. This moves those bytes out of "instrumentation whose question has been
answered" and into "actively misleading" — and it is why the replacement is a
last-failure record with an explicit `STATUS = 00h` "nothing recorded" state
rather than a set of always-printed slots.

**Verification:** definition-only, as planned. All three build-matrix
configurations assemble, link, and pass `check_overlap.py`. The regenerated
`docs/memory-map.md` is byte-identical and `docs/symbol-map.md` differs only in
the recorded symbol-table file size — no resident address moved.

### W2 — Shrink the command-lane and Bulk trace blocks — **DONE**

Implemented the frozen record; see `docs/ioc-diagnostic-record.md`.

**Result: −57 resident bytes**, and more importantly the freed space is now
contiguous and in the region W5 needs it:

| Region | Before | After | Delta |
|---|---|---|---:|
| Core BIOS diag block | `DCC0h`-`DD06h` | `DCC0h`-`DCD0h` | **−54** |
| Slot 4 command section | ends `F41Ah` | ends `F414h` | **−6** |
| Slot 3 bulk section | ends `EF3Ah` | ends `EF3Ch` | +3 |

Core BIOS now has 63 contiguous free bytes at `DCD1h`-`DD0Fh`.

What changed beyond the plan as written:

- **The capture code moved out of core BIOS** into the Bulk transport in slot 3,
  where deleting the old traces made room. That relocation is where 34 of the
  54 core bytes came from; shrinking the record itself only accounts for 20.
- **Every command failure now records, not just marker timeout.** All five exits
  funnel through one shared tail. A `STATUS` field filled in on one path out of
  five would read as current whichever failure actually happened — the same
  defect class as the marker history. The restructure cost zero bytes; it
  actually saved six, because the exits stopped repeating `ei`/`ret`.
- **No command-class field.** The plan called for "last accepted class". The only
  available source, `ioc_packet_header + 2`, holds the *previous* transaction's
  TYPE on the marker-timeout path — the one failure where the record matters
  most. Recording it honestly needs a store in the send path and slot 4 had no
  free bytes. Dropped rather than shipped subtly wrong.
- **Two field pairs are adjacent on purpose.** `LANE`+`BULK_REASON` and
  `READY`+`SYNCED` are written with 16-bit stores; without that the capture did
  not fit in slot 3. Both adjacencies and the record size are asserted at
  assembly time, and the assertions were verified to fire when deliberately
  broken.
- **Reserved bytes are explicit zeros**, not `.ds` — which leaves the `FFh` ROM
  fill and would have made the published contract false on its first read.
- **Four tools migrated, not three.** `ioc_bulk.asm` also hard-coded the block;
  it was missed in W1's survey because the search output was truncated.
- `ioc_ping.asm` carried the expected level as literal text, "(need 07)", which
  is exactly the drift `ioc_levels.inc` exists to prevent. It now prints the
  value from that file.

**Verification:** all three build-matrix configurations assemble, link, and pass
`check_overlap.py`. `check_reachable.py` reports the same 20 pre-existing
unreachable labels as the pre-change baseline — no regression. All 21 CP/M tools
rebuild clean against transport level `08h`, and the level byte at `DF7Ah` reads
`08h` in the ROM image. No stale reference to the old block survives in either
project.

**Hardware verification.** Partly done, and it found a bug.

- **SD read/write regression: PASS.** The two calls deleted from the IOCBULK hot
  path (`IOC_BULK_DIAG_RESET`, `IOC_BULK_DIAG_HEADER`) were pure diagnostics, as
  believed. This was the real risk of W2 and it is cleared.
- **Command-lane failure paths: not verifiable on this hardware.** The PIC drives
  the host reset lines, so stopping the controller resets the Z80 with it. There
  is no way to hold the machine alive through a command-lane failure. `RTSPROBE`
  is the only recoverable route and needs a power cycle.
- **Bulk-lane capture: PASS on hardware via `DIAGCHK.COM`.** `IOCBULK` with a zero length
  is rejected at `IOCBULK_BAD_LEN` before /RTSA is asserted, so nothing reaches
  the wire and the link is untouched, but the BIOS runs the full capture:
  `IOC_BULK_REJECT_INPUT` → `ioc_bulk_diag_capture` → `ioc_diag_capture_common`.
  That is the entire shared body, including the 16-bit `READY`/`SYNCED` pair
  copy, and the reserved bytes were confirmed to read zero. Added to the normal
  ROM manifest for now; it belongs in W6's diagnostic profile.

**Bug found and fixed: the mirror had drifted.** W2 reordered the record fields
in `cbios_defs.inc` to enable the two 16-bit stores, and
`../HelloWorld/src/ioc_diag_record.inc` was not updated with it. Nine of thirteen
fields were at wrong offsets in every migrated tool — `RR0` would have printed
the bulk reject stage, `BULK_STATUS` would have read a reserved byte — and the
dropped `IOC_DIAG_CLASS` was still declared. It went unnoticed because a stale
mirror assembles perfectly and only lies at runtime, and because `PING` prints
the record solely on a transport error, which could not be induced.

This is the *second* time two hand-maintained copies of one definition have
drifted in this project; `ioc_levels.inc` documents the first, where five tools
kept expecting controller level 62. So the fix is not just the corrected file:
`tools/check_diag_record.py` now compares the authority against the mirror —
offsets, size, base, lane and reason constants, the two adjacency requirements,
and the transport-level gate — and fails the build on any disagreement. It runs
from the BIOS build after `check_overlap.py` and from the tools build before any
`.COM` is assembled, so neither project can produce a stale pairing. Verified by
restoring the broken mirror and confirming it reports all ten faults.

**Still unverified:** the command-lane entry's `ld hl,#0 / ld (IOC_DIAG_LANE),hl`
— the store that clears a stale bulk stage off a command failure. Reaching it
needs a genuine command-lane failure, which this hardware cannot survive.

### W3 — Remove the dead SIO0/B and ISR-count instrumentation — **DONE**

**Result, normal build: −36 bytes** (32 code, 4 runtime state). The VDrip builds
lose 15 (13 code, 2 state) — they keep the diagnostic they actually read.

| Build | SIO core code | SIO core state |
|---|---|---|
| `v9958` (normal) | `DD10h`-`DF2Bh` (was `-DF4Bh`) | `FE70h`-`FE74h` (was `-FE78h`) |
| `vdrip` | `DD10h`-`DF3Eh` | `FE70h`-`FE76h` |

`SIO_CORE_IRQ_COUNT` and its `CONSOLE_IRQ_COUNT` alias are gone from **every**
build: nothing in either project read them, for control, recovery, or reporting.

The SIO0/B RR1 latches are gated on a new `VDRIP_TRANSPORT_LINKED` selector,
declared in `src/zephyr.asm` and rewritten by the Makefile beside the
`.include` it tracks — the same mechanism already used for the console, storage,
and transport sources. It has to be a build-time constant rather than a
consequence of the include because `sio_core.asm` is assembled *before*
`vdrip_transport.asm`.

**The one thing that had to stay.** `sio0b_record_rx_diag` is not purely
diagnostic despite its name: when RR1 shows a receive error it issues Error
Reset, and a latched special receive condition clears no other way. Deleting the
routine wholesale — which is what "remove the SIO0/B diagnostics" reads like —
would have left a path to wedge SIO0/B RX permanently. This matters in the
normal build specifically, because `cbios_boot.asm` calls
`sio_core_enable_interrupts` unconditionally, so SIO0/B interrupts are live and
the ISR reads bytes even though the V9958 console registers no sink for them.
Only the two stored bytes were gated; the reset is unconditional. Verified in
the generated listing.

**Also changed:** `tools/generate_memory_docs.py` required `SIO_CORE_IRQ_COUNT`
and the two latches as mandatory symbols. The counter row is deleted and the
latches moved to `optional_symbol_row`, which the generator already had for
build-conditional state. The generator failing the build was the thing that
caught the stale requirement, which is the behaviour worth keeping.

**Verification:** all three configurations build and pass `check_overlap.py`;
`check_reachable.py` still reports the same 20 pre-existing unreachable labels.
The generated `docs/memory-map.md` shows the shortened runtime state, and the
listing confirms the conditional blocks are assembled out of `v9958` and present
in `vdrip`.

**Hardware: PASS.** W3 shipped in the same image as W2 and is exercised by
ordinary use — the machine cold boots, the console draws, HID keyboard input
works, and SD read/write succeeds, which together run SIO core init, the
interrupt enable without its counter, and the ISR without its increment. The one
path normal operation does not reach is the receive-error branch of
`sio0b_record_rx_diag`, which needs an actual SIO0/B RX error; that the Error
Reset survives in the normal build was confirmed in the generated listing
instead.

**Note for W5:** this opens a second core-BIOS gap. `DF2Ch`-`DF4Fh` is now 36
free bytes before `VIDEO_SEND`, on top of the 63 at `DCD1h`-`DD0Fh` from W2.

### W4 — Realign slot 5 and consolidate the SD probe — **DONE, hardware-verified; one config left failing**

**Normal build (`CONSOLE=v9958 STORAGE_A=rom`):**

| | Before | After |
|---|---|---|
| SD probe | 4 fragments, 49 bytes at `DFEDh`, `F41Bh`, `F909h`, `FA74h` | one 41-byte block at `F680h` |
| Drive A: backend | `F910h`, "follows common VDrip transport" | `F6B0h` |
| Slot 5 headroom | 649 + 194 bytes, dead and fragmented | **814 bytes, contiguous** |
| Core BIOS tail | probe recovery fragment at `DFEDh` | **19 bytes returned** |

The probe was one linear routine stitched together with `jp`s across four
unrelated holes. Consolidating turned three of those into fall-through, so it
got 8 bytes smaller while gaining a stable base. Behaviour is unchanged, which
was the requirement: it is the fallback that stops a failed non-A drive looping.

Both builds now use the same order — probe, then drive A: backend, then
headroom — so the configurations differ only in where the run starts. That is
selected by `VDRIP_TRANSPORT_LINKED`, which W3 introduced and which moved ahead
of the `cbios_defs.inc` include so slot 5's layout can depend on it.

`CONSOLE=vdrip STORAGE_A=rom` builds normally.

**`CONSOLE=vdrip STORAGE_A=vdrip` no longer builds, deliberately.** It overflows
slot 5 by 29 bytes and fails layout validation naming `STORAGE_A_CODE_END`.

This is arithmetic, not a regression: that configuration needs the VDrip
transport (649) + the consolidated probe (41) + the VDrip storage backend (356)
= 1046 bytes in a 1024-byte slot. It only ever fit because 36 of the probe's 49
bytes lived *outside* slot 5, wedged into the core BIOS tail and the packed
extension — exactly the arrangement this package exists to end. No 41-byte
contiguous hole exists elsewhere in that build: the packed extension has 31
bytes across two pieces, the core BIOS at most 19.

Left failing on an explicit decision, pending a choice between retiring the
backend and giving it a two-way split probe. Documented at both places someone
would hit it: the `STORAGE_A` comment in the `Makefile` and the slot 5 layout
block in `src/cbios_defs.inc`.

**Stale figures corrected.** `docs/phase0-storage-restoration.md` records the
shared transport as 633 bytes and the VDrip storage backend as 338. Measured
now, they are 649 and 356. W8 should mark that document historical rather than
leaving its numbers to be trusted.

**Also changed:** `tools/generate_memory_docs.py` described the probe as four
fixed gaps and required each fragment's symbols. It now declares one block, and
the sentence about "fixed gaps at ..." is replaced by one naming the contiguous
range. The generator refusing to build until it was updated is the behaviour
worth keeping.

**Verification:** the two live configurations assemble, link, pass
`check_overlap.py` and `check_diag_record.py`, and regenerate the memory
documentation. `check_reachable.py` still reports the same 20 pre-existing
unreachable labels.

**Hardware: PASS.** This was the first package that could break booting rather
than misreport, and it does not:

- cold boot and ROM A: normal;
- SD B: reads and writes correctly;
- SC2 and M2 both start, and M2 compiled a program — a real workload doing
  sustained disk I/O through the relocated backend, which is a stronger test
  than any single read;
- an SD card removed and reinserted recovered, which is the path the probe's
  failure and re-selection handling exists for.

The relocated drive A: backend, the consolidated probe, and the fallback
behaviour are therefore confirmed on the machine, not just in the listing.

### W5 — Repack the reclaimed space into named regions — **DONE**

The acceptance criterion was that the generated memory map show "named regions
with useful local headroom, not new fragments placed into incidental byte-sized
gaps". That is now a table the build produces, rather than something a reader
has to reconstruct.

**`docs/memory-map.md` gained a Headroom section.** It reports every free
fragment of 4 bytes or more, attributed to its region, plus a per-region total
and largest fragment. Normal build:

| Region | Free bytes | Largest fragment |
|---|---:|---:|
| Core BIOS | 94 | 36 |
| Driver slots 0-4 | 90 | 90 |
| Packed driver extension | 31 | 27 |
| Driver slot 5 | 821 | 814 |

The distinction that makes it honest: free space is what was neither emitted nor
reserved by a `.ds`. A naive gap scan reports every uninitialised buffer as
headroom — the console's `.ds` buffers at `EB72h`, `EBD5h` and `EC16h`, the IOC
packet header at `F13Ch`, the HID state at `F642h` — which is exactly the wrong
answer for someone looking for room. A `.ds` occupies space while emitting
nothing, and shows in the listing as a line at the start of the run, so a gap
whose first address is a `.ds` line is storage and is excluded.

Run against the `vdrip` build it reports 75 / 4 / 31 / 172, which is a fair
summary of why that configuration has no room left.

**The other two items were already satisfied and are now recorded:**

- The boot banner moved out of incidental instruction gaps. Its text is bank 0
  read-only data at `8800h`, beside the font, costing no resident bytes; its
  printer is at `DCD1h`. That was done as part of the banner work rather than
  waiting for this package.
- The slot-3 gap at `ECA6h-ECFFh` is documented as console headroom by the table
  rather than being closed. Ninety contiguous bytes behind the console driver is
  useful where it is; the failure mode this plan exists to prevent is a *stray
  component* landing there, and a named 90-byte entry is what stops that.

**`CBIOS_SPARE_CODE_BASE` renamed in intent, not in symbol.** It is no longer
spare: it holds `ctc_disable_interrupts`, the 16-byte failure record, and the
banner printer, in sequence. The comment now lists all three and points at the
Headroom table as the authority, because "spare" invited exactly the wedging
this package is trying to end. The symbol itself stays — it is the `.org` that
`ctc_disable_interrupts` uses.

**Verification:** both live configurations build, pass `check_overlap.py`,
`check_diag_record.py`, and `check_reachable.py` at the unchanged baseline of 20.
No resident code moved: this package added a report and corrected comments.

**Hardware: PASS.** B: drive, SC2, M2, and Turbo Pascal compilations all run.
W5 changed no resident code, so what those runs actually re-verify is W4 plus the
banner CR/LF fix -- which is the useful result either way, since repeated
compiler workloads are a harder test of the relocated drive A: backend than any
single read.

### W6 — Split the ROM-disk manifest into normal and diagnostic profiles — **DONE**

`tools/build_rom_disk.py` now carries a profile per manifest entry, selected by
`ROM_DISK_PROFILE` in the Makefile. Default is `normal`; `diagnostic` is normal
plus everything else. **No utility source was deleted and every tool still
builds** — the diagnostic profile was verified to carry all 21.

**Normal rescue disk (12):** `PING`, `RESET`, `SDREAD`, `SDFMT`, `HIDKEY`,
`MONITOR`, `PIP`, `STAT`, `ZSID`, `DUMP`, `NOWRAP`, `WRAPON`.

**Diagnostic only (9):** `BULK`, `SDBLK`, `SDREC`, `SDSOAK`, `SDWRITE`,
`SDBENCH`, `RTSPROBE`, `DIAGCHK`, `V9958TST`.

The reason the split matters is narrower than "tidiness". Four of those tools
destroy data on whatever card is inserted, with no drive letter to get wrong:
`SDWRITE` overwrites block 0 and the partition table, `SDREC` overwrites records
0-7 which is the head of the CP/M directory, `SDSOAK` writes across multiple
LBAs, and `SDBENCH` writes a fixed high LBA and never restores it. A rescue disk
carrying those is a rescue disk that can finish the job. `RTSPROBE` is not
destructive to data but invalidates persistent sync and takes the machine down.

Two entries the source reviews had not classified:

- `DIAGCHK` — diagnostic. It is harmless (its rejection never reaches the wire)
  but it is a test tool, not a rescue tool.
- `V9958TST` — diagnostic. The console it tests is now the production console,
  so it is a display bring-up aid rather than something to reach for in trouble.

**`SDFMT` stays on the normal profile and needs no change.** The review asked
for explicit confirmation naming the SD backend rather than a drive letter, and
it already does exactly that: it prints "This ERASES the SD card directory.
Proceed (y/N)?", accepts only `y`/`Y`, and aborts on anything else. It is kept
because without it a fresh card cannot be made usable at all — that is
provisioning, not a soak test.

`HIDSTAT` was already absent from the manifest, so nothing was needed there.

**Verification:** both profiles build; the normal image was confirmed to contain
all 12 rescue tools and none of the 9 diagnostics, and the diagnostic image to
contain all 21.

**This package had to land before W7** and now has. Removing a controller
handler while its `.COM` is still on the rescue disk makes the tool fail in a
way that looks like a transport fault.

### W7 — Controller-side removals (IOController project)

The controller review's sequence, condensed. These change the private protocol,
so they travel together with a `IOC_FW_LEVEL` bump (currently 68 decimal / `44h`)
and matching `ioc_levels.inc` and `ZBIOS_XPORT_LEVEL` updates.

1. Define normal and diagnostic build profiles; change inclusion guards only, not
   transport behaviour.
2. **DONE — extract and document the functional TinyUSB/XC8 patch set.**
   See `../../MCU/IOController/docs/XC8-PATCHES.md`.

   The review expected scattered edits. They are not: TinyUSB is a git
   **submodule**, the patch set is **one commit** (`55b0d86f9`) on branch
   `zephyr80-xc8-max3421` of a fork, based on upstream tag `0.20.0`, and the
   working tree is clean. A refresh is a rebase of one commit, not a
   re-derivation, and the whole patch is recoverable with one `git diff`.

   **The finding that matters: seven `usbh_xc8_*` symbols are live state, not
   telemetry.** Each is written before a nested call that XC8's static-auto
   overlay would clobber, and read straight back into a structure field:
   `usbh_xc8_itf_save`, `_hub_open_ep`, `_hub_open_daddr`, `_hid_open_itf`,
   `_hid_ep_addr`, `_hid_ep_mps`, `_hid_next_desc` -- plus the already
   well-named `_xc8_queue_event`. They share a prefix with 68 trace variables,
   so step 4 as originally worded, "remove the trace-only `usbh_xc8_*`
   variables", would have deleted them and broken hub and HID enumeration
   silently. The discriminator: correctness storage is read back *inside*
   TinyUSB; telemetry is only written there and read by `HIDSTATUS`.

   Mechanical classification confirms this cannot be a prefix filter. Of 63
   hunks: 23 pure correctness, 3 pure trace, and **37 mixed**.

   `tools/check_xc8_patches.sh` now verifies all ten correctness workarounds
   before the firmware builds, and was confirmed to fail when one is renamed
   away. Renaming the seven off the `usbh_xc8_*` prefix remains to do, in the
   same change as the trace removal.

   **Hardware: PASS.** The firmware runs normally with the guard in place, and
   CTRL-ALT-ESC restarts the machine as intended -- so the latch, the main-loop
   poll, the cache flush and `handler_reset()` all work, and adding them
   disturbed neither HID input nor enumeration.
3. **DONE — HIDSTATUS detail pages, the active probe, and the trace ABI.**

   The seven correctness stores are renamed `xc8_saved_*`, so **everything still
   called `usbh_xc8_*` is telemetry, without exception**. Applied with word
   boundaries across the submodule and `src/ioc_hid.c` — necessary, because
   `usbh_xc8_hid_ep_mps` is correctness storage while `usbh_xc8_hid_ep_mps_lo`
   and `_hi` beside it are traces. Both profiles built byte-identical
   afterwards, as a pure rename should. `tools/check_xc8_patches.sh` was updated
   and re-verified to fail when one is renamed away.

   Then gated to the diagnostic profile: detail pages 1-5 and their dispatch;
   the five `*_debug()` accessors; `hid_host_probe()` with
   `probe_revision_burst`, `gpout_loopback_at` and `int_drive_test`; the probe
   field fills in the passive page; the diagnostic structs and declarations in
   `ioc_hid.h`; and the block of **66 trace externs** in `ioc_hid.c`, which in a
   normal build were dead ABI pointing at storage nothing read.

   | | Program | Data |
   |---|---:|---:|
   | diagnostic | 65,781 | 7,444 |
   | **normal** | **56,471** | **7,286** |
   | saved | **9,310** | **158** |

   **`hid_host_probe()` had to go, not merely shrink.** It runs 64-read revision
   bursts at three SPI rates, GPOUT loopback writes and an interrupt drive test
   — it writes MAX3421E registers and changes SPI speed. The review's rule is
   that reading the health of the link must not be able to change it, and page 0
   called it on every request.

   **`HidHostUsbState` was nearly gated with it and must not be.** It sits among
   the probe types but is explicitly "live USB state, as opposed to the bring-up
   probes" — it backs the passive page in every build. The compiler caught it;
   the guard is now split around it. Same class of near-miss as the other three
   in this plan.

   Reply layouts are unchanged in both profiles: retired fields keep their
   offsets and read zero, so a tool decodes the same frame either way. A normal
   build answers any page number with the passive page rather than rejecting it,
   so an older tool asking for page 3 gets real status instead of an error it
   would have to be taught about.

   **Hardware: PASS.** Normal tests with SC2 and M2; keyboard hot detach and
   re-attach. The topology matters for what this verifies: a hub is attached
   directly to the mezzanine and is the only device the MAX3421E sees, with the
   keyboard and d-pad behind it. So every one of these runs exercises hub
   enumeration — which is exactly what `xc8_saved_hub_ep` and
   `xc8_saved_hub_daddr` protect, and the path no build can check.

   **Known pre-existing limitation, not caused by this work:** moving the
   keyboard to a *different* port while the machine is up captures no keys.
   Detach, re-attach elsewhere, detach again, re-attach in the original port
   recovers. Both ports work individually; only changing port after boot fails.
   This predates the cleanup and was reported as long-standing. Recorded here
   because it is the kind of thing a later reader would otherwise suspect this
   package of having introduced.

9. **DONE — `IOC_FW_LEVEL` 68 → 69**, with `../../HelloWorld/src/ioc_levels.inc`
   and its printable hex/decimal digits in the same change. Level 69 says which
   reply fields carry real measurements; it does not change any frame layout.

4. **DONE — build profiles, profiler, edge counters and diagnostic commands.**

   `IOC_DIAGNOSTIC_BUILD` in `include/config.h`, selected by `IOC_PROFILE` in
   the Makefile (`normal` default, `diagnostic` opt-in). It gates **inclusion
   only** -- transport behaviour, timing and error handling are identical, so a
   fault reproduced on one profile is a fault on the other. The flags stamp
   includes the profile, so switching forces a rebuild rather than leaving a
   stale hex.

   | | Program | Data |
   |---|---:|---:|
   | diagnostic (= previous behaviour) | 65,781 | 7,444 |
   | **normal** | **62,993** | **7,371** |
   | saved | **2,788** | **73** |

   Gated: `CMD_PROFILE` and `handler_profile`; the `uprof_*` accumulation;
   `CMD_BULK_TEST`, `CMD_SD_READ_BULK`, `CMD_SD_WRITE_BULK` and their handlers;
   the Timer1 edge counters and Timer1 itself. Gated commands fall through to
   `handler_unknown()`, which rejects the class explicitly -- distinguishable
   from a transport fault -- and their CP/M callers already ship only on the
   diagnostic ROM profile from W6.

   **`uprof_now()` is deliberately NOT gated.** It reads as profiling but it is
   a microsecond time source: `bulk_channel.c`'s `wait_for_host_ready()` uses it
   for the bounded 500 ms wait on the host's RTS, and its own comment records
   that Timer3 gives that contract without adding ~1 ms to every good transfer.
   Compiling it out would either wedge the controller on a host that never
   arrives or slow every transfer that succeeds. Only the accumulation, the ten
   32-bit slots and the reset plumbing are gated; Timer3 runs in both profiles.

   That is the **third** time in this plan that something named like a
   diagnostic turned out to be load-bearing, after `sio0b_record_rx_diag`'s
   error-latch reset in W3 and the seven `usbh_xc8_*` correctness stores in
   step 2 above. `config.h` now lists what is deliberately not gated, and why.

   **Hardware: PASS** on normal-profile firmware -- B:, `PING`, `SDREAD`, SC2,
   and M2 running and compiling programs. The M2 compiles matter most: sustained
   bulk-lane I/O through `wait_for_host_ready()`, which is the path that depends
   on the ungated `uprof_now()`.

   `PING` no longer prints the physical RB3/SCK edge counts. Their reply offsets
   stay reserved and read zero in a normal build, so no tool's frame layout
   changes -- but printing "0000 clocks" for something never measured is the
   fabricated-evidence pattern this plan exists to remove.

5. *(done as part of 4)*
6. **DONE — `CMD_XFER_STATUS` shrunk to transfer ID and final status.**

   The de-shift peek, the caller-selected raw-window slice and the two
   sync-decision flags are gated; `IOC_OFF_DONE_XFER_ID` and
   `IOC_OFF_DONE_STATUS` stay in both profiles. Another **384 bytes** of program
   space, bringing the normal build to 62,609 — **3,172 below** the diagnostic
   profile.

   The raw receive window itself stays, as the review requires: it is part of
   the functional arbitrary-bit-phase de-shift algorithm, not a trace buffer.
   Only the API that exposed it diagnostically is gone from the normal build.

   **`IOC_DONE_PAYLOAD_LEN` is deliberately unchanged between profiles.** The
   gated fields read zero in a normal build rather than shortening the packet,
   so the wire format is identical in both. Shrinking LEN would change the
   packet on the wire and would have to be coordinated with the BIOS and every
   tool that decodes a DONE reply — a bigger step than removing a fill, and one
   with no byte saving on a fixed 32-byte frame.

   `SDFMT` reads `IOC_OFF_DONE_STATUS` after every record it writes, which is
   how it learns the card committed. That was checked before gating: it is byte
   5, and it is kept.
7. *(done as part of 4)*

8. **DONE — stale claims and scaffolding**, plus the mislabelled SD trace.

   - `README.md` said the latch writes an incrementing pair every 500 ms.
     `CONTROLLER_LATCH_COUNTER_TEST` defaults to **0**, so in a normal build the
     outputs are parked at zero by `controller_latch_init()` and
     `controller_latch_tick()` compiles to an empty call. Now documents the
     default behaviour and names the flag that changes it.
   - The CMake user hook called `controller_latch.c` a "diagnostic driver
     source". It is a real output driver that owns the 74HC595 pair; only the
     optional counter pattern inside it is diagnostic. The old wording invited
     deleting a driver the hardware depends on.
   - Root `main.c` **cannot simply be deleted**: MPLAB regenerates its reference
     in the per-configuration `.generated` cmake files and in
     `.vscode/IOController.mplab.json`. The quarantine already existed --
     `list(REMOVE_ITEM _ioc_sources "${_ioc_root_stub_main}")` -- so what was
     missing was the file admitting it. Its plausible-looking `main()` with an
     empty forever loop is gone; the translation unit now defines nothing, so a
     build that wrongly includes it fails at link naming the file rather than
     producing an image that starts and spins.
   - `PING` labelled the controller's SD failure trace "SD SPI trace". The
     controller re-arms and zeroes it on **every** CMD17, so on a healthy
     machine it permanently shows the last good read's R1 poll -- typically
     `FF FF 00`, meaning "polled twice, card ready". Reported as a suspected
     fault during W2 hardware testing, which is exactly the misreading the
     label invited. Now "last SD cmd poll".

   Still open on that trace: because a success overwrites it immediately, a
   failure followed by a successful retry leaves no evidence. Making the capture
   failure-biased is a firmware behaviour change and belongs with the rest of
   the controller work below, not with a relabel.

Do **not** replace `CMD_SD_READ` (`03h`) with a smaller media probe in this pass.
The BIOS selection probe depends on it, and W4 already changes that code's
placement; changing its protocol at the same time would make a fallback
regression impossible to bisect. Sequence it after W4 has been proven on
hardware.

Never silently reuse an old command number for different semantics.

### W8 — Regenerate and re-baseline the documentation — **DONE**

- `docs/memory-map.md` and `docs/symbol-map.md` regenerate from the build, so
  they were already current; the Headroom table W5 added is now the authority on
  free space in the resident window.
- `docs/optimization_report.md` — marked **historical**. It documents one pass
  over `cbios_console_vdrip.asm`, a driver the normal build no longer links, so
  its addresses describe code that is not loaded. Its deferred targets are
  marked superseded: acting on them would shrink an unlinked driver, and they
  are worth ~14 bytes against the hundreds these packages found by fixing
  placement rather than instruction selection.
- `docs/phase0-storage-restoration.md` — marked **historical, with its two wrong
  figures corrected in place**: the shared transport is 649 bytes not 633, and
  the VDrip storage backend 356 not 338. That 22-byte error is exactly why
  `CONSOLE=vdrip STORAGE_A=vdrip` no longer fits slot 5, and it was trusted
  before being measured. Leaving it uncorrected would set the same trap again.
- `docs/io_controller_bios_readiness.md` — marked **historical**. Its "~703
  bytes of unallocated space at `F52Ch–F7EAh`" describes a layout that no longer
  exists.
- Both `debug-test-code-review.md` files — changed from "proposed cleanup plan;
  no code has been removed" to **carried out**, each pointing at this plan for
  the outcome. Neither was edited to match what shipped: they are the reasoning
  the work was built from, and where the work departed from them, the departure
  is recorded here. The IOController one names its own two corrections up front,
  since both would have caused silent hardware failures if followed literally.

## Outcome

**Resident BIOS**, normal build (`CONSOLE=v9958 STORAGE_A=rom`):

| | Result |
|---|---|
| Instrumentation removed | 93 bytes (W2 57, W3 36) |
| Slot 5 | 814 contiguous free bytes, was ~840 dead and fragmented |
| Core BIOS | 94 free bytes across 5 named fragments |
| SD selection probe | one 41-byte block, was four fragments across three regions |
| Headroom | 1,036 bytes, reported per region by the build |

**Controller firmware**, normal profile:

| | Program | Data |
|---|---:|---:|
| before | 65,781 | 7,444 |
| after | **56,471** | **7,286** |
| saved | **9,310** | **158** |

**Four things named like diagnostics turned out to be load-bearing**, and each
would have failed silently on hardware rather than at build time:

1. `sio0b_record_rx_diag` also clears the SIO0/B receive-error latch (W3).
   **Renamed `sio0b_clear_rx_error`.**
2. Seven `usbh_xc8_*` symbols are live state preserved across nested calls that
   XC8's overlay clobbers — now `xc8_saved_*` (W7).
3. `uprof_now()` is the microsecond time source behind the Bulk lane's bounded
   wait, not a profiler (W7). **Renamed `timebase_us_now()`, with
   `uprof_init()` -> `timebase_us_init()`.**
4. `HidHostUsbState` sits among the probe types but backs the passive status
   page in every build (W7).

Three of those four were fixed by renaming rather than by documenting, on the
principle that the reader who deletes a symbol is the reader who never opened
the document. Each rename was verified byte-identical. `HidHostUsbState` was
left alone: its name never claimed to be a probe.

**Two defects were found that no one was looking for**: nine bytes of the old
diagnostic block had no writer at all, so `PING` printed fabricated evidence in
the one report consulted when the link is dead; and the record mirror silently
drifted from the BIOS in W2, leaving every migrated tool reading wrong offsets.
Both now have build-time guards — `check_diag_record.py` and
`check_xc8_patches.sh` — that were each verified to fail when the fault is
reintroduced.

## Cross-project ordering

The dependency that matters most: **W6 before W7**. If a controller handler is
removed while its `.COM` is still on the rescue disk, the tool fails in a way
that looks like a transport fault. The reviews both call this out.

```
W1 → W2 → W3 → W4 → W5 → W8
              W4 → W6 → W7 → W8
```

W3 can proceed in parallel with W2; W6 can start any time after W1.

## Verification gate

Every package that touches resident code ends with all of:

- `make CONSOLE=v9958 STORAGE_A=rom` (the normal build)
- `make CONSOLE=vdrip STORAGE_A=rom`
- `make CONSOLE=vdrip STORAGE_A=vdrip`
- `tools/check_overlap.py` and `tools/check_reachable.py` clean
- regenerated memory docs inspected, not just regenerated
- hardware: cold boot, warm boot, ROM A:, SD B:, HID keyboard input, SD
  absent/insert/reinsert, and failure fallback to A:

## Acceptance criteria

Carried forward from both reviews, plus this pass's realignment goal:

- No BIOS jump-table entry moves or changes calling convention. All of
  `DA00h-DA48h` is published ABI.
- `ZBIOS_XPORT_LEVEL` stays at `DF7Ah`; `IOCALL` stays at `DF7Bh`; `VIDEO_SEND`
  stays at `DF50h`.
- Drive A remains ROM-backed and always available; SD and HID remain functional.
- A failed non-A drive selection returns to A instead of looping.
- CRC, sequence, length, type, status, transfer-ID validation, bounded timeouts,
  and `LINK_SYNC` recovery all remain intact. A timeout is not debug code.
- `PING.COM` reports the BIOS transport level and the actual/expected controller
  firmware level without depending on raw trace offsets.
- Destructive utilities are absent from the normal ROM profile.
- The SD probe is one contiguous block, not four.
- The generated memory map contains named regions with documented headroom.

## Explicitly out of scope

- Enlarging the TPA. The BIOS window is fixed; this pass buys legibility and
  headroom, not user memory.
- Deleting `cbios_console_sio.asm`, `cbios_storage_ramdisk.asm`, or
  `cbios_storage_vdrip.asm`. Unlinked sources consume no BIOS bytes; their
  long-term support is a separate decision.
- Deleting the historical investigation documents in either project.
- Removing SD CRC verification, the SD error taxonomy, the eight-byte SD failure
  trace, or the Bulk raw receive window. All four are functional.
- The remaining `call ... / ret` → `jp` peephole conversions deferred by the
  earlier optimization pass. They were left for readability on purpose and are
  worth ~14 bytes; not worth reopening during a structural repack.
