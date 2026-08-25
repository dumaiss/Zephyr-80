# Two-Lane Transport: Design, Bring-Up and Open Issues

Status: bring-up. Both lanes carry data reliably, and soak runs are clean both
with and without CTC interrupt load. Command-frame integrity (CRC + rolling
sequence) is the remaining known gap — see [Open Issues](#open-issues).

See [protocol-gap-analysis.md](protocol-gap-analysis.md) for what the
proposed transport specifies that is *not* built here, and whether it
should be.

This describes the Z80 ↔ PIC transport as actually built, the order in which it
was brought up, and the problems still outstanding. It is written to be read by
someone picking this up cold, including the reasoning behind decisions that look
arbitrary, and the things that were believed and turned out to be wrong.

---

## 1. Topology

Two SIO channels, one PIC, one shared SPI bus.

```
              SIO1/B  (ports 32h/33h)          SIO1/A  (ports 30h/31h)
Z80  <------- COMMAND LANE ----------> PIC <-- BULK LANE -------------> Z80
              32-byte frames                   raw byte stream
              request/reply                    no framing, no escaping
```

Both lanes share **one** SPI2 module on the PIC and the same RB1/RB3 pins. Only
the chip select and the External Sync strobe differ:

| | select | sync strobe |
|---|---|---|
| command lane | `/SIOB_CS` (RA4) | `/SYNCB` (RA7) |
| bulk lane | `/SIOA_CS` (RA5) | `/SYNCA` (RA6) |

Consequences that matter:

- The two lanes **cannot** run concurrently. No IOCALL may be issued while a
  bulk transfer is in flight.
- The PIC is **clock master in both directions and never waits mid-transfer.**
  It emits a byte every N microseconds regardless of what the Z80 is doing.
  Every timing budget in this document follows from that one fact.

`RxCA` and `RxCB` come from the same PIC pin, each through a '125 gated by its
own channel select, and both are pulled up. `/SYNCA` and `/SYNCB` run directly
from the PIC, ungated.

---

## 2. Why External Sync mode

The Z80 SIO is run in External Sync mode. In that mode `/SYNC` is an **input**,
and the falling edge on it tells the receiver where character assembly starts.

SDLC/Monosync/Bisync were not options: they drive `/SYNC` as an *output*, which
would contend with the PIC, which owns that net.

This has a direct consequence that shapes everything else: **the PIC must place
the `/SYNC` edge at an exact bit position inside a byte.** SPI hardware cannot do
that — you cannot interrupt a hardware shift register between bit 1's rising and
falling clock edges. So byte 0 of every MCU→Z80 transfer is bit-banged by hand,
`/SYNC` drops inside it, and every later byte goes out through SPI2 at full
speed, because once `/SYNC` is low it stays low and no further edge matters.

That is `sio_link_clock_sync_byte()`. It is timing-exact code. The no-trailing-gap
asymmetry on bits 0 and 1 is load-bearing; a previous refactor into "clean"
generic bit helpers changed the waveform and the host received nothing but its
own `A5h` fill.

---

## 3. Command lane

### Frame format

Fixed 32 bytes, both directions:

| offset | meaning |
|---|---|
| 0 | class (command or response) |
| 1 | sequence |
| 2 | status |
| 3 | payload length |
| 4.. | payload |

Replies are led by a `7Eh` alignment byte, which is the byte carrying the
`/SYNCB` edge. It is not part of the 32.

### Z80 → PIC (request)

The PIC clocks a fixed 48-byte window and then searches it. It does **not** know
where in that window the host's transmission began: the host asserts RTS, and
its first byte reaches the wire some variable time later.

So `find_frame_start()` walks candidate **bit** offsets and validates a header at
each: class must be a known command, sequence must be `01h`, status `00h`, and
the payload length must match that specific class.

The per-class length check is **not** redundant with the class check. The search
takes the first offset that looks like a header, so those four fields are the
only thing separating a correct lock from a wrong one. Every field that stops
being checked makes a false lock likelier. **Adding a command means adding a
clause there, deliberately.**

A false lock is not a benign failure: it dispatches the *wrong handler*. An
observed case decoded a `CMD_SD_READ_BULK` as `CMD_PING` and replied `RSP_PING`,
after which every subsequent reply was one transaction out of step.

The search bound is derived from the window (`(48 − 32) × 8 = 128` bits) so the
whole slack the window was sized to provide is actually usable. It was 16 bits
for a long time, which threw that tolerance away and worked only because
one-shot programs had consistent timing.

### PIC → Z80 (reply)

1. Guard delay (`EXTSYNC_REPLY_GUARD_US`, 200 µs) so the host has enabled its
   receiver and entered hunt.
2. Two setup clocks with `/SYNCB` idle.
3. The `7Eh` alignment byte, hand-clocked, `/SYNCB` dropping inside bit 1.
4. 32 payload bytes through SPI2.
5. One trailing `FFh` — the SIO exposes its final received byte to `RR0` only
   after further clocks arrive.

The host scans up to `SIO_COMMAND_REPLY_SCAN_LIMIT` (160) received bytes looking
for `7Eh`. Failing to find one is `IOC_XPORT_BAD_FRAME` (`02h`); receiving
nothing at all is `IOC_XPORT_TIMEOUT_REPLY_MARKER` (`11h`). **Those two mean very
different things** — see [Open Issues](#issue-1-request-detection-race).

---

## 4. Bulk lane

A dumb byte pipe. No headers, no escaping, no terminator — the command lane
already supplied the framing and is authoritative about what the bytes mean.

### Lifecycle

```
IDLE --command--> PREPARE --READY--> BULK_ACTIVE --len bytes--> DONE
```

A handler calls `bulk_channel_arm*()` while building its READY reply. The bytes
must not be clocked until that reply has actually reached the host, so the
transfer is deferred: `main` runs `bulk_channel_run_if_armed()` immediately after
`external_sync_send()` returns.

The 8-bit `XFER_ID` in READY is echoed in DONE. A mismatch means a transfer was
lost or overlapped, which is the entire reason it exists.

### Command-lane handshake

Two signals, and they carry **levels, not pulses**. Nothing important lives in an
edge, because the PIC samples these lines only in its main loop and is blind for
the length of a bulk transfer or a card write.

| signal | dir | meaning |
|---|---|---|
| `/SIO1B_INT` (RF0) | in | low = the host has an **unacknowledged request** |
| `/DCDB` (RE0) | out | asserted = **COMMAND_READY**, the PIC will accept a request |

`/SIO1B_INT` means "I have a request outstanding", *not* "a transaction is in
progress". The host drops it as soon as it has finished transmitting its frame,
well before the reply. The PIC observes that release as a **required step of
servicing**, so it cannot miss it — and having seen this request acknowledged,
any low level found while idle must belong to a later one. That is what removes
the race, and it needs no latched edge (port F has no IOC — see Issue 1).

`/DCDB` is backpressure, not the race fix. READY means "the host may make
exactly one request", which matches the architecture: one SPI engine, no
concurrent lanes, one transaction in flight. It is asserted only after the
acknowledge *and* after all work the request triggered has finished, bulk phase
and card write included.

Its real value is telling **busy** apart from **dead**. Without it both present
as an ~11 s byte timeout; with it, a host can wait deliberately and a missing
controller is reported in microseconds as `IOC_XPORT_NOT_READY`.

> **Do not enable Auto Enables on channel B.** With `WR3` bit 5 clear, as it is
> today, `/DCDB` is a pure status bit in `RR0` bit 3 with no side effects. Set
> that bit and `/DCDB` gates the host's *receiver*, so deasserting it
> mid-transaction would silently kill reception. `/DCDA` on the bulk lane does
> exactly that, deliberately. The two channels are **not** configured alike.

One further detail: the host issues `WR0 = Reset External/Status Interrupts`
before each poll of `RR0`. The SIO latches modem-status bits on change, so a
stale latch would otherwise report a level the pin no longer carries.

Requests are also framed with two trailing filler bytes. `sio_command_put_byte`
writes into the transmit buffer, so when the send loop finishes the last frame
byte has not reached the wire — and releasing RTS *disables the transmitter*,
which would truncate it. The filler guarantees the frame is clear of the shift
register first, and lands in window slack the PIC already tolerates.

### Bulk-lane handshake signals

| signal | dir | meaning |
|---|---|---|
| `/SIO1A_INT` (RF1) | in | host's RTS: "I am in my transfer loop, go" |
| `/DCDA` (RB4) | out | with Auto Enables, gates the host's **receiver** |
| `/CTSA` (RB0) | out | gates the host's **transmitter**; marks the bulk phase live |

Waiting for the host's RTS replaces a fixed start guard, which was the single
largest cost in a sector transfer and was a guess. This is deterministic.

`/DCDA` is held deasserted outside a transfer, so stray clocks on the shared bus
cannot produce stray bytes in the host — BULK_ACTIVE enforced in hardware.

For a **write**, `/CTSA` stays asserted until the card write has completed, not
just until the last byte lands. The commit *is* part of the transfer: the card
has not been touched when the final byte arrives.

### MCU → Z80 (read)

The MCU places the `/SYNC` edge, so it owns the byte boundary and the host simply
reads `length` bytes. Byte 0 carries the sync edge and is still delivered as
data, so the host reads exactly `length` bytes.

### Z80 → MCU (write)

**Not symmetric with the read**, and this is the part most likely to be
mis-assumed. The MCU supplies the clock but has no idea which edge the host's
transmitter started shifting on, and the host idles marking for an
indeterminate time before it starts.

So the payload is led by a **`7E 81` preamble**. The MCU captures the stream raw
and de-shifts it against wherever that pattern is found.

Two preamble bytes, not one: a lone `7Eh` occurs at a shifted offset inside
ordinary data — a `00-FF` ramp contains one — and a false lock rotates the whole
block silently.

**DONE is mandatory for a write.** A read can skip it: receiving every byte and
seeing `/CTSA` drop already proves completion. A write cannot — bytes reaching
the MCU says nothing about whether the card stored them, and the card is only
touched after the last byte arrives.

---

## 5. Timing budgets

Everything here follows from the PIC never waiting mid-transfer.

| path | host loop | cost | MCU pacing |
|---|---|---|---|
| bulk read | `INI` loop | 56 T = 5.6 µs/byte | 6 µs/byte |
| bulk write | `OUTI` loop | 56 T = 5.6 µs/byte | 12 µs/byte |
| command lane | `sio_command_get_byte` | 151 T = 15.1 µs/byte | 16 µs/byte |

The command lane is slow because of its per-byte `call`/`ret`, `push`/`pop` and
24-bit timeout reload. The bulk lane avoids all of that: `INI`/`OUTI` do the port
access, the store, `HL++` and `B--` in one 16 T instruction.

### The read/write asymmetry is deliberate

On a **read**, the MCU clocking slightly too fast costs nothing — the host has
simply not seen the byte yet and polls again.

On a **write**, the MCU clocking too fast makes the host's SIO **under-run**. The
transmitter then streams its `WR7` fill character, which is `00h` on this
channel. The MCU receives a perfectly well-formed block of zeros, the preamble
search succeeds, and it commits that to the card. **A silent wrong-data write.**

Worse, once the Tx Underrun latch sets, the transmitter stops consuming the
buffer, so the host's TBE never re-asserts and it times out.

Hence 12 µs, roughly 2× the host loop, and hence the host checking `RR1` bit 6
after transmitting. Do not tune the write pacing down to match the read.

**Never test this transport with all-zero data.** Zeros are indistinguishable
from underrun fill. Every test block must carry a non-zero canary.

---

## 6. Bring-up order

Each step existed because the previous one had left something unproven.

1. **PING over the command lane.** Established External Sync framing, the
   `/SYNCB` drop position, and the bit-search receive.
2. **`SD_READ`** — 16 bytes returned inside the command-lane reply frame. Proved
   the SD driver without involving the bulk lane at all. Still the best
   first-line diagnostic, because it isolates card problems from transport
   problems.
3. **`BULK_TEST`** — a synthetic `00 01 02 …` ramp from MCU SRAM, no card
   involved. Proved the bulk lane read direction independently.
4. **`SD_READ_BULK`** — full 512-byte sector, verified by the `55 AA` signature
   at offset 510, which proves the *tail* arrived, not just the head.
5. **`IOCBULK`** — moved the read direction into the BIOS. `ioc_bulk.asm` was
   deliberately kept on its inline loop as an A/B control.
6. **`SD_WRITE_BULK`** — the Z80→MCU direction, `CMD24`, and the preamble
   scheme.
7. **Soak test** — multi-LBA write/read/verify, and CTC-driven interrupt load.

### What the soak found immediately

Steps 1–6 all used **LBA 0**, which is the one address where block-addressed
(SDHC) and byte-addressed (SDSC) arithmetic agree, since `0 × 512 == 0`. The
entire 32-bit LBA path was therefore unexercised. The soak spans LBAs up to
1048576 and every block carries its own LBA, so a wrong-block read fails loudly.

**That path is now confirmed correct** — the first soak pass verifies all eight
LBAs byte-for-byte.

The soak also immediately exposed the request-detection race below, which no
one-shot `.COM` program could ever have shown.

---

## 7. Open issues

### Issue 1: request detection race — FIXED

Kept here because the reasoning matters and the failure modes are worth
recognising if anything like it recurs.

**The fix:** `/SIO1B_INT` was redefined from "a transaction is in progress" to
"I have an unacknowledged request", released as soon as the request frame is
delivered rather than at the end of the transaction. The PIC observes that
release as a *required step of servicing*, so it cannot miss it, and any low
level found while idle therefore belongs to a later request. No latched edge is
needed — which matters, because port F has no IOC.

`/DCDB` was then added as COMMAND_READY backpressure (see the command-lane
handshake above). It is not what fixes the race, but it is the most likely
reason the residual error rate went to zero: it governs when a transaction may
start at all.

The original analysis follows.

**This was the blocker for sustained traffic.**

`/SIO1B_INT` (RF0) is the host's service request: level-low for the whole IOCALL
transaction. The PIC samples it only in its main loop, and is blind while inside
a transaction, a bulk transfer, or a card write — hundreds of milliseconds.

Both detection schemes tried so far fail:

- **Sampled edge** (remember previous level, look for high→low). Only works if
  the PIC happens to sample inside the gap between one transaction's release and
  the next one's assertion. Back-to-back hosts re-assert within microseconds.
  Miss it and the edge is gone permanently — the line is already low and nothing
  will make it fall again. The request is lost until the host's ~11 s timeout.

- **Level plus wait-for-release.** Fails in the other direction. During a write
  the host releases RTS, transmits the bulk payload, waits for `/CTSA` and
  re-asserts for DONE — all while the PIC is still inside the bulk receive and
  card write. By the time the PIC waits for a release, it has already happened
  and will not repeat. Short bound → the PIC gives up and re-services the same
  low level, clocking junk windows into the host (the `BAD_FRAME` cascade below).
  Long bound → deadlock, ~10 s per DONE query.

The failure amplifies badly. When the PIC misses a frame it sends no reply, so
the host holds RTS and waits. If the PIC then re-services, it clocks another
48-byte window with `/SYNCB` asserted, which the host counts as received bytes.
After ~4 windows the host's 160-byte scan is exhausted and it reports
`BAD_FRAME` — so **one** missed frame produces several reported errors, and the
error rate looks far worse than the underlying fault rate.

**The obvious fix is not available.** A latched edge would solve it — an
interrupt-on-change flag records an assertion arriving while the PIC is busy —
but the PIC18F57Q84 provides IOC on ports **A, B, C and E only**, and
`/SIO1B_INT` is on **port F**. There is no hardware latch for this pin.

Candidate fixes, none yet implemented:

1. **Software latch by sampling inside long operations.** Poll `/SIO1B_INT`
   inside the bulk transfer loops and the SD busy-wait, recording that a release
   was observed. The line *is* high for a usable interval during the bulk phase,
   so this is reachable. No board change. Currently the most promising.
2. **Move `/SIO1B_INT` to an IOC-capable pin.** Correct but needs hardware.
3. **Host-side retry.** Costs a full ~11 s timeout per lost request unless the
   host timeout is also reduced.
4. **An explicit MCU-ready signal** the host polls before asserting RTS.

### Issue 2: the one-bit `/SYNC` difference

Channel B drops `/SYNCB` inside bit **1**; channel A drops `/SYNCA` inside bit
**0**. Measured, not guessed: with the drop at bit 1 the bulk lane read `80h`
where the ramp's first byte is `00h`, and a sector read returned `2A D5` where
the signature is `55 AA` — `(55h >> 1)` and `(AAh >> 1) | 80h`, a whole-stream
one-bit shift.

Ruled out by test or inspection:

| candidate | result |
|---|---|
| `WR3` / Auto Enables | tested — `D1h` behaves exactly as `F1h` |
| `WR4` | identical `30h` on both, by inspection |
| setup clock count and shape | identical |
| bit-bang waveform | identical; same drop position within the bit |
| clock gate-open timing | tested — no effect |

`RxCA`/`RxCB` share one PIC pin through per-channel '125 gates and both are
pulled up, so gate transitions are symmetric and do not explain it either.

**Still unexplained.** The measurement that would settle it is a rising-edge
*count* at the SIO's `RxC` pin — after the '125, so it is what the receiver
actually sees — between `/SYNC` going low and the end of that byte, taken on
each channel. That count is exactly what sets the window. Another firmware
experiment will not find it.

Both lanes share `sio_link_clock_sync_byte()`; the drop bit is the only
difference, and it is a genuine hardware asymmetry rather than a workaround for
a configuration difference.

### Issue 3: interrupt latency — addressed on both lanes

**The structural point.** In designs where the Z80 bit-bangs the SPI clock
itself, an interrupt simply stretches the transfer: the CPU stops clocking, so
the peripheral stops too, and nothing is lost. Zephyr cannot borrow that. The
MCU is clock master and never waits, so an ISR is not latency — it is lost data.

A CTC ISR costs 117 T-states (98 T of handler plus 19 T of IM2 acknowledge) =
11.7 us at 10 MHz.

**Bulk lane:** `DI` around the whole transfer, in `IOCBULK` for reads and in the
host's transmit phase for writes. ~3.1 ms and ~6.2 ms of masked time.

**Command lane:** `DI` around each frame *transfer*, not around the whole
transaction — the MCU performs card I/O inside a transaction, so masking across
the reply would blackout for up to a second. The masked window runs from the
start of the request send through RTS release and the receiver arm (~1.14 ms),
then unmasks for the scan, then masks again for the 32-byte body (~1.02 ms).

**The receiver arm must be inside the masked window.** This was the subtle one.
Re-enabling interrupts at the end of the send let a pending ISR run before the
receiver was armed, and with console interrupts stacking on top the arm could
land part-way through the MCU's reply (which begins only 200 us later). The
receiver then synced on a later edge, saw no `7Eh`, and timed out. `RR0` showed
SYNC/HUNT **clear** with no byte available — the reading that identified it.

**Diagnostic note.** `RR1` bit 5 (Rx Overrun) was clear on every failure
throughout, which was read as ruling out interrupt involvement. It did not: a
clear error bit says one specific thing did not happen. The SIO has no status
bit for "the host armed me too late", and that is what was happening.

**Raising pacing was tried and backed out.** It does not remove the dependency,
only buys a larger ISR you happen to survive.

**Still not built: burst transfer.** The MCU stopping the clock every N bytes
would let the host service interrupts in the gaps, cutting the bulk blackout to
~192 us at 32-byte bursts. The existing bulk RTS can be strengthened into
per-burst flow control. Worth it for GameOS; not needed for CP/M, where a 3 ms
blackout is acceptable and a periodic tick simply coalesces across it.

### Issue 3a: original notes (superseded)

**The structural point.** In designs where the Z80 bit-bangs the SPI clock
itself, an interrupt simply stretches the transfer: the CPU stops clocking, so
the peripheral stops too, and nothing is lost. That is why such drivers can run
with interrupts enabled given only a rule about not clobbering shared GPIO
state.

Zephyr cannot borrow that. The MCU is clock master and never waits, so an ISR
is not latency — it is lost data. The producer cannot be paused.

Measured: a CTC ISR costs 117 T-states (98 T of handler plus 19 T of IM2
acknowledge) = 11.7 us at 10 MHz. Against it:

| lane | host loop | pacing | slack | survives an ISR? |
|---|---|---|---|---|
| bulk read | 5.6 us (INI) | 6 us | 0.4 us + 3-byte FIFO (~18 us) | marginal |
| bulk write | 5.6 us (OUTI) | 12 us | 6.4 us, ~2 bytes buffered | no |
| command | 15.1 us | 16 us | 0.9 us | no |

Under CTC load at 1 ms this failed ~65% of writes.

**Raising the pacing was the wrong fix and was backed out.** It does not remove
the dependency, it only buys a larger ISR you happen to survive, leaving
correctness a function of ISR duration forever.

**What is implemented:** `DI` around the whole transfer, in `IOCBULK` for reads
and in the host's transmit phase for writes. That removes the timing dependency
outright. Cost is a ~3.1 ms interrupt blackout on a read and ~6.2 ms on a write.
CP/M has no real-time expectation and the console SIO buffers, so that is
acceptable — but note a periodic tick will COALESCE across the blackout, which
matters if the tick is used for accounting rather than scheduling.

**The better fix, not yet built: burst transfer.** The MCU stops the clock every
N bytes so the host can service interrupts in the gaps. At 32-byte bursts the
blackout falls to ~192 us; at 16 bytes, ~96 us. The existing bulk RTS already
means "I am in my transfer loop, go" and can be strengthened into per-burst flow
control, so the MCU never clocks a burst unless the host has explicitly entered
an interrupt-protected window. That removes the blackout without reintroducing
any dependence on ISR duration.

### Issue 3a: original notes (untested)

The read loop runs 5.6 µs against a 6 µs budget — about 7% headroom, less than
one interrupt's latency. A stall inside the `INI`/`OUTI` loop is unrecoverable:
on a read the SIO's 3-byte RX FIFO overflows and bytes are lost; on a write the
transmitter under-runs.

`SDSOAK I` drives CTC channel 0 as a periodic interrupt source to measure this.
**It has not been run yet** — Issue 1 has to be fixed first, or the results will
be unreadable.

The number worth finding is where it breaks: the FIFO buys roughly 18 µs at
6 µs/byte, and that figure is the interrupt budget this transport can tolerate.
It needs to be known before CP/M storage moves behind this, because at that
point every disk access happens with the console live.

---

## 8. Diagnostics

### Command-lane transport codes (`IOCALL` return)

| code | meaning |
|---|---|
| `01` | send timeout — the MCU never clocked; request likely lost (Issue 1) |
| `02` | `BAD_FRAME` — 160 bytes received, no `7Eh`; usually the cascade above |
| `11` | no reply byte seen |
| `12` | reply began, then stalled |

### Bring-up scaffolding in the DONE reply

`IOC_OFF_DONE_PEEK` carries the first 8 bytes of the transfer buffer after
de-shifting; `IOC_OFF_DONE_RAW` carries the first 8 bytes of the raw capture
window before it. Together they separate "the host never transmitted", "the
de-shift is wrong" and "the card write went wrong", which are otherwise
indistinguishable.

This is what found the de-shift bug that had survived several rounds of
theorising: a raw line of `01 FC 02 01 02 04 06 08` is the complete correct
stream shifted one bit, which pinned the fault to the de-shift in one step.

**Keep this until the write path has real mileage.** Remove it, along with
`bulk_channel_rx_window()`, when the transport is trusted.

### `SDSOAK`

```
SDSOAK          soak, no interrupt load
SDSOAK I        with CTC interrupts at the default rate (~1 ms)
SDSOAK I 20     with CTC interrupts, time constant 20
```

Any key stops it; counts are hex. Failure lines carry a `code=` identifying the
exact check that failed and an `info=` carrying the underlying status.

Patterns rotate per pass: LBA-seeded ramp, `FF` runs, `AA/55` alternating, and
repeated `7E 81` — the last deliberately attacks `find_bulk_start`, since a
preamble that can false-lock inside payload data is a design risk chosen by
reasoning rather than measurement.

---

## 9. Lessons that cost time

Recorded because each one was believed confidently and was wrong.

- **A scope showing two signals coincide does not mean one gates the other.**
  `SPI_CLK` and the device select coincided because the firmware only ever
  clocked while a select was asserted. That correlation was written into three
  files as "confirmed on a scope" and used to justify deleting the SD spec's
  required CS-high power-up burst.
- **All-zero data proves nothing on this transport.** It is exactly what an
  under-running transmitter produces.
- **`RXBF` means the FIFO is *full*.** For single-byte exchanges it never sets;
  use `SPIxRXIF`.
- **Read the code before theorising about the hardware.** The de-shift bug was
  `armed_length` being cleared before it was used as a loop bound — visible in
  four lines of C, after several rounds of SIO timing hypotheses.
- **Instrument earlier.** Every one of these was found by a readout, not by
  reasoning. The raw-window peek took one round and gave an unambiguous answer.
