# Zephyr-80 Utilities

The programs that are **part of the machine**, as opposed to programs that run
on it. Everything here speaks the IO Controller protocol, drives BIOS-owned
hardware, or exists to recover a machine that is misbehaving — so it is
versioned with the BIOS and the controller firmware, not with your software.

Programs that merely run on Zephyr-80 belong in `../Software`; demos,
experiments and bring-up sketches belong in `../HelloWorld`.

## Building

```sh
make              # every set
make normal       # just the ROM rescue set
make diagnostic   # just the diagnostics
make tools        # just the tools
make list         # show which is which
```

Output is `build/*.com`. `../CPM2.2` collects them from there when it builds the
ROM A: volume — it does not build them itself.

## Calling the operating system

The operating system runs from its own SRAM bank and publishes no fixed
addresses, so every tool reaches it through `CALL 5`. `src/zbdos.inc` provides
the Zephyr BDOS functions under the names tools already used:

| Name | Function | What |
|---|---:|---|
| `IOCALL` | 214 | IO Controller command/reply |
| `VIDEO_SEND` | 215 | video command stream |
| `IOCBULK`, `IOCBULKW` | 216, 217 | IO Controller bulk receive and transmit |
| `zb_move`, `zb_xmove`, `zb_selmem` | 210-212 | bank primitives; call `zb_selmem` from common memory only |
| `zb_xport_level` | 203 | `A` = the BIOS IO Controller transport level |
| `zb_diag_iy`, `zb_sercon_iy` | 203 | `IY` = the IOC link failure record, or the serial console flags byte |

Include it at the end of a program: it assembles code. Buffers passed to these
calls can be anywhere in the program's memory, because the BIOS copies them
through common memory. `IY` survives BDOS calls, so a tool can load it once.

A tool that needs a timer interrupt registers a CTC callback with BDOS function
200. The callback, and everything it touches, must be copied into
`E000h-E3FFh` first. `SDSOAK` is the worked example.

## The sets

**`normal`** is the ROM rescue disk: what you want present when the machine is
in trouble and A: is the only volume you can trust.

| | |
|---|---|
| `PING` | Version, transport, power and controller health. Non-destructive. |
| `RESET` | Resets host and controller together. |
| `SDREAD` | Command-lane SD read; separates controller/SD failure from CP/M filesystem failure. |
| `SDFMT` | **Destructive.** Provisioning — a fresh SD volume needs its directory initialised, and without this a new card cannot be made usable at all. |
| `HIDKEY` | Separates IOC key translation and queueing from BIOS `CONST`/`CONIN`. |
| `PADSTAT` | Passive USB/gamepad enumeration status. |
| `SERCON` | Arms or disarms the serial console tee — what you reach for when the screen is dark. |
| `NOWRAP` / `WRAPON` | Console line-wrap configuration. |
| `VOLINFO` | Which addressing mode each storage unit is really using: an image file on a FAT card, or the raw card. |
| `SDDIR` `SDGET` `SDPUT` `SDDEL` | The `/SHARED/` folder tools. With a FAT card in the socket, these are how a file gets off this machine or onto it when nothing else works. `SDGET` and `SDPUT` accept an ambiguous name (`SDGET *.MOD`) and copy every match. |

**`diagnostic`** is bring-up and benchmark work, and much of it is
**destructive**: `SDWRITE`, `SDREC`, `SDSOAK` and `SDBENCH` with no arguments act
on whatever card is inserted, with no drive letter to get wrong. The rest —
`BULK`, `SDBLK`, `RTSPROBE`, `DIAGCHK`, `V9958TST`, `HIDSTAT` and `SNDTEST` — are
non-destructive bring-up aids, as are `SDBENCH`'s two file modes. None of them
goes on the ROM disk: they have no business on the disk you reach for when the
machine is already in trouble. They always build; copy one to a work drive when
you need it.

The ROM disk also carries prebuilt Z-System tools from `zsys/`: `CD`, `PWD` and
`MKDIR` for named directories, `MCOPY`, `CRC` and `NSWP`. The ROM build installs
them for this machine as it stages them; the files here are the originals.

