# Zephyr-80: Lessons Learned

Consolidated from the bring-up records in `Code/MCU/IOController/docs/` and
`Code/HOST/CPM2.2/docs/` — roughly 11,500 lines of planning, root-cause reports
and debug logs, reduced to what is worth carrying forward.

**This document is not an authority on anything.** It records what went wrong,
what went right, and which mistakes were expensive. For current behaviour use
the subsystem documents listed at the end; for current numbers use
`Code/HOST/CPM2.2/docs/memory-map.md`, whose headroom table is generated from
the build rather than written by hand.

---

## 1. The patterns that repeated

These recurred across subsystems that share no code — the SIO transport, the
MAX3421E, the SD card, the BIOS realignment, the FAT32 work. They are the part
of this document most likely to save time on the next thing.

### Silence is not evidence of absence

A seated SD card that has not entered SPI mode is exactly as silent as an empty
socket. The driver was therefore written so that **only the presence pin can
report a card as absent**; bus silence reports `SD_ERR_NO_RESPONSE` and a trace
buffer separates the cases.

The same shape appeared on the MAX3421E: an undriven MISO reads as all-ones,
which is indistinguishable from a part that is present and answering `FFh`. And
on the command lane, where a frame the receiver rejects produces *no reply at
all*, so a validation failure reaches the host looking like a dead controller.

Whenever a failure mode can produce "nothing", something must be able to tell
"nothing" apart from "nothing yet".

### The thing that "appeared to work" was usually being masked

Three separate faults were latent for months because an earlier, cruder
implementation happened to hide them:

| Fault | What was masking it |
|---|---|
| Two extra SIO clock edges per transaction | The old transport re-established External Sync every reply, resetting the character boundary before the error could accumulate |
| Stale `FFh` in the SIO receive pipeline | The old Bulk reader disabled and reinitialised the receiver each transfer, discarding pipeline state |
| A `const`/RAM pointer that XC8 mishandles | The function was never linked until a new command referenced it |

In every case the *change* was blamed first, and in every case the change had
only removed the masking. **When a long-standing subsystem breaks the moment
something adjacent is improved, suspect exposure before regression.**

### Correlation recorded as measurement

`include/sd_card.h` carries a correction worth reading in full. An earlier
comment claimed, "confirmed on a scope", that SPI_CLK was gated by the device
selects. What the scope actually showed was clock and select coinciding — which
they did, because the firmware only ever clocked while a select was asserted.

That inference was written down as a measured hardware fact, and on its
strength the spec-required CS-high power-up burst was deleted as useless. It is
not useless: it is the step that puts an SD card into SPI mode, and losing it is
the likeliest cause of the intermittent all-`FFh` CMD0 traces that followed.

**Never write inferred topology into a comment as though it were measured.** The
cost is not the wrong belief; it is the correct code deleted on the strength of
it.

### Diagnostics can fabricate evidence

Nine bytes of the BIOS failure record — the command marker history and its index
— had **no writer at all**. The scan loop that once filled them had been
rewritten and the storage left behind. `PING.COM` printed those zeros
unconditionally, under a label saying they were the bytes the reply scan saw.

On the one report anybody consults when the link is dead, that is not a stale
field. It is fabricated evidence reading "the line was silent" regardless of
what happened on the wire.

The replacement is a *last-failure* record with an explicit "nothing recorded"
state, rather than a set of always-printed slots. **A diagnostic that cannot
distinguish "no data" from "zero" is worse than no diagnostic.**

### Things named like diagnostics that were load-bearing

The instrumentation-removal pass found four, each of which would have failed
silently on hardware rather than at build time:

| Was named | Actually is | Now named |
|---|---|---|
| `sio0b_record_rx_diag` | Also clears the SIO0/B receive-error latch — the only thing that does | `sio0b_clear_rx_error` |
| `usbh_xc8_*` (seven of them) | Live state preserved across nested calls XC8's overlay clobbers, sharing a prefix with 68 real traces | `xc8_saved_*` |
| `uprof_now()` / `uprof_init()` | The microsecond time source behind the Bulk lane's bounded wait | `timebase_us_now()` / `timebase_us_init()` |
| `HidHostUsbState` | Backs the passive status page in every build | unchanged — the name does not claim otherwise |

