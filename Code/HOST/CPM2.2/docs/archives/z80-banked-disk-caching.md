# Z80-side banked disk cache

Status: proposed design; no BIOS or utility code has been changed. Timing figures
are derived from documented clock rates, protocol pacing constants and Z80
instruction timings, not measured on hardware — every one of them should be
confirmed with `IOC_SDBENCH.COM` before the design is trusted.

The idea, as on John Winans' Z80 Retro!: spend the otherwise-idle SRAM banks on a
disk cache, sized at runtime by a transient (`SETCACHE.COM 0-6`, 0 meaning no
cache).

## Executive summary

| | Value |
|---|---|
| Free SRAM | Banks 2-7, 48 KiB each = **288 KiB** |
| Recommended cache unit | **512-byte block**, not 128-byte record and not a file |
| Expected warm speedup | **about 4x** per record (≈2.1 ms → ≈0.5 ms) |
| Expected cold sequential speedup | about 1.5x, from the read-ahead a 512-byte line gives free |
| Expected write speedup, if write-back | **about 9x** (~4.7 ms -> ~0.5 ms) |
| Write policy | **Write-through in v1**, write-back as a planned phase |
| Resident BIOS cost | ~350-450 bytes of code, ~272 bytes of common RAM |
| Resident BIOS space available today | **about 215 bytes** |

The last two rows are the finding that matters. The design is sound and the RAM
is genuinely free, but **the resident BIOS does not currently have room for it.**
The cleanup already proposed in `docs/debug-test-code-review.md` is the
dependency: it estimates 100-180 bytes recoverable from IOC trace blocks, which
together with the 194-byte gap at F9B2h is enough and not much more than enough.

The second finding worth stating up front: **the Z80's own memory copy, not the
link, becomes the bottleneck.** A cache hit still costs two 128-byte cross-bank
copies, and that is roughly a quarter of what the record fetch costs today. So
288 KiB of cache buys about 4x, not 50x. That is still a very good return for
memory that is doing nothing, but it is worth knowing before the work starts.

## What is actually free

From `Memory Management.md` and the decoder equations:

- 512 KiB SRAM as eight 64 KiB banks, latch on port `00h`, bits D0-D2.
- In RAM-only mode (`D4=1`), `0000h-BFFFh` follows the selected bank and
  `C000h-FFFFh` is forced to bank 0. So each bank contributes a **48 KiB banked
  window**, and the top 16 KiB is common.
- `src/cbios_storage_ramdisk.asm` already declares banks 2-7 as available
  (`RAMDISK_FIRST_BANK = 2`, `RAMDISK_LAST_BANK = 7`, 6 banks × 48 KiB =
  294,912 bytes) and is retained but not linked in the current build.

Two caveats on "free":

- `src/boot_shadow_copy.asm` copies pages/banks 1 through 7 at cold boot, so the
  banks contain stale ROM-page content rather than zeroes. The cache must
  explicitly invalidate every tag at init and must never infer validity from
  content. (Separately: that copy pass into banks 2-7 now serves no reader, and
  skipping it would shorten cold boot. Out of scope here, worth noting.)
- The RAM disk backend claims the same banks. Exactly one of the two can be
  linked. `SETCACHE` needs to know which build it is in, or the two need to
  negotiate.

The BIOS executes from the common window, which has a useful consequence used
below: **a cache bank can be selected while BIOS code, its stack and `IOCBULK`
all keep running**, because all of them live above C000h.

## Why 512-byte blocks

The question was "block, record or file, whichever suits the OS". The answer is
the 512-byte block, for four reasons:

1. **A miss is exactly one `CMD_SD_READ_BULK`**, which the controller already
   implements. No IOC firmware change is needed for the read path at all.
2. **Free read-ahead.** One fill covers four consecutive CP/M records, so a
   sequential scan misses once per four records instead of every record. That is
   where most of the cold-path win comes from.
3. Record granularity (128 B) would need four times the tags and four times the
   round trips for the same coverage.
4. File-level caching is the wrong layer. The BIOS never sees files, only
   records; caching files would mean changing the BDOS, which is stock CP/M and
   should not be touched.

The block number is `record >> 2`, the same quantity the controller's `sd_cache`
already uses as its LBA, so the two tiers agree on addressing by construction.

## Timing