**`tools`** are everyday tools that drive machine hardware but are not rescue
tools. They are not on the ROM disk either; copy one to a work drive.

| | |
|---|---|
| `XFER` | X/Y/ZMODEM file transfer with the PC over the serial console port. |

## `SDBENCH`: what storage costs a program

```
SDBENCH [d:]TEST.DAT        BDOS sequential read of a CP/M file    READ ONLY
SDBENCH TEST.DAT /S         FS bulk read of /SHARED/TEST.DAT       READ ONLY
SDBENCH                     raw 512-byte card read and write      DESTRUCTIVE
  /N                        run without the counter: correctness, no timing
  /C  with /S               re-read a 2 KiB window so every pass after the
                            first is a controller cache hit
  /P  with /S               MCU physical-SD profile around the timed pass;
                            needs diagnostic firmware, like raw mode
  /H  with FILE             hit-only BDOS run through the BIOS deblock line;
                            forbids /S, /C and /P
```

The two file modes exist to answer one question: **what does a read cost the
program that makes it**, measured on the Z80, where the program experiences it.
That is the number a resource or streaming library has to be designed against,
and it is not the same number as the card's own speed.

Use a file of at least a few hundred KiB. Small files are measured through a
warm cache and a short run is mostly quantisation — see below.

### `/C`, `/P` and `/H`

`/C` applies to `/S` and selects the warm-revisit pass: the benchmark re-reads
one 2 KiB window of the file instead of the whole file, so after the first lap
the same four 512-byte sectors stay resident in the controller's eight-slot
cache and the card drops out of the measurement. The 2 KiB is the benchmark's
address window and nothing more — there is no special 2 KiB refill buffer
anywhere in the system.

`/P` requires `/S`; on any other command line it is a usage error. It resets
and baselines the controller's physical-SD profile around the timed pass and
reports physical read calls, ticks, derived time, average, and the cache
miss/retry/reinit deltas afterwards. It needs diagnostic controller firmware —
`handler_profile` is diagnostic-only — as the next section spells out.

`/H` requires a filename and plain BDOS mode, and is rejected together with
`/S`, `/C` or `/P`. It further requires B: to be the default drive, the file
to be on B: and at least 512 bytes, and a BIOS with SYSINFO version 2 or
later. It measures the cost of a BDOS sequential read guaranteed to hit the
host deblock line: 1024 laps × 4 records = 4096 fn-20 reads through the full
`CALL 5` path, rewinding the open FCB between laps, with zero MCU
transactions. It reports elapsed time, ms/record, and the deblock
hit/miss/IOCALL/IOCBULK deltas that prove the run really was hit-only.

### Raw mode and `/P` need diagnostic firmware; the plain file modes do not

`SDBENCH` with no arguments, and `BULK`, `SDBLK` and `SDWRITE`, are built on
`CMD_PROFILE`, `CMD_BULK_TEST` and the raw 512-byte SD commands. **A normal
controller build does not implement any of them** — level 69 retired them from
that profile, and they are answered with `RSP_UNKNOWN_COMMAND`. That is not a
fault and not a link problem; `BULK` reports it as `profile error 0xf1`, which
is simply "the reply class was not `RSP_PROFILE`".

To run them, reflash with the diagnostic profile:

```sh
cd ../../MCU/IOController && make IOC_PROFILE=diagnostic
```

**The two plain file modes need none of that.** They time on the Z80 with the
CTC and use only the SD storage commands (through BDOS) and `CMD_FS_*`, which
every build serves. `SDBENCH` probes for the diagnostic surface before it
offers the destructive prompt, so it will say so rather than asking you to
sacrifice a card to a run that could not have produced a number.

**`/P` is the exception.** It reads the controller's physical-SD profile over
`CMD_PROFILE`, which only a diagnostic build serves. On a normal build it is
answered with `RSP_UNKNOWN_COMMAND` and reports `profile error 0xf1`, exactly
as raw mode would.