**The fix is to rename, so the mistake is no longer available to make.** A note
in a document is not a fix: the reader who deletes the symbol is the reader who
never opened the document. All three misleading names are now gone, and each
rename was verified to produce a **byte-identical** binary — which is both the
proof it was a pure rename and the cheapest possible regression test.

The discriminator that found the XC8 seven is worth reusing: *correctness
storage is read back inside the module; telemetry is only written there and read
from outside.*

### A helper that reads its caller's variables is coupled to that caller

The BIOS's `ccp_clear_redraw` looked like a display routine — clear the screen,
draw the prompt. It also read `ACTIVE` and `USERNO` and wrote `CURPOS` and
`STARTING`, all four of them **private variables of the stock BDOS**, at fixed
addresses inside the region a BDOS replacement overwrites.

Calling it from ZSDOS therefore printed a prompt built from message-string bytes
(`K=` instead of `A`) and, far worse, **overwrote a `RET` instruction with
`03h` on every keystroke** — ZSDOS fell through a return into a string as code.
The visible symptom was cosmetic; the real one was silent.

Nothing in the routine's name, signature or comment said "only valid while the
stock BDOS is resident". The fix was to need none of it: the console driver
already clears on `0Ch`, and the drive and user are in page zero at `0004h`
where every CP/M maintains them.

**Before reusing a routine across a component swap, check what it touches, not
what it is called.** The same shape appeared twice more in one afternoon —
`RDBUFCCP` compared against one CCP's buffer address, and `NBYTES` stored
history inside the CCP that a replacement CCP does not have.

### One flag must gate one variable

The single most expensive process error in the project's history. During the
FAT32 bring-up, one build flag gated the volume handlers **and** the filesystem
handlers together. Eleven firmware builds and a reset-looping machine later, the
conclusion "FatFs cannot be linked into this firmware" was recorded as fact in
three places.

It was wrong. Every build that linked FatFs also linked an unrelated defect. Of
eleven builds, the real cause predicted the outcome 11/11; FatFs predicted 2/11.
Once the real defect was fixed, FatFs linked and ran.

A bisect flag that moves two things does not bisect.

### Measure; then re-measure after the tree moves

`phase0-storage-restoration.md` recorded the shared VDrip transport at 633 bytes
and the storage backend at 338. The measured figures are **649** and **356**.
Those two stale numbers were trusted during the slot 5 realignment, and the
22-byte difference is why `CONSOLE=vdrip STORAGE_A=vdrip` no longer fits in
driver slot 5 and is deliberately left failing.

The FAT32 design document repeated the pattern from the other direction: its
baseline was 65,095 bytes of flash against a tree that had since shrunk to
60,042. Its conclusions survived; its numbers did not.

---

## 2. Hardware facts that cost time

Board-level truths that are not visible from the source, listed because each one
was paid for once already.

### The SIO clock is gated, and idles high

PIC `RB3/SIO_SCK` drives both SIO clocks through a **74AHCT125**, enabled by
`/SIOA_CS` and `/SIOB_CS`, with 100 kΩ pull-ups (R37/R38) on the gated outputs.
An unselected SIO clock therefore rests **high**.

With the firmware parking the clock low, releasing a channel select produced one
low-to-high transition that the SIO counted as a receive clock. A command
transaction releases the gate twice, so the Z80 received 562 edges where the PIC
generated 560 — a two-bit drift per transaction, returning to the same byte
boundary every fourth transaction. PING succeeded exactly once in four.

Two consequences worth remembering:

- **RB3 and the SIO clock input are different nets.** PIC-side edge counters
  measure the source pin and cannot see a transition created downstream by the
  buffer and its pull-up. They read 560 while the SIO received 562.