Sources: Z80 at 10.000 MHz (`Clock Architecture.md`, CPU-board Y1, no runtime
switching); command lane paced at `EXTSYNC_TARGET_BYTE_US = 16` µs/byte; bulk
lane MCU→Z80 at `BULK_TARGET_BYTE_US = 6` µs/byte plus
`BULK_ADMISSION_GUARD_US = 100` µs; `LDIR` at 21 T-states per byte, unrolled
`LDI` at 16.

### Cost of a hit

A hit is two 128-byte copies, because the cache line and the CP/M DMA buffer are
both in the banked window and cannot be visible at the same time. The staging
point is `MOVE_BUFFER` in common RAM.

| Step | T-states | At 10 MHz |
|---|---:|---:|
| Group-table lookup, bank switch, tag compare | ~120 | 12 µs |
| Copy line → `MOVE_BUFFER` (`LDIR`) | 2,683 | 268 µs |
| Copy `MOVE_BUFFER` → DMA (`LDIR`) | 2,683 | 268 µs |
| Call overhead, bank restore | ~200 | 20 µs |
| **Total** | **~5,700** | **~570 µs** |

Replacing both `LDIR`s with unrolled `LDI` blocks costs about 32 bytes of code
each and brings the total to roughly **440 µs**. Worth doing if the bytes exist.

### Cost of a miss, and of today's path

| Path | Cost |
|---|---:|
| Today, one record, IOC cache hit | ~1.8 ms |
| Today, one record, IOC cache miss | ~3.2 ms |
| Today, four sequential records | ~8.5 ms |
| Proposed, 512-byte line fill (4 records) | ~3.8 ms |
| Proposed, four sequential records, cold | ~5.8 ms |
| Proposed, four sequential records, warm | ~2.0 ms |

Working: a record read today is a 12-byte request plus a 16-byte READY on the
command lane (28 × 16 µs = 448 µs), then 137 bulk bytes at 6 µs plus the 100 µs
admission guard (922 µs), plus `sd_zero_frames` (~134 µs), plus one cross-bank
DMA copy (~268 µs), plus the `/SIO1B_INT` handshake, `COMMAND_READY` polling and
PIC dispatch. A 512-byte fill replaces the 137 bulk bytes with 521, so it costs
about 3.8 ms and yields four records instead of one.

### What that means

- Warm, per record: **2.1 ms → 0.5 ms, about 4x.**
- Cold sequential, per four records: 8.5 ms → 5.8 ms, about 1.5x.
- **A purely random single-record read gets slower**, because the miss now fetches
  512 bytes instead of 128. This is worth stating plainly. It does not matter much
  in practice — CP/M's BDOS reads directory entries sequentially and file records
  sequentially — but it is a real regression on a genuinely random access.

Two workloads for scale, assuming the 16 KiB directory and a 24 KiB transient:

| Workload | Today | Cold cache | Warm cache |
|---|---:|---:|---:|
| Directory scan (128 records) | 269 ms | 150 ms | 64 ms |
| Load a 24 KiB `.COM` (192 records) | 403 ms | 225 ms | 96 ms |

### The secondary win

`Two SIOs couple via the interrupt mask`: IOC bulk transfers disable interrupts
for milliseconds and can overrun the console SIO0 FIFO, which is why the fault
only appears when A: and B: are alternated. A warm Z80-side cache removes roughly
three quarters of the IOC bulk traffic on read-dominated workloads, and with it
three quarters of the windows in which interrupts are off. That is a reliability
improvement, not just a speed one, and it may be the more valuable half.

## Mapping scheme

The constraint that shapes everything: **there is nowhere near enough common RAM
for a tag array.** Six banks of 128-byte records would be 2,304 tags; even
512-byte lines across the full 288 KiB would be 576 tags. The free common scratch
is 256 bytes at FD00h-FDFFh.

The scheme that fits, with no division anywhere on the hot path:

- **Line = 512 bytes. 64 lines per bank**, occupying `0000h-7FFFh` of each cache
  bank (32 KiB of the 48 KiB window).
- `line = block & 63` — a mask.
- `bank = grouptab[block >> 6]` — one lookup in a **256-byte table in common RAM
  at FD00h**, rebuilt by `SETCACHE` whenever the bank count changes. For an 8 MiB
  volume `block` is 0-16,383, so `block >> 6` is 0-255 and the table is exactly
  256 entries. This is the whole trick: it replaces a modulo-by-*n* with a byte
  read, and it is the reason 0-6 banks can be supported rather than only powers
  of two.