### What each mode measures

| Mode | Path | Transaction |
|---|---|---|
| `SDBENCH file` | BDOS 20 → BIOS `READ` → host 512-byte deblock line → on miss `CMD_SD_READ_BLOCK` → bulk lane → controller cache → card | one miss fetches 512 bytes; the next three records are served from the line, no transaction |
| `SDBENCH file /H` | BDOS 20 → BIOS `READ` → deblock line hit | none: never reaches the lane |
| `SDBENCH file /S` | `CMD_FS_READ` → READY → bulk lane → FatFs → controller cache → card | 128, 256 and 512 bytes |
| `SDBENCH` | `CMD_SD_READ_BULK` / `CMD_SD_WRITE_BULK`, cache bypassed, timed by the controller | one 512-byte card block |

**The sizes in the FS rows are real transactions.** The controller does a single
`f_read` of exactly that many bytes before it answers READY, and the bulk phase
then carries them in one transfer.

**The 128 in the BDOS row is the only size there is.** CP/M 2.2's sequential
read still moves one 128-byte record per call, and that is what every timed
sample covers. What has changed is what happens beneath it: the BIOS now
deblocks on the Z80, so four consecutive records cost one 512-byte fetch on
the first of them and three host-side hits after it. Nothing in this program
will ever print them as one 512-byte transfer, because that is the misreport
the whole exercise exists to avoid.

There is no 1024-byte row and cannot be one: `IOC_FS_CHUNK_MAX` is 512, and the
controller answers `IOC_STATUS_FS_RANGE` to anything larger.

**The two file modes do not read the same file.** BDOS mode reads inside a CP/M
volume; `/S` reads a file in `/SHARED/` on the FAT card. Same card, same cache,
different files. Compare them as transport measurements, not as two views of one
file.

**BDOS mode names the drive it measured**, including when the command line did
not, because that decides what the numbers mean: A: is a build-time choice and
may be the ROM volume, and measuring flash is not measuring an SD card.

### The clock: two counters, no interrupts

CTC channels **3 and 1**, both timer mode, **interrupt disabled**, each read
with a single `IN`. Nothing vectors. On this board the timers step at 10 MHz ÷
16 — **1.6 µs** — and the control word's prescaler bit has no observed effect:
`27h` and `2Fh` both step at 1.6 µs. Every number below is written for that
measured step.

**Why not an interrupt.** The IO Controller link cannot survive one.
`cbios_ioc_command.asm` is polled byte I/O against an externally clocked SIO —
*"ISR-safe: No. Blocking poll"* — with a three-byte receive FIFO, about 18 µs at
6 µs/byte. A BIOS IM2 dispatch saves four register pairs, calls the callback and
issues `EI`/`RETI`, comfortably more than that budget. An early version of this
tool timed the run from a 1 kHz CTC interrupt; it did not perturb the
measurement, it destroyed it — `Bad Sector` on call 20, and `CMD_FS_READ` timing
out with no reply byte.

**Why two counters.** One 8-bit counter at 1.6 µs repeats every 409.6 µs, and
elapsed time is only recoverable while it stays under that. A record read on
this machine is about **19.5 ms** — nearly 48 full cycles — so a single counter
aliased every read and reported a throughput far above a stopwatch reading. A
clock that silently divides by an unknown integer is worse than no clock,
because the answer still looks plausible.

So the counter is widened. Channel 3 runs a time constant of 256 and channel 1
runs 255. The periods are coprime, so the pair of residues identifies the
elapsed count uniquely over 256 × 255 = 65280 steps — about 104 ms at 1.6 µs.
The combine is cheap because 256 ≡ 1 (mod 255):

```
a = (prevA - nowA) mod 256          residue from channel 3
b = (prevB - nowB) mod 255          residue from channel 1
k = (b - (a mod 255)) mod 255
elapsed = a + 256 * k
```

No division, no table. The channels need no common start and are never
synchronised — only their own differences are used.