- The fix is that the shared clock now idles **high everywhere** — SPI2 uses
  `CKP=1, CKE=0`, `LATB3` is set high before either select, and PPS handovers
  happen at the same level.

### The MAX3421E powers up in half-duplex, and this board cannot do half-duplex

In half-duplex the part tri-states MISO and drives read data back out of its own
**MOSI** pin — after the eighth falling edge, expecting the master to have
released that line. On this board `SPI_MOSI`, `SPI_CLK` and `/USB_CS` pass
through **U3, a CD74HC4050 at 3V3**, which is unidirectional PIC→MAX3421E. The
master's driver cannot be turned off.

So every read returned garbage from an undriven MISO, and on the second byte of
each read two CMOS output stages fought each other.

Worse, the firmware read the REVISION register *before* calling `tuh_init()` —
and the only code that sets `FDUPSPI` is inside `hcd_init()`. **The revision
check gated the call that establishes the revision check's own precondition.**
A lock with no key.

The bootstrap is a blind *write* (`8A 10`, PINCTL, DIR=1), because a write
behaves identically in both modes: the master drives MOSI for the whole cycle
and the part never turns its driver on. Only reads differ, which is why the
order cannot be inverted.

### The MAX3421E cannot be reset, and does not share the PIC's reset

`RES` (U2.12) is strapped to +3V3 — there is no reset control. `RES` and
`CHIPRES` both spare PINCTL and USBCTL; only a power-on reset clears them. The
part sits on the mezzanine 3V3 rail while the PIC is a separate 5 V board.

**Resetting or reflashing the PIC does not reset the MAX3421E.** Once the
FDUPSPI write lands once, it stays in full duplex across every subsequent PIC
reset — which is why the blind write is repeated per probe burst, and why
exercising the real cold-start path means dropping the 3V3 rail.

Also on that part: `GPX` (U2.17) is a no-connect, so the one-probe "is it alive"
answer is unavailable — worth bodging on the next spin. All eight `GPOUT` pins
are no-connects, which is what makes the walking-pattern loopback test free.
`/USB_INT` reaches PIC RA0 unbuffered at 3.3 V into a 5 V part; if RA0's buffer
is Schmitt (VIH = 4.0 V) a high never registers and the pin reads permanently
asserted. That presents as "enumeration silently never starts", not as a bus
fault; `INLVLA0` selects TTL levels.

### Test electrical paths at every rate

The GPOUT loopback runs at 125 kHz, 1 MHz and 4 MHz **on purpose**. The failure
being hunted is propagation delay through U3, which is fixed — so a marginal
part passes slow and fails fast, and a single-rate test calls the board healthy.

Walking-one alone cannot separate stuck-low from undriven, so the patterns are
`00 01 02 04 08 05 0A 0F`: `00`/`0F` pin both stuck-at polarities and `05`/`0A`
cross every adjacent pair in both directions.

### Scope captures of bursty buses lie

Within a burst SCK genuinely is 125 kHz / 1 MHz / 4 MHz. But the whole probe is
about 10 ms and fires once per tool run against an otherwise silent bus, so a
free-running scope measures the burst *envelope*. Trigger on the falling edge of
the chip select.

### SD cards are not interchangeable

After connector rework and confirmed signal levels, two generic INDMEM 16 GiB
SDHC cards fail ACMD41 startup where a SanDisk 4 GiB works reliably in the same
socket with the same firmware. Brand, controller batch, capacity and adapter use
are confounded in that sample — treat both failing cards as **one** result, not
two independent data points.

The conservative settings in `sd_card.h` (125 kHz init, 12 power-up bytes or 96
clocks with CS high, 10 ms settle, CRC verification on) exist because of this
and should be relaxed **one at a time**, keeping the CRC check, so a regression
names its own cause.

The first successful compatibility change came from comparing the driver with
John Winans' Z80 Retro implementation. Both drivers deassert CS between `CMD55`
and `ACMD41`, so that transaction boundary was not the fault and must not be
removed. The important difference was at the end of each transaction: John's
driver emits one `FFh` byte while the SD card is still selected, then raises CS
and emits another two `FFh` bytes.