- **Tags live in the bank they describe**, at `8000h`: 64 entries × 2 bytes =
  128 bytes. Tag is `[block >> 6, flags]`, one byte each, because `block >> 6`
  fits in a byte. `flags` carries valid and, once more than one image can be
  mounted, the unit.
- Offset within the line is `(record & 3) << 7`.

Total usable cache is 6 × 32 KiB = **192 KiB**, or 2.3% of an 8 MiB volume. The
remaining 16 KiB per bank holds the 128-byte tag array and is otherwise spare.

Two notes on that:

- **The 96 KiB left over is not wasted so much as unclaimed.** The obvious use is
  to pin the CP/M directory: it is 16 KiB (AL0 = F0h, BLS = 4096, blocks 0-31),
  it is by far the hottest region, and pinning it needs no tag lookup at all —
  `block < 32` is the whole test. That is a cheap phase-two addition with a
  disproportionate effect, since BDOS re-reads the directory on essentially every
  file operation.
- Using the full 48 KiB per bank (96 lines, 288 KiB) is possible but needs a
  512-entry group table, which no longer fits in common RAM and would have to be
  read from a bank — one extra bank switch, about 11 T-states. Affordable, but the
  extra 96 KiB moves coverage from 2.3% to 3.5%, which is unlikely to change any
  hit rate that matters. Not recommended for a first version.

Direct-mapped conflicts land 384 blocks (192 KiB) apart, which for this volume
and these workloads is not a pattern CP/M produces.

**This scheme depends on the volume being exactly 8 MiB**, which is what makes
`block >> 6` a single byte. If volumes ever grow, the group table grows past 256
entries and has to move into a bank. Worth a comment in the source rather than a
surprise later.

## Write policy

Writes are the expensive direction, so this section decides more of the payoff
than the read path does.

| Operation | Cost today |
|---|---:|
| Read one record | ~1.8 ms |
| **Write one record** | **~4.7 ms** |

A write costs 2.6x a read for two reasons, both in the transport rather than the
card. The bulk lane is paced at `BULK_RX_TARGET_BYTE_US = 24` µs/byte inbound
against `BULK_TARGET_BYTE_US = 6` outbound — four times slower toward the
controller — and a write additionally takes the mandatory `CMD_XFER_STATUS`/DONE
round trip that a read skips. Working: 268 µs DMA copy, 134 µs frame clear,
448 µs command and READY, 100 µs admission guard plus 137 bulk bytes at 24 µs
(3,388 µs), and 448 µs for the DONE exchange.

So write-back is the larger prize: **~4.7 ms to ~0.5 ms, roughly 9x**, against 4x
for reads.

### Why writes are paced four times slower, and what that implies

The asymmetry is not loop speed. The host's `INI` read loop and its `OUTI`
transmit loop both cost 56 T-states, 5.6 µs at 10 MHz. It is the buffering and
the failure mode that differ, and the reasoning is recorded in
`Code/MCU/IOController/src/bulk_channel.c`.

The PIC is clock master in both directions and does not wait.

- **Reading (6 µs/byte).** If the PIC clocks early the host has simply not seen
  the byte yet and polls again, and the SIO's three-byte RX FIFO absorbs about
  18 µs of jitter on top. Being too fast costs nothing.
- **Writing (24 µs/byte).** The host must feed its transmitter, and the SIO
  transmit path holds only about two byte-times. If the PIC out-clocks the refill
  loop the transmitter under-runs and streams its WR7 fill character, which on
  this channel is 00h. The PIC then captures a well-formed block of zeros: the
  preamble search succeeds, the CRC matches over the zeros, and the block is
  committed to the card. The failure is silent and looks exactly like a
  successful write. Separately, once the Tx Underrun latch sets the transmitter
  stops consuming the buffer, so TBE never re-asserts and the host times out.

24 µs rather than 12 is empirical: 12 left 6.4 µs of slack, less than the 117
T-states (11.7 µs) of a CTC ISR, and under CTC load at 1 ms roughly 65% of writes
failed. 24 µs leaves 18.4 µs, more than one interrupt.

**Two consequences for this design.**

First, `IOCBULKW` now runs the whole transfer with interrupts disabled — `di` at
`src/cbios_ioc_command.asm:1279`, `ei` at 1475, commented "the MCU is clock master
and does not wait, so a stall here is lost data rather than latency." The ISR
that 24 µs was sized against can no longer land inside a transfer. Whether the
`di` post-dates that measurement or is deliberate belt-and-suspenders is not
recorded. This is worth re-measuring, because 24 µs × 512 bytes is **12.3 ms of
interrupts-off per block**, and that window is precisely the SIO0 console
coupling: while it is open the VDrip driver's RTS watermark logic cannot run, so
the console cannot apply backpressure. Halving the pacing would halve the window.