Channel 1 is the partner because channel 0's `TO0` is SIO0/A's clock and must
not be touched, while `TO1` leaves the board. Channels 1 and 2 have never been
seen to *vector*, which is why nothing here asks them to; the CTC note records
that they do *count* with the interrupt bit clear and a control word of `27h`.
The measured step is 1.6 µs (10 MHz ÷ 16) — the prescaler bit has no observed
effect, as `2Fh` steps at 1.6 µs too — so the arithmetic is scaled to the step
the hardware actually makes and `27h` stays as the verified control word.
`tk_start` proves it on the running machine anyway, and reports `1` or `2` if a
channel is programmed but not counting — a dead counter reads as a constant,
which would otherwise show up as an infinitely fast disk rather than as a fault.

| | |
|---|---|
| Resolution | **1.6 µs** |
| Range | **104 ms per read** — about 5× a normal read |
| Time base | 32-bit, accumulated in the program's own memory |
| Wrap | Both counters wrap continuously and the residue arithmetic handles it; the 32-bit base cannot wrap in any run |
| Run length | Unbounded in practice: the 104 ms per-read ceiling bounds every conversion intermediate |
| File size | 4 MiB, checked. Beyond that the throughput product leaves 32 bits |

What is sampled either side of each read is **one read**, not the run — gaps
between reads are excluded from every reported figure and may be any length.

**Still not measurable:** a single read longer than ~104 ms. Nothing detects
that. **Cross-check a long run against a stopwatch** — if the reported total
falls well short of the wall clock, treat every figure as aliased. That is the
check that caught the single-counter ceiling, and it is the only one there is.

`/N` runs the identical pass with the counters never started. It measures
nothing; it exists so a failure can be told apart from a timing artefact in one
run.

### Caching

The controller keeps **eight 512-byte slots** in front of the card, LRU, and
both file modes go through it — FatFs shares it rather than keeping its own. In
BDOS mode one block in four misses the BIOS's own deblock line and reaches the
controller cache, which may then serve it from SRAM or go on to the card, while
the other three records are served straight from the bank-7 line. **That is the
application-visible path, not a distortion of it**, and it is why the histogram
is bimodal and the mean is a poor guide to what a streaming reader must
survive.

What *would* be a distortion is re-reading something small enough to still be
resident. Eight slots is 4 KiB, so any file of a few hundred KiB read forward
once cannot be served from it. **That is the entire methodology: there is no
host-side way to invalidate the controller's cache, and this program does not
pretend to have one.** Use a large file, and read the first run of a boot as the
coldest one.

The `/S` mode's three passes re-read the same file, but each pass leaves the
cache holding the *end* of the file, so the next pass starts cold.

### Reading the output

```
BDOS sequential read, 128-byte records
  bytes   524288  time    6248.32 ms   83915 B/s     81.94 KiB/s
  reads     4096  min     0.99  avg     1.52  max    27.95 ms
  ms  <1:0 1-2:4021 2-5:61 5-10:9 10-20:3 20-50:2 50-100:0 >=100:0
```

`time` is the sum of the individual read latencies — the time the program spent
inside BDOS, not wall clock. Console output and the benchmark's own bookkeeping
are outside every timed window, so they cannot inflate it. The histogram sums
exactly to `reads`, and the buckets sum exactly to `time`.

**Throughput is the number to quote; `max` is the number to design against.** A
streamer that has to hold a frame rate does not care about the mean. Size the
buffer from `max` and the frame budget, and use the tail buckets to judge how
often the worst case actually happens.

Bucket edges are milliseconds expressed in ticks — `ms × 625 / TC` at the
1.6 µs step — and rounded to the nearest tick, so at a coarse `/T` the lowest
buckets collapse toward zero rather than being mislabelled.

### Correctness checks