`sd_deselect()` now preserves that exact order: **8 trailing clocks with SD CS
low, followed by 16 idle clocks with every SPI1 device deselected.** With that
single change, a previously failing card initialized through multiple cold
boots and completed VGM playback of a 120 KiB song, exercising sustained
multi-block reads. This is strong preliminary evidence, not yet a completed
soak test. If this failure is revisited, preserve the selected trailing byte
before changing initialization commands, retry counts, or the `CMD55`/
`ACMD41` boundary.

### V9958 R#8 `VR` must be 1 on 64K×4 DRAM

The reset value of `00h` selects 16K-DRAM addressing. On the production
LunchCrema hardware that aliased `00000h` and `08000h`, so later bitmap rows
overwrote earlier ones. Diagnostic signature: `exp=12 act=56 @0123` after
writing `56h` at `08123h`.

### CTC channels are not proven until proven individually

CTC0 at port `40h` in timer mode, `/256`, automatic trigger, constant 217
produces stable IM2 interrupts and is the verified application time source.
CTC1 and CTC2 did not yield usable playback interrupts during VGM bring-up —
recorded as an **unresolved observation, not a defect**. Before using them,
verify vector, daisy-chain acknowledgement, control word and board routing with
a counter-only ISR.

The same bring-up showed a compact ISR coexists fine with the SIO console and
foreground SD streaming, while moving stream decoding, PSG writes and BDOS reads
*into* the ISR caused instability. Keep ISRs small; do the work in foreground.

---

## 3. Toolchain: XC8 on the PIC18

The compiler is a first-class source of defects in this firmware, not a
neutral tool. `Code/MCU/IOController/docs/XC8-PATCHES.md` is the authority.

### The call graph is unanalysable, and that has consequences

TinyUSB's function-pointer driver tables make the call graph look recursive.
XC8 reports `warning (1393) possible hardware stack overflow detected;
estimated stack depth: unknown (due to recursion)` and then allocates
overlaid local storage from liveness information that is not sound.

Six silent corruptions in the USB path are traced to this. `STVREN = ON` is set
deliberately so that a hardware call-stack overflow resets the device instead of
corrupting a return address — turning an unprovable property into a visible
failure. Since the controller drives the host reset pair, that failure presents
as **the whole machine rebooting continuously with nothing on the console**.

### Never return a pointer that may address either RAM or program memory

`const` lives in program memory on PIC18, so:

```c
static const uint8_t blank_name[11] = { ' ', ... };
const uint8_t *vol_name(uint8_t unit)
{ return (unit < VOL_UNITS) ? units[unit].name : blank_name; }
```

returns a pointer whose target address space is not known until run time. This
function — **never called** — reset-looped the machine from the moment it was
linked. Replacing the accessor set with one function that fills a
caller-supplied byte array fixed it.

Constructs that merely ask something unusual of the compiler are unsafe here
even when unreachable.

### Bisecting a fault in code that never runs

The technique that eventually worked, and is worth reusing:

1. Put the suspect code behind a `-D` flag in `dispatch.c` so the **linker
   strips it**, and confirm the stripped build boots.
2. Add back **one construct per build**.
3. Compare `Program space` and `Data space` between builds. **If a smaller
   build fails, stop thinking about size** — that single control killed several
   plausible theories at once.
4. Keep a known-good hex to reflash between experiments.

Also worth building: a *control* that changes size without changing code. Adding
36 KB of inert `const` to a working firmware proved image size was irrelevant.

### Period toolchains fail in ways that name nothing

Bringing ZCPR2 and ZSDOS into the ROM meant running 1980s CP/M assemblers under
an emulator, and every failure was silent or misdirected:

- **A CRLF slip reports as `INPUT LINE TOO LONG`.** Three lines edited into a
  config file with `\n` instead of `\r\n` made ZMAC see the whole file as one
  line. The error named neither the file nor the line number. Both build
  scripts now check line endings before assembling.