Do not simply change it. The failure mode is silent zeros written to the card,
which is the worst class of fault this machine has. The experiment is to
instrument the Tx Underrun latch, soak writes at 12 µs under real console load,
and confirm the `di` actually closes the hole rather than assuming it does
because the interrupt is masked.

Second, and directly relevant here: **write-back clusters these windows.** A
batch flush at WBOOT becomes a run of back-to-back 12.3 ms interrupts-off
periods, which is the worst possible pattern for that coupling. Prefer dripping
one dirty line per `CONST` poll — the console status call the CCP polls
continuously — so the windows stay spread out, which is what the controller
already does with its own 100 ms flush timer.

### Recommendation: write-through first, write-back as a planned phase

**Not** because write-back is unsound. Because write-through is the smallest
change that proves the mapping, the cross-bank copy and the fill-into-bank path,
and it costs nothing against today's write speed — a CP/M write goes to the
controller exactly as it does now and additionally updates the cached line if one
is present. `SETCACHE` then cannot lose data under any circumstance, which is
what makes it safe to hand to a user as a runtime knob.

### What write-back actually risks, stated accurately

`sd_cache` on the controller is *already* write-back, with a 100 ms flush timer
and an address rule that commits the directory head synchronously. A CP/M write
is therefore already not durable at the moment BDOS believes it is. A Z80-side
tier **extends that window rather than introducing a new class of failure**, which
is a weaker claim than it first appears.

The one place the two tiers genuinely differ is **clean shutdown**. The PMU
asserts `/SHUTDOWN_RQ`, the PIC notices it on an idle main-loop pass, drops
`COMMAND_READY`, flushes `sd_cache` and cuts the rails. The PIC cannot reach into
Z80 SRAM banks, so a Z80 dirty tier would be lost on the normal way of turning
the machine off — not on an edge case.

That is fixable, in three steps of increasing cost:

1. **Honour BDOS's write type.** CP/M passes `C = 1` for a directory write; the
   current SD backend deliberately ignores `C` and leaves the policy to the
   controller's address rule. Write through on `C = 1` and write back otherwise.
   Losing a data block costs one file's contents; losing a directory write costs
   the volume. This one line removes most of the possible damage.
2. **Flush on WBOOT.** Every transient exits through it, so the dirty window is
   bounded to a single program's run. The invalidate-on-WBOOT pass the coherency
   section already requires becomes a flush-then-invalidate pass.
3. **An in-band shutdown handshake, on the poll that already exists.** The
   controller already has a Z80 conversation running at all times: `CONST` calls
   `hid_input_poll`, which issues `CMD_HID_INPUT` through `IOCALL` on an adaptive
   backoff (`HID_BACKOFF_MIN` 1, `HID_BACKOFF_MAX` 64). At an idle CCP prompt
   `CONST` spins thousands of times a second, so the controller is asked
   sub-millisecond; during console output it is asked once per 64 characters.

   So the PIC does not need to interrupt the Z80 at all. On `/SHUTDOWN_RQ` it can
   set a "shutdown pending" flag in the reply to whatever command is asked next,
   start a bounded timer, and wait. The BIOS sees the flag on its next poll,
   drains dirty lines through the ordinary write path, and answers with
   `CMD_SD_FLUSH` — a command that already exists. The PIC then flushes its own
   cache and cuts the rails, or does so anyway when the timer expires, so a wedged
   or cache-less Z80 cannot prevent a shutdown. The PMU's one-second grace period
   is the budget, and it is ample against a sub-millisecond poll.

   The one gap is a program that computes for a long time without calling
   `CONST`. It is small: such a program is not writing to disk either, so the
   dirty set is whatever it left behind before it started, and the grace period
   still covers a flush once it next prints anything.

   **Not NMI.** The Z80's NMI vector is fixed at 0066h, and on CP/M that address
   is inside the default FCB — 0066h is `005Ch + 10`, the second byte of the
   file-type field, and a three-byte `JP` there also takes `t3` and `ex`. The
   handler has to be *resident* to be reachable, so the tempting argument that
   corrupting it is harmless because the machine is powering off anyway does not
   work: the damage is done for the whole session, not at shutdown. 0066h is also
   in the banked window (0000h-BFFFh), so a handler would have to be replicated
   in every bank. NMI is the wrong instrument here; the polled path costs nothing
   and conflicts with nothing.