The record count comes from the directory before the run, so a premature EOF is
reported as one rather than showing up as a fast run. `/S` checks READY's length
against the length requested on every transaction, and reports which of open,
read or close failed: stages `41`/`42`/`43` are open, `51`/`52`/`53` read,
`61`/`62`/`63` close, in each case transport / wrong class / controller status.
A transport failure (`info 11`, no reply byte) on **open** means the controller
is not serving `CMD_FS_*` at all; the same failure on **read** means the link
broke mid-run. A read that fails is reported
and is never counted as a sample. One byte per read is accumulated, outside the
timed window, so the transfer cannot be optimised into nothing; there is no
whole-file checksum, because this measures transport and not the media.

A key stops a run; the figures then cover what was actually read, and say so.

## `XFER`: file transfer over the serial console

```
XFER ZR [d:]        ZMODEM receive; the sender names the files
XFER ZS [d:]afn     ZMODEM send, wildcards allowed
XFER YR [d:]        YMODEM batch receive
XFER YS [d:]afn     YMODEM batch send
XFER XR [d:]name    XMODEM receive (CRC or checksum, 128 or 1K blocks)
XFER XS [d:]name    XMODEM send (1K blocks with CRC, 128 with checksum)
```

The PC side can be any program that speaks the protocol — `lrzsz` (`sz`/`rz`,
`sb`/`rb`, `sx`/`rx`), TeraTerm, minicom — **with RTS/CTS flow control on the
port**. ESC or ^C on the keyboard aborts; a failed receive deletes its partial
file. An existing file of the same name is replaced.

It works in the default V9958 build only. A VDrip build uses SIO0/B for VDrip
itself and would need a file transport of its own.

**How it takes the port.** The BDOS console cannot carry binary data: the
serial console fallback has an 8-byte ring with no flow control, reads three
ESCs as its takeover gesture, and mirrors console output onto the same wire.
For the length of a transfer XFER turns off SIO0/B's receive interrupt (WR1
only — not SIO1, the CTC or WR9), clears the sercon tee and input bits, and
polls the port itself. On exit it restores the sercon flags and warm boots,
and warm boot re-registers the sink and re-enables the interrupt. Whichever
way the program ends, the console comes back as it was.

**How it keeps up.** The SIO buffers 3 bytes and a disk write masks interrupts
for milliseconds. XFER writes only where the sender is waiting for an answer
(an X/YMODEM ACK, a ZMODEM ZCRCW), and releases RTS around every disk write and
console call. ZRINIT advertises a 4K receive buffer, so a sender that honours
it stops at least that often; anything that still slips through is resent after
ZRPOS.
When sending, every 1K ZMODEM block waits for its ZACK.

**Limits.**

- CP/M 2.2 stores whole 128-byte records, so a received file is padded with ^Z
  to the next record, and a sent file's size is its record count times 128.
- XMODEM, and YMODEM without a size, cannot tell block padding from data:
  trailing ^Z bytes are dropped before the last record is padded again.
- ZMODEM uses CRC-16 only; ZRINIT does not offer CRC-32. There is no crash
  recovery: an interrupted file starts over.
- File names from the PC keep the last path component, truncated to 8.3, with
  characters CP/M rejects replaced by `_`.

## `src/ioc_diag_record.inc` is a mirror, not an original

The IOC failure-record layout is owned by `../CPM2.2/src/cbios_defs.inc`. This
copy gives the tools the record's field offsets, and `make` checks the two agree
before building anything. The record's address is not compiled in: tools read it
from BDOS function 203 at run time (`zb_diag_iy`).

That check is not ceremony. A tool built against a stale layout **assembles
cleanly and only lies at runtime** — in the one report anybody consults when the
link is dead. The mirror has drifted from the BIOS once already.

## Adding a command to the protocol

Three edits, not two:

1. `../MCU/IOController/include/ioc_frame.h` — the opcode
2. `../MCU/IOController/src/dispatch.c` — the handler
3. `../MCU/IOController/src/external_sync.c` — **`is_command_class()`**

That third one is a receiver-side whitelist. An unlisted class is dropped
*silently*, with no reply at all, so the host reports
`IOC_XPORT_TIMEOUT_REPLY_MARKER` — which reads as a dead controller rather than
"unknown command".