- **DRI's `LINK.COM` prints `ABORTED` and nothing else** on `ZMAC` output —
  bare, with no options, no diagnostic. Microsoft's `L80` reads the identical
  `.REL` fine. The DRI linker is kept vendored purely to record that it does not
  work here.
- **The emulator does not exit when its input ends**, so a build that "hangs"
  may have finished correctly minutes earlier. Twice I let a timeout expire
  before checking, and both times the output files were already sitting there.
  **Judge these builds by their artefacts, not by process exit.** The scripts
  now watch for the assembler's completion line and stop on it — 1.8 seconds
  instead of two minutes.

The general rule: when driving a tool that predates useful error reporting,
build the check into the harness, because the tool will not tell you.

### Zephyr-80 is a textbook 56K CP/M, and that keeps paying

`CBASE=C400h`, `FBASE=CC06h`, `CBIOS_BASE=DA00h` are exactly what the standard
formulas produce:

```
CPRLOC = 3400H + (MSIZE-20-BIOSEX)*1024     ; MSIZE=56, BIOSEX=0  -> C400h
BIOS   = CPRLOC + 800H + 0E00H              ;                     -> DA00h
```

Both ZCPR2's `Z2HDR.LIB` and ZSDOS's `zsdos.lib` compute their addresses that
way, so each needed **one or two equates changed and nothing else**. Period
software drops onto this machine without adjustment, and that is worth
preserving the next time the memory map is tempted to move.

### `make` can succeed and build nothing — twice, by two mechanisms

This has now happened in the same makefile two different ways, and both times
the tell was a stale `build/` that looked like success.

**1. The default goal.** `check-xc8-patches` was the first real target, and GNU
make takes the first real target as the default goal. A bare `make` ran the
patch check, printed OK, exited 0 and built nothing. Fixed with
`.DEFAULT_GOAL := all`.

**2. An empty variable at the start of a recipe line.** The compile recipe
begins with `$(XC8)`. When an over-broad edit deleted the `XC8_DIR` / `XC8` /
`DFP` definitions, that line began with `-mcpu=...` — and **GNU make strips a
leading `-` from a recipe line as its ignore-errors modifier.** Make ran
`mcpu=PIC18F57Q84` as a command, the shell reported "not found", make reported
`(ignored)`, and the build exited 0 with no hex produced. The breakage survived
a commit because of it.

Fixed with an explicit guard, and the guard was verified to fire:

```make
ifeq ($(strip $(XC8)),)
$(error XC8 is empty -- the compiler variable was lost.  See XC8_DIR above.)
endif
```

The general rule: **a build system that can exit 0 without producing its output
will eventually do so at the worst moment.** Prefer a loud `$(error)` over
trusting that a variable is set.

---

## 4. Transport and protocol

### Adding a command takes three edits

`ioc_frame.h`, `dispatch.c`, **and** `is_command_class()` in `external_sync.c`.

That last one is a receiver-side validation whitelist. An unlisted class is
dropped *silently*, because `service_command_request()` sends no reply when the
receive fails — so the host reports `IOC_XPORT_TIMEOUT_REPLY_MARKER`, which
reads as a dead controller, rather than `RSP_UNKNOWN_COMMAND`, which would name
the problem in one line.

### Persistent sync means receiver state persists too

The SIO's last shifted character is not necessarily visible in the CPU-readable
FIFO when its eighth clock arrives; further clocks advance the internal
pipeline. The MCU therefore clocks one `FFh` after the CRC so the host can read
a complete packet — which leaves that trailer as the newest internal character,
free to become the *first* FIFO byte of the next transfer.

The trailer cannot simply be removed (it can hide the CRC low byte), and the
receiver cannot be reset to clear it (receiver disable is one of the events that
destroys External Sync character assembly). The answer was to make the Bulk lane
scan for the `A5 5A` marker like the command lane already did, instead of
assuming FIFO byte zero is payload byte zero.