With steps 1 and 2 the exposure is a power cut or a crash *mid-run*, losing data
blocks but never the directory. That is the bargain every disk cache makes, and
on a hobby machine with a PMU that already defers writes it is defensible. Step 3
closes the clean-shutdown case entirely and is the point at which write-back
becomes strictly better than today rather than a trade.

`SETCACHE` should not be the control for this. Keep the size number and the write
policy as separate settings, so a user can size the cache without also choosing a
durability model.

## Coherency


Anything that writes the volume without going through the BIOS storage driver
makes the cache stale. On this machine that is a real and present category, not a
hypothetical: `IOC_SDFMT.COM`, `IOC_SDREC.COM`, `IOC_SDWRITE.COM` and the rest of
the `ioc_sd*` family address the controller directly through `IOCALL`, precisely
so they work when the driver cannot be trusted.

The cheap and complete answer is to **invalidate the whole cache on warm boot**.
Every transient exits to the CCP through WBOOT, so any diagnostic that scribbled
the volume is followed by an invalidate before CP/M reads anything again. It costs
one pass clearing 384 valid flags — six bank switches and six 64-byte clears,
well under a millisecond — on a path that already reloads the CCP.

Invalidate on:

- `SETCACHE` changing the bank count (via the generation check below);
- WBOOT;
- `CMD_VOL_MOUNT`, once images are mountable — a remount changes what the tags
  mean.

## SETCACHE.COM

The BIOS extension vector run at DA00h-DB78h is documented as having been
"exactly full" once already: adding `IOCBULKW` at `ZBIOS_EXT_BASE + 15h` required
shifting the console, storage and banking bases up three bytes, absorbed out of
banking's slack. Appending a `CACHECTL` vector would repeat that exercise.

**Recommended instead: no new vector.** Put a small control block in the common
scratch area — bank count, a generation counter, and hit/miss statistics — and
have `SETCACHE.COM` write it directly. The storage read path compares the
generation on entry and re-initialises (clear tags, rebuild the group table) when
it has changed. That costs about 15 T-states on the hot path and zero bytes of
ABI.

```text
  FD00h-FDFFh   group table, 256 entries, rebuilt on generation change
  (control)     banks (0-6), generation, first bank, hits, misses
```

The control bytes fit in the free runtime-state holes at FE08h-FE1Fh (24 bytes)
or FE2Dh-FE3Fh (19 bytes). `SETCACHE.COM` with no argument prints the current
size and the hit/miss counters, which is what makes the knob worth having: it
turns a guess into a measurement.

The objection is that a stray program can corrupt the control block. True, but
CP/M has no protection anywhere and FD00h is documented BIOS scratch; the same
argument applies to `MOVE_BUFFER`. If a clean ABI is preferred later, appending
`CACHECTL` at `ZBIOS_EXT_BASE + 18h` remains available at the cost of another
three-byte shift.

## Space budget — the blocking issue

Genuine free *code* space in the resident BIOS today, computed from
`build/firmware.ihx` (gaps that are really uninitialised RAM buffers or stack are
excluded):

| Range | Size | Note |
|---|---:|---|
| DCD1h-DCDCh | 12 | inside the IOC diag area |
| DD07h-DD0Fh | 9 | before the SIO core |
| F9B2h-FA73h | 194 | slot 5, between the storage backend and the probe result store |
| **Total** | **215** | |

Free *data* scratch: FD00h-FDFFh (256 bytes, unallocated), plus 43 bytes in the
runtime-state holes.

Estimated need:

| Item | Bytes |
|---|---:|
| Lookup, tag compare, hit copy | ~120 |
| Miss fill (issue `CMD_SD_READ_BULK`, receive into bank, copy out) | ~120 |
| Write-through line update | ~50 |
| Invalidate-all, generation check, group-table rebuild | ~90 |
| Unrolled `LDI` blocks (optional, buys ~130 µs/hit) | ~64 |
| **Total** | **~380-450** |

**Short by roughly 165-235 bytes.** The stated source is
`docs/debug-test-code-review.md`, which estimates 100-180 bytes recoverable from
the command-lane failure snapshot and the bulk rejection diagnostics, plus more
from the SIO interrupt counter. That review is a proposed plan with nothing
removed yet, so it is a prerequisite for this work, not a parallel track.