**Both lanes now validate identically.** The last structural difference between
the receive paths was exactly where the bug lived.

### Distinguish the failure stages in the status byte

`IOC_XPORT_TIMEOUT_REPLY_MARKER` (`11h`) versus `IOC_XPORT_TIMEOUT_REPLY_BODY`
(`12h`) carry "the reply never came" versus "the reply began, then stalled".
That distinction made a whole diagnostic field redundant and deletable. Bulk
rejection reasons `01h`–`07h` name the stage that rejected a frame.

Precision in a status byte removes the need for a diagnostic buffer later.

### A status query must not change state

`CMD_VOL_INFO` originally called `vol_ensure_mounted()`. That can run
`sd_card_init()` — about a second of ACMD41 polling at 125 kHz, well past the
host's IOCALL timeout — and, when the card session has been lost, it calls
`vol_init()`, which discards every mount. **Asking what was mounted could
unmount it.**

### Long operations must drop `COMMAND_READY`

The host gates every IOCALL on that line. The SD cache flush already lowered it
around a long write; the auto-mount did not, so a request arriving mid-mount
waited past the host's timeout. The Z80 holds `/SIO1B_INT` until acknowledged,
so a request is *delayed* rather than lost — lowering the line only tells the
host the truth about when to bother asking.

---

## 5. Process

### Gates exist because the alternative is a bricked machine

The FAT32 design document specified a phased sequence, each phase ending
somewhere shippable, with an explicit gate: *"selftest mounts a real card;
`IOC_SDREC`, `IOC_SDBLK` and the HID path still pass unchanged."* All three
phases were implemented and flashed together, skipping every gate. The machine
reset-looped and stayed unusable across a dozen build-and-flash cycles.

The document's own risk section had named the mechanism in advance —
*"Adding 7,000 lines of new code to that allocator is not free"* — and its
proposed mitigation was precisely the gate that was skipped.

### Build-time guards beat review

Two defects nobody was looking for were found during the realignment: nine bytes
of diagnostic with no writer, and a record layout mirror that had silently
drifted from the BIOS. Both now have guards — `check_diag_record.py` and
`check_xc8_patches.sh` — and **each was verified to fail when the fault is
reintroduced.** A guard that has never been seen to fail is not a guard.

### Cross-project ordering is a real dependency

`W6 before W7`: if a controller handler is removed while its `.COM` is still on
the rescue disk, the tool fails in a way that looks like a transport fault.
Retire the caller before the callee.

### Destructive tools do not belong on a rescue disk

`SDWRITE`, `SDREC`, `SDSOAK` and `SDBENCH` act on whatever card is inserted,
with no drive letter to get wrong. They have no business on the disk you reach
for when the machine is already in trouble. The ROM manifest has `normal` and
`diagnostic` profiles for exactly this; nothing is deleted, and every tool still
builds.

### Stamp historical documents at the top

Several planning documents were still being read as current long after the tree
moved. They now carry a `HISTORICAL` banner naming what has changed and pointing
at the authority. `io_controller_bios_readiness.md`,
`phase0-storage-restoration.md` and `optimization_report.md` are the examples
worth copying.

**A superseded document that does not say so is a trap, not an archive.**

### Recovery infrastructure earns its place

After three separate builds reset-looped the machine into programmer-only
recovery, `boot_guard.c` was added: a `__persistent` counter that survives
reset, and after three consecutive boots that fail to stay up for two seconds,
the firmware comes up **degraded** — skipping the risky path so the machine
boots and can be interrogated. A power cycle clears it; so does staying up.

Turning "bricked" into "boots and tells you why" is worth ~40 lines.

---

## 6. What went right

Worth recording, because a lessons-learned document that only lists failures
misrepresents the project.

- **The two-lane transport design held.** `protocol-gap-analysis.md` compares
  the original proposal against what shipped line by line; the deviations are
  all deliberate compatibility choices, and the framing model needed no rework.
- **The record-addressed storage model was the right layer.** The BIOS asks for
  a 128-byte record and gets one; deblocking, LRU and write policy live on the
  PIC where SRAM is plentiful and firmware is easy to change. The Z80 side never
  learned the card has blocks.
- **Vendoring TinyUSB as a submodule with a single patch commit.** The complete
  patch set is one `git diff` away and a refresh is a rebase, not a
  re-derivation. Compare with a copied tree, where the same 63 hunks would be
  unrecoverable.
- **Explicit invariants in header comments.** The write-through rule, the
  "nothing may write a mounted image through the filesystem" rule, and the SD
  belt-and-braces table each survived contact with a later change *because they
  said why, not just what.*
- **Splitting boot-critical code from convenience code.** Image resolution runs
  on 500 verifiable lines (`fatmap.c`) while FatFs serves user space, so a fault
  in the large library costs a transient rather than the machine's ability to
  boot.
- **The failure record at a fixed address.** A `.COM` can read it with
  `ld a,(nnnn)` and report it with no working transport — which is the only
  moment it matters.

---

## 7. Still open

| Item | State |
|---|---|
| INDMEM SD cards fail ACMD41 startup | Selected trailing byte fixes cold boots and a 120 KiB VGM read; extended soak testing pending |
| `CONSOLE=vdrip STORAGE_A=vdrip` | Deliberately left failing — 22 bytes over driver slot 5 |
| CTC1 / CTC2 interrupts | Unresolved observation from VGM bring-up; not proven defective |
| `/USB_INT` input threshold at RA0 | Never checked; would present as "enumeration never starts" |
| `/SHARED/` folder tools | Built and on A:, never exercised on hardware |
| `CMD_VOL_MOUNT` timeout | Can outrun the BIOS IOCALL timeout on a slow card |
| Hardware call-stack depth | Unbounded by the toolchain; `STVREN` makes overflow visible, not impossible |

---

## 8. Source documents

**IO Controller** — `Code/MCU/IOController/docs/`

| Document | What it is |
|---|---|
| `max3421-bring-up-debug.md` | The full USB bring-up log, including a "Ruled Out — Do Not Re-Investigate" table and a bisection guide |
| `XC8-PATCHES.md` | Which TinyUSB edits are compiler workarounds and which are instrumentation |
| `ping-two-bit-drift-root-cause.md` | The gated-clock idle-level fault |
| `bulk-persistent-sync-pipeline-root-cause.md` | The stale SIO FIFO trailer |
| `sd-card-acmd41-startup-failure.md` | Card-family startup failure, evidence and remediation phases |
| `two-lane-transport.md` | **Authoritative** transport contract |
| `external_sync_protocol.md` | SIO rules, sync establishment, packet and CRC |
| `protocol-gap-analysis.md` | Proposed versus shipped, with reasons |
| `pinout.md` | Port map and board-level constraints |
| `debug-test-code-review.md` | What belongs in normal versus diagnostic firmware |

**CP/M BIOS** — `Code/HOST/CPM2.2/docs/`

| Document | What it is |
|---|---|
| `memory-map.md`, `symbol-map.md` | **Generated from the build** — the authority on layout and free space |
| `bios-realignment-plan.md` | The instrumentation cleanup, its outcome, and the four load-bearing "diagnostics" |
| `ioc-diagnostic-record.md` | The fixed-address failure record and why its field order is load-bearing |
| `ioc-fat32-images-and-shared-fs.md` | The FAT32 design, the eleven-build bisect, and the correction |
| `ctc-and-real-time-programming.md` | CTC, IM2 under CP/M, the 60 Hz budget |
| `lunchcrema-v9958-console-bringup.md` | Non-negotiable V9958 register settings |
| `serial-console-fallback.md` | The recovery console on SIO0/B |
| `zephyr80_bios_walkthrough.md` | BIOS structure |
| `debug-test-code-review.md` | Resident BIOS and utility inventory |
| `io_controller_bios_readiness.md`, `phase0-storage-restoration.md`, `optimization_report.md` | **HISTORICAL** — kept for reasoning, superseded on numbers |