If the cleanup lands short, the fallback is to drop the unrolled `LDI` blocks
(−64 bytes, +130 µs per hit) and the statistics counters, and to place the fill
path in the 194-byte slot-5 gap with the hot lookup in core BIOS.

### One thing that costs nothing

The miss path needs a 512-byte landing area, and there is no 512-byte buffer in
common RAM — `MOVE_BUFFER` is 192 bytes. It does not need one: because the BIOS
runs from the common window, `IOCBULK` can be pointed straight at the cache line
inside the selected bank. Select the bank, call `IOCBULK` with HL in `0000h-7FFFh`,
restore. The transport's own code, stack and state are all above C000h and are
unaffected by the bank switch. This is the property that makes the whole design
fit; without it the fill would need a buffer that does not exist.

## Interaction with the FAT32 image work

`docs/ioc-fat32-images-and-shared-fs.md` proposes serving CP/M records out of a
named file, addressed by a unit number. Two consequences here, both cheap if
designed in now and awkward if retrofitted:

- The tag's `flags` byte must carry the unit, or a cache warmed against
  `CPM_1.DRV` will silently answer reads against `CPM_2.DRV`.
- `CMD_VOL_MOUNT` must invalidate the cache, for the same reason.

Neither costs measurable code. Both are the kind of thing that is obvious in
advance and extremely hard to diagnose afterwards.

## Suggested sequence

1. **Measure first.** Run `IOC_SDBENCH.COM` and time a directory scan and a
   transient load as they stand. Every number in this document is derived rather
   than observed; if the real per-record cost is not near 2 ms, the whole
   cost/benefit shifts and the design should be revisited before any BIOS byte is
   spent.
2. **Land the diagnostic cleanup** from `docs/debug-test-code-review.md`, far
   enough to free 200+ bytes. Confirm with `check_overlap.py` and a regenerated
   memory map.
3. **Read-only cache, one bank, fixed size.** No `SETCACHE`, no group table —
   bank 2 only, `bank = 2` constant. This proves the mapping, the cross-bank copy
   and the fill-into-bank trick with the least possible code.
   *Gate:* a warm directory scan is measurably faster and `IOC_SDREC.COM` still
   passes.
4. **Group table, 0-6 banks, `SETCACHE.COM`,** invalidate on WBOOT, hit/miss
   counters.
   *Gate:* `SETCACHE 0` is byte-for-byte the current behaviour; `SETCACHE 6`
   shows the expected hit rate on a repeated `DIR`.
5. **Write-back, staged.** Directory writes (`C = 1`) stay write-through;
   everything else defers; flush on WBOOT. Then the in-band shutdown handshake on
   the existing `CMD_HID_INPUT` poll, to close the clean-power-off case.
   *Gate:* pulling the plug mid-run loses file data but never leaves the volume
   unmountable; a normal PMU shutdown loses nothing.
6. **Optional: pin the directory** in the spare 16 KiB of the first cache bank.

## Open decisions

1. **Is the RAM disk backend ever coming back?** It owns the same banks. If it
   might, the two need a shared allocator or an explicit either/or at build time.
2. **192 KiB or 288 KiB?** The recommendation is 192 KiB for the simpler
   arithmetic. The extra 96 KiB is available at the cost of moving the group table
   into a bank; it moves volume coverage from 2.3% to 3.5%.
3. **Should `SETCACHE` persist?** Nothing on this machine stores settings across a
   cold boot today. A default in the BIOS with a runtime override is probably
   right; a persisted setting would need somewhere to live.
4. **How far to take write-back, and when?** Honouring BDOS's `C = 1` directory
   write type plus a flush on WBOOT is cheap and bounds the exposure to data
   blocks lost in a mid-run power cut. Closing the clean-shutdown case needs a
   shutdown-pending flag in the controller's replies and a flush response, which
   is a change at both ends but no new signalling. Writes cost 2.6x what reads
   do, so this is where most of the remaining performance lives — it should be
   scheduled, not deferred indefinitely.

## Related

- `docs/debug-test-code-review.md` — the source of the bytes this work needs.
- `docs/ioc-fat32-images-and-shared-fs.md` — the controller-side image and
  filesystem proposal, which this must not be designed in isolation from.
- `docs/memory-map.md` — the generated map the space budget above is taken from.
- `src/cbios_storage_ramdisk.asm` — the existing banked backend; it already
  proves the bank arithmetic and the cross-bank record copy.
- `Memory Management.md`, `Clock Architecture.md` — the hardware facts the timing
  rests on.
