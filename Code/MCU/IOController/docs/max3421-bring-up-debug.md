# MAX3421E Bring-Up: Debug Log

Date opened: 2026-08-28
Status: **RESOLVED THROUGH HID REPORTS.** The MAX3421E link is clean, the FE1.1
hub and keyboard enumerate, and boot-keyboard reports continuously reach the
IOC application callback.  See the level-61 result for the final report-path
fault and its exact submission/completion accounting.

A running record of what was tried against "the MAX3421E will not come up", what
each attempt ruled in or out, and what is still open. Append to it; do not prune
the ruled-out section, because its whole value is stopping the same ground being
covered twice.

## Level 62: HID reports become terminal input

The first post-bring-up input layer is now implemented, but still awaits a run
on the machine.  It deliberately stops before BIOS integration:

```text
TinyUSB boot-keyboard report
  -> new-key transition detector
  -> US-keyboard / control / VT100 translation
  -> 128-byte IOC HID input queue
  -> CMD_HID_INPUT (0Eh)
  -> HIDKEY.COM test program
  -> existing CP/M console output
```

The translator lives entirely in `src/ioc_hid.c`; storage, the SD cache, the
bulk lane and BIOS `CONST`/`CONIN` are unchanged.  Printable US keys, Shift,
Caps Lock, Ctrl combinations, keypad characters, cursor/navigation keys and
F1-F12 are covered.  Cursor keys use `ESC [ A/B/C/D`, F1-F4 use `ESC O P-S`,
and the remaining function/navigation keys use the usual numbered CSI forms.
Each multi-byte sequence is admitted atomically, so a full queue cannot leave a
partial escape sequence for the host.  The saturating dropped-sequence count is
reported by the command.

`CMD_HID_INPUT` is nonblocking.  Its one-byte request payload is the maximum
number of bytes wanted (zero is status-only); its reply payload is:

```text
byte 0      bytes still queued after this dequeue
byte 1      dropped-sequence count, saturated at FFh
bytes 2..   zero to 24 terminal-input bytes
```

`HIDKEY.COM` polls this command directly and echoes returned bytes through
`CONOUT`; it never calls `CONST` or `CONIN`.  Ctrl-C exits.  This is the intended
bring-up boundary before the queue is wired into the BIOS console input path.

Only key-down transitions are emitted in this first cut.  An unchanged held
key does not repeat at the USB polling rate; deliberate host-side typematic is
still to be designed after the translation and queue have been exercised.

A clean level-62 firmware link reports:

```text
Data space used       7,416 of 12,800 bytes (57.9%)
Data stack reserved     512 bytes
Conservative total    7,928 of 12,800 bytes (61.9%)
Physical headroom     4,872 bytes             (38.1%)
```

The 256-byte US translation table linked in `MEDIUMCONST` (program space), not
SRAM.  The queue itself is 128 bytes.  Both firmware and `HIDKEY.COM` build
cleanly apart from the pre-existing XC8/TinyUSB warnings; hardware validation
is the next test.

## Current SRAM checkpoint (level 61, before key translation)

The firmware that enumerates the hub and keyboard and receives HID reports is
**not** the 99.2%-SRAM build described later in this chronological log.  The
current Makefile still selects:

```text
-mstack=hybrid:512:0:0
```

A forced level-61 rebuild from all sources reports:

```text
Data space used       7,280 of 12,800 bytes (56.9%)
Data stack reserved     512 bytes
Conservative total    7,792 of 12,800 bytes (60.9%)
Physical headroom     5,008 bytes             (39.1%)
```

XC8 reports the separately configured 512-byte data-stack reservation as
`512 of 512 (100.0%)`.  That means the requested reservation was placed; it is
not a measured runtime high-water mark.  The later `12,693 of 12,800 (99.2%)`
figure belongs to a rejected experimental `-mstack=software` build and must not
be used as the current firmware's memory figure.

The largest current allocation is the eight-slot SD cache: 4,160 bytes.  Other
notable fixed buffers are the bulk receive window (539), the bulk staging block
(512), TinyUSB's two-device host table (279), and the SD-record staging buffer
(128).  The intended HID-to-terminal-input layer should need only a small byte
queue and a few bytes of key/modifier state; its translation tables must remain
`const` so they occupy program space rather than SRAM.  Budget the first version
at no more than 256 additional SRAM bytes and re-check this table after it is
linked.

This does not close the separate PIC18 hardware return-stack warning, nor does
it make the hybrid allocator's previously found overlay defects impossible.
Those are correctness risks, but they are not evidence that data SRAM is nearly
exhausted.

## Presenting Symptoms

- `HIDSTAT.COM` never reported a live controller.
- On a scope: MOSI appeared to sit at all ones, and SCK toggled but not at
  anything like the configured rate.
- SPI wiring had already been continuity-checked and the selects were confirmed
  to be strobing.

## Root Cause

**The MAX3421E powers up in half-duplex SPI mode, and this board is not wired
for half duplex.**

The datasheet is explicit (§SPI Half- and Full-Duplex Operation):

> The MAX3421E is put into half-duplex mode at power-on, or when the SPI master
> clears the FDUPSPI bit. In half-duplex mode, the MAX3421E tri-states its MISO
> pin and makes the MOSI pin bidirectional [...] The MISO pin can be left
> unconnected in half-duplex operation.

So with `PINCTL.FDUPSPI = 0` the part never drives MISO at all; read data comes
back out of its own MOSI pin. Figure 11 note 3 adds the warning that matters
here:

> FOR SPI READ CYCLES, AFTER THE 8TH CLOCK-FALLING EDGE, THE MAX3421E STARTS
> DRIVING THE MOSI PIN AFTER TIME tON. THE EXTERNAL MASTER MUST TURN OFF ITS
> DRIVER TO THE MOSI PIN BEFORE tON TO AVOID CONTENTION.

This board cannot turn that driver off. From
`pBITzPlatform/pBITzBackplaneMezzanine/USBPorts.kicad_sch`, `SPI_MOSI`,
`SPI_CLK` and `~USB_CS` all pass through **U3, a CD74HC4050 running at 3V3**
(units 1, 2 and 3) before reaching U2. That buffer exists to translate the PIC's
5 V levels down — `Zephyr-80/Schem/Zephyr-80-IO/IO Controller.kicad_sch` is
+5V-only — and it is unidirectional, PIC to MAX3421E. Only `SPI_MISO` returns
unbuffered, straight off U2.15.

(Note on sources: `pBITzPlatform/pBITzTerminal/IO Controller.kicad_sch` is a
different product on the same platform and has a completely different port A
map. The Zephyr-80 IO card is `Zephyr-80/Schem/Zephyr-80-IO/`. Do not read the
pBITzTerminal sheet for this machine.)

Both symptoms follow directly:

- Every read returned garbage, because the PIC was sampling an undriven MISO.
- MOSI looked wrong, because on the second byte of every read the MAX3421E
  switched its MOSI driver on into U3's output. Two CMOS output stages fighting.

### Why the firmware could not recover from it

`hid_host_init()` read the REVISION register *before* calling `tuh_init()`.
The only code that sets `FDUPSPI` is TinyUSB's `hcd_init()`, which writes
`PINCTL | PINCTL_FDUPSPI` first and reads REVISION second — see
`hcd_max3421.c:509-513` — for exactly this reason.

That made the bring-up path a lock with no key: the revision check gated the
call that establishes the revision check's own precondition. Result was
`HID_HOST_BAD_REVISION` on every boot, permanently.

`hid_host_probe_revisions()` had the same defect, and was worse in kind: 192
blind half-duplex reads, each one a driver fight. That is what was on the scope.

## Fix Applied

`select_full_duplex()` in `src/ioc_hid.c` — one blind `8A 10` write (PINCTL,
DIR = 1) issued before any read, called at the top of `hid_host_init()` and
again at the start of each probe burst.

A *write* is the correct bootstrap because it behaves identically in both modes:
the master drives MOSI for the whole cycle and the MAX3421E never turns its
driver on. Only reads differ between the modes, which is why the order cannot be
inverted.

Expected result: REVISION reads `0x13`. That is the R18 reset value in the
datasheet's register table (`0 0 0 1 0 0 1 1`); `0x01` and `0x12` are the
earlier die revisions.

## Ruled Out — Do Not Re-Investigate

| Hypothesis | Why it is not the problem |
|---|---|
| SPI mode mismatch | SPI1 is `CKP=0`, `CKE=1` — mode 0. The datasheet states the part works in `(0,0)` and `(1,1)` with no adjustment, because it clocks on the rising edge in both. |
| MISO 3.3 V into a 5 V PIC on RC4 | The SD card uses the identical unbuffered path through its own 4050 and works. Empirically fine. |
| Wrong command bytes | `0x90` = R18<<3, DIR 0. `0x8A` = R17<<3, DIR 1. `0xA0`/`0xA2` = R20 read/write. All verified against the command-byte format `Reg[7:3] \| 0[2] \| Dir[1] \| Ack[0]`. |
| 74HC595 latching garbage during USB traffic | Expected `spi1_bus_select(NONE)` to clock RCLK while USB was selected. It does not: RCLK is already parked high before `/IO_USB_CS` asserts, so no edge is produced. The shift register does fill with USB bytes — the port C clock is ungated — but it is fully overwritten by the next 16-bit `controller_latch_write()`. |
| Idle bus traffic confusing the scope | There is none. `CONTROLLER_LATCH_COUNTER_TEST` is 0 and `sd_cache_tick()` only touches SPI when a slot is dirty. |

### On the scope reading specifically

Within a burst, SCK genuinely is 125 kHz / 1 MHz / 4 MHz. But the whole probe is
about 10 ms and fires once per `HIDSTAT` run against an otherwise silent bus, so
a free-running scope measures the burst envelope rather than the clock. Trigger
on the falling edge of `/IO_USB_CS` (RA3) at roughly 20 µs/div.

## Hardware Constraints Confirmed

Traced from `USBPorts.kicad_sch` and confirmed by inspection.

- **`RES` (U2.12) is strapped to +3V3.** There is no reset control at all.
  TinyUSB even carries the comment "driver does not seem to work without nRST
  pin signal". `CHIPRES` is documented as equivalent to pulling `RES` low, so
  the SPI-side reset path is intact, but a wedged part can only be recovered by
  dropping the rail.

  **This changes how the fix must be tested.** `RES` and `CHIPRES` both spare
  R17 (`PINCTL`), R15 (`USBCTL`) and the SPI logic — only a power-on reset
  clears them. The MAX3421E sits on the mezzanine 3V3 rail while the PIC is a
  separate 5 V board, so resetting or reflashing the PIC does *not* reset the
  MAX3421E. Once the FDUPSPI write lands one time, the part stays in full duplex
  across every subsequent PIC reset. To exercise the real cold-start path, drop
  the 3V3 rail. This is also why the blind write is repeated per probe burst
  rather than done once at boot.

- **`GPX` (U2.17) is a no-connect.** GPX defaults to `OPERATE`, which would have
  been a single-probe "is the part alive and out of reset" answer. It is not
  available. Worth bodging out on the next board spin.

- **`/USB_INT` (U2.18)** has a 10 kΩ pull-up to 3V3 and goes unbuffered to PIC
  RA0 at 5 V. Not yet checked — bring-up does not get that far. Flagged because
  unlike MISO this path has no working precedent on the board: if RA0's input
  buffer is Schmitt (VIH = 0.8·VDD = 4.0 V) then a 3.3 V high never registers,
  and the pin reads permanently asserted. `INLVLA0` selects TTL levels if so.
  This will present as "enumeration silently never starts", not as a bus fault.

- All eight `GPOUT` pins (U2.4–U2.11) are no-connects, which is what makes the
  loopback test below free.

## GPOUT Loopback Test

Added because GPX is unavailable and reading one constant register is weak
evidence — a bus stuck in exactly the wrong way can match a constant, but not a
walking pattern.

`gpout_loopback_at()` writes IOPINS1 (R20) and reads it back through eight
patterns — `00 01 02 04 08 05 0A 0F` — masking to the GPOUT nibble, since
GPIN3-0 share the register and float on this board. Walking-one alone cannot
separate a stuck-low bit from an undriven one, so `00`/`0F` pin both stuck-at
polarities and `05`/`0A` cross every adjacent pair in both directions.

Run **per rate**, on purpose. The failure being hunted is propagation delay
through U3, which is fixed — so a marginal part passes at 125 kHz and fails at
4 MHz. A single-rate test would call that board healthy.

Reported by `HIDSTAT.COM` as three bytes:

- `00` — every pattern read back correctly.
- `FF` — the PIC's own SPI module never completed a byte; nothing was learned
  about the far end.
- anything else — mask of the GPOUT bits that read back wrong. `0F` is "nothing
  is getting through in one direction or the other"; a single bit is a stuck or
  bridged line.

## Bisection Guide

With FDUPSPI set, the remaining failure modes separate cleanly:

| Observation | Conclusion |
|---|---|
| REVISION `13`, loopback `00` at all three rates | SPI link is healthy end to end. |
| REVISION `13`, loopback `00` slow but non-zero at 4 MHz | U3 propagation delay. Drop `HID_SPI_BAUD`. |
| REVISION `13`, but `tuh_init()` returns false | Stuck in the bounded OSCOK poll → Y1/Y2 12 MHz crystal and its 22 pF load caps. Register access does not need the oscillator; the SPI logic is clocked by the master's SCLK, and the register file is only inaccessible when VCC or VL is absent. |
| REVISION `00` or `FF`, loopback `0F` | SPI link itself — U3, or MISO. |
| Loopback `FF` | The PIC's SPI1 module, not the far end. |

## Protocol Changes

`IOC_FW_LEVEL` 23 → **24**. `HID_STATUS` payload 6 → **9** bytes. Both ends must
be flashed together: `HIDSTAT.COM` checks the reply length and will report
"unexpected payload length" against level-23 firmware.

## Run Log

### 2026-08-28 — level 24 flashed, first run

```text
IOC HID STATUS
  bring-up status : 03  BAD REVISION
  MAX3421E REVISION: FF
  /USB_INT level  : 1   inactive
  live REV @125k : FF
  live REV @1MHz : FF
  live REV @4MHz : FF
  GPOUT link@125k: 0F  FAIL
  GPOUT link@1MHz: 0F  FAIL
  GPOUT link@4MHz: 0F  FAIL
```

Level 24 is confirmed running: the reply-length check passed and the new GPOUT
lines printed. What this run establishes:

- **The fault is not timing.** Identical results at 125 kHz, 1 MHz and 4 MHz.
  That is precisely what the per-rate loopback was built to catch, and it rules
  out U3 propagation-delay marginality. Lowering `HID_SPI_BAUD` will not help.
- **The MAX3421E is not driving MISO at any point.** `FF` rather than `00` is
  the signature of an undriven bus here — the SD driver notes the same thing for
  an empty socket ("every response byte reads FFh"). A full-duplex part drives
  MISO for the whole time SS is low, including the status byte during the
  command phase. Nothing is coming back at all.
- `0F` on the loopback carries no information beyond that: with every read
  returning `FF`, pattern `00` gives `(FF^00)&0F = 0F` and pattern `0F` gives
  `00`, so the OR is `0F` by construction.
- **`/USB_INT` reads 1.** The mezzanine's 10 kΩ pull-up to 3V3 is holding RA0
  high, which proves that net exists and — usefully — that RA0 reads a 3.3 V
  high correctly. The `INLVLA` concern is closed. It does **not** prove U2 is
  powered; the pull-up holds high with the part dead or unpowered.

### The crystal is not a candidate for this symptom

Register access does not need the 12 MHz oscillator. The SPI logic is clocked by
the master's SCLK, and the datasheet only says the register file is inaccessible
when VCC or VL is absent. A dead crystal would still return a correct REVISION.
`FF` therefore places the fault *upstream* of the oscillator: power, the SPI
path, or the part. Y1/Y2 only become suspects once REVISION reads `13` and
`tuh_init()` then hangs in the OSCOK poll.

### Interconnect verified, so it is not a wiring design error

Traced end to end across three sheets:

```text
PIC RA3 (pin 24) --~IO_USB_CS--> [pBITz Bus Interface].SPI_CS0
                             --> mezzanine SPI_CS0 --> USBPorts ~USB_CS
                             --> U3 unit 2 (CD74HC4050) --> U2.14 (SS)

PIC RA2 (pin 23) --~IO_SD_CS---> SPI_CS1 --> SD_Card ~SD_CS
```

No swap, no missing net, and the firmware's port A map matches the real board
pin for pin. `SPI_CS0` is USB and `SPI_CS1` is SD, consistently on both sides.

### What is left, and why

The working SD card proves `IO_SCK`, `IO_MOSI` and `IO_MISO` end to end from the
PIC through the backplane to the mezzanine, and proves `~IO_SD_CS`. It proves
nothing about:

1. **U2 power** — VCC (pin 23) and VL (pin 2). Not proven by anything so far.
2. ~~`~IO_USB_CS` / `SPI_CS0`~~ — **cleared.** Scoped toggling at the backplane
   end and at the buffer output; continuity good from the package back.
3. **U2.15 (MISO) solder joint** — the net is proven, that pin's joint is not.
4. **U2 itself.**

### 2026-08-28 — `/IO_USB_CS` confirmed on a scope

Measured leaving the IO card. RA3, the PIC's drive of it, and the IO card's
routing are all good. The unexercised part of that net is now only what is
downstream of the card edge: backplane, mezzanine connector, U3.

### U3 is the prime suspect

**U3 is a different physical part from the buffer the SD card uses.**
`SD_Card.kicad_sch` instantiates its own `4xxx:4050`; U3 lives only on
`USBPorts.kicad_sch`. So nothing that currently works exercises U3 at all.

All three signals the MAX3421E needs in order to be commanded pass through it:

| Signal | U3 in | U3 out | Reaches |
|---|---|---|---|
| `MOSI` | pin 3 | pin 2 | U2.16 |
| `~CS`  | pin 5 | pin 4 | U2.14 (SS) |
| `CLK`  | pin 7 | pin 6 | U2.13 (SCLK) |
| VDD / VSS | pin 1 / pin 8 | — | +3V3 / GND |

`MISO` is the only SPI signal that bypasses U3, going straight from U2.15 to the
connector.

A dead, unpowered or badly joined U3 therefore explains **every** observation
with a single fault: U2 gets no select, no clock and no data, so it never drives
MISO, the bus floats, and every read returns `FF` at every rate. It also
explains why `/USB_INT` still reads 1 — that is just the 10 kΩ pull-up, which
does not involve U3 — and why the SD card is unaffected.

Useful property of the 4050 while testing: it is the classic 5 V to 3.3 V
translator precisely because it has no input clamp diode to VCC. An unpowered
4050 cannot be parasitically powered through its inputs, so the pin 1 check is
decisive rather than ambiguous.

### 2026-08-28 — continuity and U3 both clear

- Continuity checked MAX package → buffer → backplane. Copper is good.
- The select was scoped **at the backplane end and at the buffer output**. Both
  toggle.

**U3 is cleared.** It is powered and actively driving, and the signals reach
U2's pins. Combined with the working SD card proving CLK/MOSI/MISO to the
mezzanine, the entire path from RA3 to the MAX3421E package is now verified by
measurement rather than by inference.

That leaves the part itself, and exactly two things about it are still unproven.

### 1. ~~U2 has never been shown to be powered~~ — CLEARED 2026-08-28

3.3 V measured at the pads of the package. VCC and VL are present at U2.

The reasoning that made this worth checking is kept below, because it is still
the reason the *ground* side needs the same treatment.

#### Why it needed checking

`/USB_INT` reading 1 proves only that the mezzanine's 10 kΩ pull-up to 3V3
exists. It holds that net high with U2 dead, unpowered, or absent. Nothing in
any run so far has demonstrated that U2 has rails.

This matters more than it sounds, because of the RES pin note:

> The MAX3421E is internally reset if either VCC or VL is not present. The
> register file is not accessible under these conditions.

VL (U2.2) and VCC (U2.23) are the same +3V3 net on this design. Measure **at the
pins**, not at the rail or a nearby cap — a cold joint on a power pin reads
3.3 V on the plane and nothing at the package, which is precisely the fault that
would survive every test done so far.

### 2. The ground side of the package

**Not the exposed pad.** An earlier revision of this document called the EP the
prime suspect on the grounds that it is the part's primary ground. That is
wrong, and the datasheet pin table says so outright:

> Exposed Pad, Connected to Ground. **Connect EP to GND or leave unconnected.**
> EP is located on the bottom of the TQFN package.

An open EP cannot explain an unresponsive part. Do not reflow it — that is
hot-air rework with real risk of damaging the board, for no diagnostic value.

The ground that does matter is **U2.3 and U2.19** (`GND` and `GND__1`, both to
`#PWR018`). Measuring 3.3 V at the VCC/VL pads referenced to *board* ground
proves those two pads are fed; it says nothing about whether the die has a
ground return. If both GND pads are open the part is unpowered in the way that
matters while every voltage measurement looks perfect. Check continuity from
U2.3 and U2.19 to board GND.

### The INT drive test (firmware level 25)

Everything observed so far arrives through MISO, and MISO is silent — which is
equally consistent with "the part never hears us" and "the part is fine but
cannot answer". Those need separating, and the board offers exactly one other
pin to do it with: INT (U2.18), an **output** of the MAX3421E.

Writes need no MISO, so the part can be commanded blind. With `INTLEVEL = 0` the
datasheet makes INT "an edge active push-pull output", and Figure 12 gives its
*inactive* level as high for negative edge (`POSINT = 0`) and low for positive
edge (`POSINT = 1`). So POSINT selects a DC level the part actively drives —
independent of the oscillator, of USB traffic, and of any interrupt being
pending.

What makes it trustworthy: RA0's only pull is 10 kΩ to 3V3, so **a low on that
net cannot be produced by anything except U2 driving it**. A low is positive
proof; a stuck high is the negative result.

| Result | Meaning |
|---|---|
| `01` | Pass. U2 is powered and executing writes. A silent MISO is then U2.15 or its stub alone. |
| `03` | Stuck high. Nothing is reaching the part despite the signals arriving at its pins → power at the pins, or the exposed pad, or a dead die. |
| `00` / `02` | Stuck low / inverted. Unexpected; treat as a wiring fault on the INT net. |
| `FF` | The PIC's own SPI module gave up. |

### MISO may not have been covered by the continuity test

The continuity check ran "MAX package → buffer → backplane". **MISO is the one
SPI signal that does not go through the buffer** — U2.15 goes straight to the
`SPI_MISO` hierarchical label and out to the connector, with no U3 hop. So that
test path would not have traced it. Worth confirming explicitly: U2.15 to the
mezzanine connector's MISO pin.

This is a live candidate precisely because it is the failure that would leave
everything else measuring perfect: the part powered, selected, clocked and fed,
executing every write, and simply unable to answer.

#### 2026-08-28 — the part is alive. Link is marginal, not dead.

Two consecutive runs, no change in between:

```text
run 1                              run 2
  REVISION (boot)   00               REVISION (boot)   00
  /USB_INT          0  ASSERTED      /USB_INT          1  inactive
  live REV @125k    01               live REV @125k    E1
  live REV @1MHz    13               live REV @1MHz    13
  live REV @4MHz    A8               live REV @4MHz    01
  GPOUT @125k       07               GPOUT @125k       0F
  GPOUT @1MHz       0F               GPOUT @1MHz       0F
  GPOUT @4MHz       0F               GPOUT @4MHz       0F
  INT drive         01  PASS         INT drive         03  STUCK HIGH
```

**`13` is the rev-3 code from the R18 reset value, and it came back at 1 MHz in
both runs.** The MAX3421E is alive, powered, grounded, and communicating. The
problem was never a dead die.

**This retroactively corrects the `03` reading.** An earlier revision of this
document said a stuck-high INT drive test with good rails meant a dead part and
justified replacing U2. That was wrong and would have destroyed a working
board. `INT drive` reads `01` in one run and `03` in the next with nothing
changed between them — it is the same marginal link, sampled twice. **A single
sample of an intermittent connection is never grounds for condemning a part.**

The failures are also **not rate-ordered**: 1 MHz is clean while both 125 kHz
and 4 MHz garble. Timing problems degrade monotonically with clock rate, so this
is not the 4050, not the SPI mode and not the sample point. It is a contact.

### What changed between "nothing" and this

U2 was reflowed. That is the whole delta, and it localises the original fault to
the package's own joints rather than to anything on the board — every net,
buffer and rail had already measured good.

Worth knowing for the next pass: a reflow that moves a part from *completely
dead* to *marginal* usually means the joints are now partially wetted, and on a
fine-pitch package that is nearly always insufficient flux rather than
insufficient heat. Re-heating an already-reflowed joint mostly just cooks off
what flux remains and can make it worse. Add flux first, then reflow.

### Why the instrument had to change

`probe_revision_burst()` did 64 reads and reported the 64th, discarding the
other 63. On a bus that is right most of the time that is a coin toss, and it
cannot distinguish a dead link from a 95%-good one — both of which this board
produced within a minute of each other. The same flaw made `GPOUT` useless once
the link came alive: the mask ORs across 8 patterns, so a single glitch pins it
at `0F` forever.

Firmware level 26 fixes both:

- Revision bursts tally the three legal codes, return the **majority winner**
  and **how many of 64 reads produced it**. Majority also defeats the specific
  trap in this data — `01` is both a valid revision and a plausible corruption
  of `13`, and only the counts tell them apart.
- `GPOUT` packs the count of failing patterns (0-8) into the high nibble above
  the bit mask, so it keeps grading after the mask saturates.

`64 of 64` is a clean bus. Watching that number while reworking a joint is
feedback; watching a single hex byte is not.

### 2026-08-28 — resolved

```text
  bring-up status : 01  CONTROLLER READY
  MAX3421E REVISION: 13
  live REV @125k / @1MHz / @4MHz : 13 / 13 / 13
  GPOUT link@125k / @1MHz / @4MHz: 00 / 00 / 00   ok
  INT drive test : 01  PASS
```

Flux plus a second reflow of U2 did it. Forty-eight clean write/read round trips
across three clock rates, zero errors.

**`CONTROLLER READY` proves more than it says.** `hid_host_init()` only reaches
status 01 if `tuh_init()` returned true, which means `hcd_init()` completed
every step: PINCTL, the REVISION assert, CHIPRES, **the OSCOK poll**, MODE, bus
reset, HIEN, CPUCTL. That poll is the one step gated on the 12 MHz crystal, so
Y2 and its load caps are confirmed running — the last open hardware unknown,
closed without a separate test.

### Two independent faults, and why that made it confusing

This was never one problem:

1. **The firmware bootstrap could never succeed.** REVISION was read before
   `tuh_init()`, so before anything set FDUPSPI. On a board that buffers MOSI
   one way, a half-duplex read has nowhere to go. This was fatal on its own and
   would have kept the controller dead on a perfectly assembled board.
2. **U2 had cold joints.** Also fatal on its own.

Fixing (1) exposed (2) rather than fixing anything visible, which is why the
first flash of level 24 looked like no progress at all. Neither fault could be
seen past the other, and the whole middle section of this document is the cost
of that.

### What actually did the diagnostic work

- **The rate-swept probe.** Rate-independent failure ruled out the 4050, the
  SPI mode and the sample point in one run, and kept the search on contacts.
- **The INT drive test.** It commanded the part blind and watched its own output
  pin, using the one asymmetry available: RA0's only pull is 10k to 3V3, so a
  low there is unforgeable. It closed U2 ground and the INT return path across
  both connectors at once.
- **Majority counting.** Reporting one sample of a marginal link produced two
  opposite verdicts within a minute and nearly cost a working part.

## Next measurements, in order

1. Flash level 26 and bank a `64 of 64` baseline at each rate. Nothing is wrong
   at level 25, but 26 is the build that can *grade* the link if it ever drifts,
   and a known-good baseline is what makes a later regression obvious.
2. Move to the enumeration phase: dispatch `/USB_INT` and run `tuh_task()`.
### The 100% data-stack figure was a false alarm

This document previously flagged `-mstack=hybrid:512:0:0` reporting the data
stack at 100% as a risk to fix before enumeration. It is not a risk and there is
nothing to fix. XC8 reports the *reservation*, not the high-water mark, so the
figure reads 100% at every size:

```text
-mstack=hybrid:512     Data stack space used 200h ( 512) of  200h (100.0%)
-mstack=hybrid:1024    Data stack space used 400h (1024) of  400h (100.0%)
-mstack=hybrid:2048    Data stack space used 800h (2048) of  800h (100.0%)
```

Both sides of the ratio are just whatever was asked for. The number carries no
information about actual depth, and raising the size on the strength of it would
have been cargo cult. Actual depth under enumeration is still unknown, but there
is no evidence of a problem, so leave it at 512 and revisit only if the
enumeration phase actually misbehaves.

## Still Open

1. The three measurements above: U2 power, then `/IO_USB_CS` at both ends.
2. Once REVISION reads `13`, confirm `tuh_init()` gets past the OSCOK poll —
   that is the first thing that depends on the crystal rather than the SPI link.
3. `-mstack=hybrid:512:0:0` reports the data stack at 100%. Pre-existing, but
   `tuh_task()` and enumeration deepen the call chain — raise it before that
   phase rather than after it starts misbehaving.

## Closed

- `/USB_INT` level shifting into the 5 V PIC. RA0 reads the 3.3 V high
  correctly; no `INLVLA` change needed.
- U3 propagation-delay marginality. The rate-independent result rules it out.
- U3 as a dead or unpowered buffer. Scoped driving at its output.
- The `~IO_USB_CS` net, end to end. Scope plus continuity.
- Wiring design error. Traced across all three sheets; `SPI_CS0` is USB and
  `SPI_CS1` is SD consistently on both sides, and the firmware's port A map
  matches the real board pin for pin.
- The 12 MHz crystal, *for this symptom*. Register access does not use it.
- U2 power. 3.3 V measured at the package pads.
- A dead die. REVISION returns `13` at 1 MHz across repeated runs.
- U2 ground, and the INT return path across both connectors. The INT drive test
  read `01` at least once, which only U2 driving that net can produce.
- U2's joints. Reflowed with added flux; clean at all three rates since.
- The 12 MHz crystal, outright. `CONTROLLER_READY` requires passing the OSCOK
  poll inside `hcd_init()`.
- The exposed pad. The datasheet permits leaving it unconnected, so it cannot
  be the fault. Do not rework it.

---

# Phase 2: Enumeration (firmware level 27)

Opened 2026-08-29. Bring-up above is resolved; this section tracks getting a
keyboard enumerated and reporting.

## Design decisions

**`/USB_INT` is switched to LEVEL mode.** TinyUSB defaults `PINCTL.INTLEVEL` to
0, making INT an edge output whose pulse can be as short as 10.6 us. This
firmware has no interrupt handler — the main loop polls, and it can be inside a
bulk transfer or an SD write for milliseconds — so it would miss those pulses
outright and USB would simply stall. Level mode holds INT asserted until the
last pending IRQ is cleared, which a late poll cannot miss. The datasheet
requires an external pull-up for this mode and the board has one (R7, 10k to
3V3): the hardware was always wired for level mode, only the default was wrong.
Set via `tuh_configure(0, TUH_CFGID_MAX3421, ...)` before `tuh_init()`.

**`tuh_task()` runs in the idle branch only.** Enumeration is slow — descriptor
fetches, hub port resets, mandated settling delays — and the Z80 will not wait
that long for a reply on `/SIO1B_INT`. It runs where `sd_cache_tick()` runs:
after any command in flight has fully completed, never between a request and its
reply. `tuh_task()` itself does not block; with `CFG_TUSB_OS = OPT_OS_NONE` the
event queue read is documented as always behaving as a zero timeout.

**Boot protocol is automatic.** `hid_host.c` sets `_hidh_default_protocol =
HID_PROTOCOL_BOOT` and applies it during set_config, so keyboards arrive in the
fixed 8-byte layout with no report-descriptor parsing. `CFG_TUH_HID_EPIN_BUFSIZE`
was already 8, which matches exactly.

**`CFG_TUH_DEVICE_MAX` raised 1 → 2.** TinyUSB sizes its device table as
`CFG_TUH_DEVICE_MAX + CFG_TUH_HUB`, so 1 left exactly one slot for everything
downstream of the hub — a keyboard and nothing else, ever.

## KNOWN LIMITATION: low-speed devices behind the hub will not work

There is an FE1.1S hub (U1 on `USBPorts.kicad_sch`) between the MAX3421E and
every USB port. Reaching a **low-speed** device through a hub requires the host
controller to send PRE packets, which on the MAX3421E means setting
`MODE.HUBPRE` and `MODE.LOWSPEED` for those transfers.

**TinyUSB's MAX3421E driver does neither.** `MODE_HUBPRE` is declared in the
register enum at `hcd_max3421.c:112` and is never written anywhere in the tree.
`MODE_LOWSPEED` is only ever set from **root port** speed detection
(`hcd_max3421.c:866`), never switched per device — and the root port here is the
hub, which is full speed.

Consequences:

- A **full-speed** device behind the hub works normally.
- A **low-speed** device behind the hub enumerates (the hub reports its speed
  over the control pipe, which is full speed to the hub itself) but its
  interrupt endpoint will never transfer.

Most traditional USB keyboards are low speed. `HIDSTAT` therefore reports the
mounted device's speed, so this presents as a diagnosis rather than as a silent
stall. If a low-speed keyboard has to be supported, `hcd_max3421.c` needs
per-transfer mode switching: set `MODE_LOWSPEED | MODE_HUBPRE` before a transfer
addressed to a low-speed device behind a hub, and clear them after. The driver
already tracks the target `daddr` per endpoint, and `tuh_speed_get()` supplies
the speed, so the information needed is all present.

## What to look for

```text
  USB devices    : 2                     hub + keyboard
  keyboard addr  : 02  MOUNTED
  keyboard speed : 00  full speed - supported
  boot reports   : 0000 rising           the endpoint is actually being polled
  last report    : 00 00 04 00 00 00 00 00     'a' held down
```

A **rising** report count is the real proof: it means the interrupt endpoint is
being serviced, not merely that enumeration finished.

## Request payloads must set LEN

`external_sync_send()` puts exactly `frame->bytes[IOC_OFF_LEN]` payload bytes on
the wire, so a request field written into the mailbox without also setting LEN
is simply never transmitted. The receiver memsets the frame and fills only the
bytes that arrived, so the field reads back as zero — a silent, well-formed
wrong answer rather than an error.

This bit the page selector on its first outing: `HIDSTAT` set the page byte at
`tx_frame + 4` but left `tx_frame + 3` at zero, and the controller correctly
served page 0. Every other host tool in HelloWorld sets `tx_frame + 3` alongside
its payload; this is the same length contract the reply side has, in the other
direction.

## 2026-08-29 — nothing is on the USB bus

Page 1, with a keyboard plugged in:

```text
  port connected : 00
  MODE   (R27)   : C1      DPPULLDN|DMPULLDN|HOST, SOFKAENAB clear
  HIRQ   (R25)   : 09      BUSEVENT + SNDBAV; no CONDET
  HRSL   (R31)   : 03      JSTATUS = 0 and KSTATUS = 0  -> SE0
  USBIRQ (R13)   : 01      OSCOK
  task calls     : 60xx    the idle-branch placement runs
```

`HRSL` bits 7:6 are the finding. `JSTATUS = 0` and `KSTATUS = 0` means both data
lines are **low — SE0**. The MAX3421E pulls D+ and D- down via DPPULLDN/DMPULLDN
and nothing is pulling either up. A device announces itself by pulling D+ high;
that is the whole connect mechanism, and it is not happening. `SOFKAENAB` clear
and no CONDET in HIRQ say the same thing from two other angles.

The MAX3421E is behaving perfectly. The FE1.1S is not presenting itself upstream.

**This also closes the coexistence question.** `task calls` above 0x6000 proves
`hid_host_task()` is reached from the idle branch tens of thousands of times,
and HIDSTAT completes two full transactions per run, so `tuh_task()` in the main
loop does not disturb the SIO link.

### The hub's crystal load caps

C6/C7 (22 pF) on Y1 are unpopulated. Populate them.

The board contains its own control experiment: **Y1 and Y2 are the same part**
(`ABL-12.000MHZ-B2`) with the **same 22 pF pair** specified, and Y2's network is
populated and works — the MAX3421E reaches OSCOK. The FE1.1S application circuit
also specifies a 16 pF / 30-50 ppm crystal, and a part called out by its load
capacitance expects external loading.

The usual argument for omitting load caps is that they only shift frequency.
That is true and it is not the issue here. Unloaded, stray capacitance alone
(~5 pF) against an 18 pF-spec crystal pulls roughly **+500 ppm**, and USB full
speed allows **±2500 ppm** — so accuracy would not have broken enumeration even
with the caps absent. What load capacitance actually sets is the Pierce loop's
phase condition and gain margin, so the failure mode of omitting it is that the
oscillator **does not start at all**, or starts only at some temperatures. That
is precisely the observed symptom.

Scope U1.2 (XOUT) before reworking, to confirm. Probe XOUT rather than XIN --
XIN is the high-impedance side and a probe there can stop a marginal oscillator
outright, producing a misleading result.

**Use roughly 100 ns/div.** One cycle at 12 MHz is 83 ns. A first attempt at
10 ms/div showed a ~100 Hz sawtooth, which is not a measurement of anything: at
that timebase the scope is undersampling by six orders of magnitude and folding
the signal into a slow alias, which characteristically looks like a sawtooth.

### Measurements on the hub

| Pin | Signal | Measured | Meaning |
|---|---|---|---|
| U1.17 | XRSTJ | 3.3 V | not held in reset |
| U1.21 | VD33F | 3.3 V | internal regulator up, part has rails |
| U1.18 / U1.20 | VBUSM / VDD5 | tied +5V | hub is told VBUS is present, so it has no reason to withhold its pull-up |
| U1.2 | XOUT | unreadable (aliased) | inconclusive so far |

So the hub is powered, out of reset, and correctly told there is a host --
and still presents nothing upstream. That is how a part with no clock behaves.
Together with the identical working Y2/C9/C10 network on the same board, the
unpopulated load caps are the strong hypothesis even without a usable scope
trace.

## 2026-08-29 — hub is on the bus; enumeration times out

C6/C7 populated (2 x 10 pF stacked per position, 22 pF not to hand):

```text
  port connected : 01
  root speed     : 00      full speed
  MODE   (R27)   : C9      SOFKAENAB now SET
  HIRQ   (R25)   : 48      FRAMEIRQ -- SOF is being generated
  HRSL   (R31)   : 8E      JSTATUS = 1, result nibble E = TIMEOUT
```

The crystal was the fault. The hub now presents itself, the MAX3421E sees
J-state, and SOF frames are running. What remains is that the hub does not
answer packets.

That split is itself diagnostic: holding D+ high is nearly static once the
pull-up is enabled, while *responding to packets* needs a stable 12 MHz. Seeing
the first without the second is what a marginal oscillator looks like -- and the
oscillator was observed bursting and quenching before the caps went in.

### But there was also a real firmware bug with the same signature

`tusb_time_delay_ms_api()` was not implemented by this port, so TinyUSB's
default in `tusb.c` was used:

```c
const uint32_t time_ms = tusb_time_millis_api();
while ((tusb_time_millis_api() - time_ms) < ms) {}
```

That is only as good as the clock's granularity, and ours ticks every 10 ms. So
`t0` is always a tick boundary and a requested 10 ms elapses on the very next
tick -- possibly 100 us later. USB requires 10 ms of reset recovery before a
device will answer, so honouring it as ~0 ms means addressing a device that is
not listening yet. The result is `HRSL_TIMEOUT`, indistinguishable from absent
hardware.

The port now supplies `tusb_time_delay_ms_api()`, rounding up to whole ticks and
adding one more so the wait can only ever be too long (by under 20 ms), never
too short. XC8 does not honour `TU_ATTR_WEAK`, so the default in `tusb.c` is
guarded with `#if !defined(__XC8)`, matching the treatment the weak stubs in
`class/hid/hid_host.c` already have.

### CORRECTION: tuh_task() does block

An earlier note in this document said `tuh_task()` does not block, reasoning
from `osal_queue_receive` being a zero-timeout read under `OPT_OS_NONE`. That is
true of an idle pass and false of an enumerating one: the delay API above is a
busy-wait, and `ENUM_DEBOUNCING_DELAY_MS` is **150 ms**. A `tuh_task()` pass
that is enumerating can hold the main loop for that long.

This is survivable, but for a specific reason rather than by luck: `/SIO1B_INT`
is a level the Z80 holds until acknowledged, so a request arriving inside the
window is delayed rather than lost -- the same property the SD cache flush
already depends on. It is bounded, and it happens only during enumeration.

### The INT drive test now declines to answer when USB is live

It read `02 "inverted"` on the first run with a hub attached. That was the test
being wrong, not the hardware: once USB is up, FRAMEIRQ alone asserts INT every
millisecond, so the pin no longer reflects POSINT. It now returns `FEh` and says
so. A diagnostic that produces confident nonsense once the system starts working
is worse than one that declines.

## 2026-08-29 — "USB devices: 0" was a blind instrument

After the delay fix, `HRSL` went `8E` -> `80`: result nibble `E` (TIMEOUT) to `0`
(SUCCESS), `JSTATUS` still set. Transfers to the hub complete. That also retires
the marginal-crystal worry — a part with an unstable clock cannot answer packets.

But `USB devices : 0` persisted, and that reading was **wrong by construction**.
From `usbh.c:1935`:

```c
if (is_hub_addr(dev_addr)) {
  TU_LOG_USBH("HUB address = %u is mounted\r\n", dev_addr);
} else {
  tuh_mount_cb(dev_addr);   // only for non-hubs
}
```

`tuh_mount_cb()` is **never called for hubs**, and the counter incremented only
there. A fully enumerated, perfectly working hub reads as zero devices. The
instrument was blind to the one device on the bus.

Replaced with `mounted addrs`, a bitmap built from the stack's own
`tuh_mounted()` over every address. Hub addresses start above
`CFG_TUH_DEVICE_MAX`, so with DEVICE_MAX = 2 the hub is address 3 and bit 2 is
the hub's own mount state.

## 2026-08-29 — enumeration stops before the first descriptor

Level 30 added milestone counters, via `tuh_event_hook_cb()` (which fires on
every event the stack queues) and the two enumeration descriptor callbacks:

```text
  mounted addrs  : 00
  attach events  : 02
  remove events  : 00
  device descr   : 00
  config descr   : 00
  HRSL   (R31)   : 80     success
  MODE   (R27)   : C9     SOFKAENAB set
```

So the connect event reaches the stack — twice — and `GET_DESCRIPTOR(device)`
never returns. The failure is between the attach event and the first descriptor.

Counters saturate at `0xFF` rather than wrapping, because the meaningful
distinction is zero versus non-zero and a wrapped counter reading `00` would lie
in exactly the place it matters.

### Hypothesis A: a control transfer is being rejected, silently

`tuh_control_xfer()` has a pre-existing XC8 branch in this tree:

```c
if (xfer->complete_cb != NULL) {
  TU_ASSERT(usbh_setup_send(...));
} else {
#if defined(__XC8)
  // This port deliberately uses the asynchronous control-transfer API.
  // XC8 cannot take the address of the reentrant local used below.
  ctrl_info->stage = CONTROL_STAGE_IDLE;
  return false;
#else
  ... blocking spin ...
#endif
}
```

Any enumeration step that issues a control transfer **without** a completion
callback therefore does nothing and returns false, silently. `hub.c` has at
least one blocking-looking helper (`hub_port_get_status_local`) on the
enumeration path, so this needs checking rather than assuming.

Note the non-XC8 branch would deadlock this port anyway: it spins calling only
`tuh_task()`, never `hcd_int_handler()`. Every normal port dispatches that from
a hardware ISR; ours only calls it from `hid_host_task()` in the main loop,
which is precisely what would be blocked. The XC8 guard accidentally protects
us from a hang, at the cost of a silent failure.

### Hypothesis B: the root-port reset sequence

`enum_new_device()` for a root-port device does: 150 ms debounce ->
`hcd_port_reset()` -> `ENUM_RESET_ROOT_DELAY_MS` -> `hcd_port_reset_end()` ->
re-check `hcd_port_connect_status()` -> `process_enumeration(ENUM_ADDR0_DEVICE_DESC)`.
All three delays are busy-waits, during which `hcd_int_handler()` is not called,
so any interrupt raised by the bus reset is deferred. Whether that matters
depends on `handle_connect_irq()`, which has not been read yet.

### Next instrument

Record the last enumeration state reached, straight from `process_enumeration()`.
That names the failing step rather than inferring it. The state values:

```text
 0 IDLE                      7 GET_DEVICE_DESC
 1 HUB_RERSET                8..15 GET_STRING_*
 2 HUB_GET_STATUS_AFTER_RESET   16 GET_9BYTE_CONFIG_DESC
 3 HUB_CLEAR_RESET             17 GET_FULL_CONFIG_DESC
 4 HUB_CLEAR_RESET_COMPLETE    18 SET_CONFIG
 5 ADDR0_DEVICE_DESC           19 CONFIG_DRIVER
 6 SET_ADDR
```

Plus a count of control transfers rejected by the XC8 branch above, which
directly tests Hypothesis A.

## XC8 and TinyUSB weak symbols

XC8 does not honour `TU_ATTR_WEAK`, so every weak default the port needs to
override must be guarded `#if !defined(__XC8)` in the vendored source. This has
now been needed in four places:

- `class/hid/hid_host.c` — the HID callbacks (pre-existing)
- `host/usbh.c` — `usbh_app_driver_get_cb`, `tuh_mount_cb`, `tuh_umount_cb`
  (pre-existing)
- `tusb.c` — `tusb_time_delay_ms_api`
- `host/usbh.c` — `tuh_enum_descriptor_device_cb`,
  `tuh_enum_descriptor_configuration_cb`, `tuh_event_hook_cb`

If a fifth is needed, these should be collected into a single patch file against
the vendored tree rather than left as scattered edits, so a TinyUSB update does
not silently drop them.

## 2026-08-29 — bisected to a dropped completion inside the driver

Three instrumented rounds, each narrowing by one layer. Same result with a
keyboard plugged in or not, which is consistent: we are stuck enumerating the
**hub**, long before any downstream port is powered, so nothing downstream can
matter yet.

### Level 31 — the state machine is entered, and Hypothesis A is dead

```text
  last enum state : 05     ENUM_ADDR0_DEVICE_DESC
  enum failures   : 00
  ctrl rejected   : 00
  device descr    : 00
```

`process_enumeration()` runs, at the first descriptor step. `ctrl rejected = 00`
kills Hypothesis A outright: no control transfer was refused for lacking a
completion callback. `enum failures = 00` means it was never re-entered with a
failure either — so it is not a retry loop. It is entered **once** and never
called again in any form.

### Level 32 — the transfer completes in hardware, successfully

```text
  HXFRDN seen    : 01
  xfer_done runs : 01
  ep lookup fail : 00
  HRSL at done   : 80     JSTATUS set, result nibble 0 = SUCCESS
```

So the SETUP packet was sent, the controller raised transfer-done exactly once,
`handle_xfer_done()` ran, `find_opened_ep()` succeeded, and the result was
success. A control transfer needs three transactions — SETUP, DATA IN, STATUS —
and only one ever happens.

### Level 33 — the completion is dropped inside the driver

```text
  setups started : 1     xfer events up: 0
```

`hcd_setup_send()` was called once; **no `HCD_EVENT_XFER_COMPLETE` was ever
queued**. So `handle_xfer_done()` processed a successful SETUP and did not call
`xfer_complete_isr()`. Everything above the host controller driver is exonerated.

### The contradiction

For a SETUP, `handle_xfer_done()` takes the OUT branch and decides:

```c
if (xact_len < ep->packet_size || ep->xferred_len >= ep->total_len) {
  xfer_complete_isr(...);          // report completion
} else {
  xact_out(...);                   // "more to transfer"
}
```

and `hcd_setup_send()` immediately before it sets:

```c
ep->total_len = 8;
ep->xferred_len = 0;
```

`xact_len` is 8 for a SETUP, so `xferred_len` becomes 8 and `8 >= 8` is true —
the completion branch **must** be taken. It is not. One of the values the code
runs on is therefore not the value the source says it is.

Candidates worth keeping in mind while reading the page 2 data:

- `ep_dir` computed as IN rather than OUT, which routes to a branch that
  re-issues HXFR and never completes. That branch is silent, which fits.
- `_hcd_data.hxfr_bm` not overlaying `_hcd_data.hxfr` as intended under XC8 —
  a bitfield/union layout problem would corrupt `ep_num` and the direction bits
  together.
- `find_opened_ep()` returning a *different* endpoint than the one
  `hcd_setup_send()` prepared. It returned non-NULL, but non-NULL is not the
  same as correct.

Static reading has gone as far as it usefully can. Level 34 captures the actual
values at the branch.

### Transport ceiling reached

`IOC_COMMAND_MAX_DATA` is `IOC_FRAME_SIZE - IOC_OFF_PAYLOAD - 2` = **26 bytes**,
not 28 — the CRC takes the last two. Page 1 hit that ceiling at level 33, with
the started/reported counters packed into nibbles to fit the final byte.

Further instrumentation therefore goes on **page 2** rather than displacing
evidence from page 1. Retiring counters that currently read constant would be
the cheaper move and the wrong one: their being constant is a result, and
deleting them would make a regression invisible.

Page 2 reports what `handle_xfer_done()` branched on: `hxfr`, `ep_dir`,
`peraddr`, `ep_num`, `packet_size`, `total_len`, `xferred_len`, `ep_state`,
`xact_len`, and a branch code (1 = completed OUT/SETUP, 2 = took `xact_out`,
3 = re-issued HXFR on the IN path, 4 = completed IN, 0 = never reached).

## 2026-08-29 — Level 34 proves the driver completion branch is correct

The page 2 capture returned exactly the values predicted for a successful
address-zero SETUP:

```text
HXFR reg       : 10
ep_dir         : 00
PERADDR        : 00
ep_num         : 00
packet_size    : 08
total_len      : 0008
xferred_len    : 0008
ep_state       : 03
xact_len       : 08
branch taken   : 01     completed
```

This kills all three remaining endpoint-state hypotheses.  The HXFR union is
laid out correctly, `find_opened_ep()` returned the EP0 that
`hcd_setup_send()` prepared, and the length comparison selected
`xfer_complete_isr()`.  The lost completion is below that branch.

### Generated-code clue: the event object aliases its callee's arguments

The XC8 symbol file shows a concrete violation of the source-level lifetime of
the completion event:

```text
hcd_event_xfer_complete...@event      053Ch..0544h  (9 bytes)
osal_queue_send...@success            053Ch
tu_fifo_write@f                       053Bh..053Ch
tu_fifo_write@data                    053Dh..053Eh
```

`hcd_event_xfer_complete()` constructs its local `hcd_event_t` at `053Ch`, then
passes its address through `hcd_event_handler()` and `queue_event()`.  XC8 uses
the non-reentrant static-auto model for these functions and has overlaid the
still-live event with storage belonging to the nested queue call.  Preparing
the FIFO call therefore overwrites the event before `tu_fifo_write()` copies
it.  In particular, `tu_fifo_write@data` aliases the event's `event_id` and
`dev_addr` bytes.  That explains both observations at once: the MAX3421 driver
takes the completion branch, but no valid `HCD_EVENT_XFER_COMPLETE` reaches the
queue or event hook.

The likely reason is that TinyUSB's header helpers are written as
`always_inline static inline`.  XC8 does not honour the same inlining model and
emits out-of-line non-reentrant functions, but its overlay analysis does not
preserve the helper's local object across the deeper call chain.

### Level 35 test fix

For XC8 only, `queue_event()` will first copy the caller-owned event to one
file-static staging object and queue from that stable address.  This firmware
has no USB ISR and calls the host stack only from the foreground idle path, so
queue submissions cannot overlap; one staging object is sufficient.  The
change leaves TinyUSB's queue, event format and all non-XC8 builds unchanged.

Expected result after flashing level 35: the first completion count rises,
enumeration advances beyond state `05`, and page 2 begins showing the later
DATA/STATUS transactions.  If it does not, the same diagnostics remain in
place and the next boundary is entry into `hcd_event_xfer_complete()` versus
successful `tu_fifo_write()`.

Level 35 builds successfully.  The post-fix symbol/assembly check places the
staging object at `07D3h..07DBh` and emits the nine-byte copy before preparing
any queue-call arguments.  The nested FIFO storage remains in COMRAM around
`053Bh`, so it can no longer overwrite the object actually passed to the FIFO.
Program use is 56,337 of 131,072 bytes and data use is 7,004 of 12,800 bytes.
The pre-existing unbounded hardware-stack warning remains; this change neither
adds a callback level nor attempts to address that separate warning.

## 2026-08-29 — Level 35 reaches hub-driver configuration

The hardware result after the event-staging fix is a major boundary advance:

```text
device descr     : 01
config descr     : 01
last enum state  : 13h    ENUM_CONFIG_DRIVER (decimal 19)
enum failures    : 00
ctrl rejected    : 00
HXFRDN seen      : 28h
xfer_done runs   : 28h
ep lookup fail   : 00
HRSL at done     : A5h    result nibble 5 = STALL

HXFR             : 20h    OUT token
PERADDR          : 03h    enumerated hub
ep_dir / ep_num  : 00h / 00h
packet_size      : 40h    EP0 max packet size 64
total_len        : 0001h
```

This confirms that level 35 fixed the completion path: the device descriptor,
full configuration descriptor, address assignment and `SET_CONFIGURATION` all
completed.  The stop is now inside the hub class driver's `set_config` sequence,
after it has read the hub descriptor and powered the ports.

The final transfer shape is diagnostic.  At that point TinyUSB calls
`hub_edpt_status_xfer()` to arm the hub's one-byte interrupt-IN endpoint.  The
trace instead shows a one-byte **OUT on EP0**.  That is exactly what the MAX3421
driver produces if `hub_interface_t.ep_in` contains zero: endpoint zero has a
64-byte packet size, `hcd_edpt_xfer()` changes its control direction to OUT, and
the hub correctly stalls an ordinary OUT token that was not preceded by a
SETUP.  The `xact_len` and branch fields on this page are stale from the prior
successful transaction because the error path completes before updating them.

### Generated-code proof of the second XC8 overlay

`hub_open()` obtains the interrupt endpoint descriptor, calls
`tuh_edpt_open()`, then reads `desc_ep->bEndpointAddress` to retain the address
for polling.  XC8 assigned these locations:

```text
hub_open@desc_ep       0536h..0537h
tuh_edpt_open@desc_ep  0535h..0536h
```

The generated call setup copies the caller's two-byte pointer into the callee's
argument area in increasing order.  Its second store writes the pointer's high
byte to `0536h`, overwriting the low byte of the caller's still-live `desc_ep`.
The nested open therefore succeeds using the callee copy, but the post-call
read uses a damaged pointer and stores `00h` instead of the FE1.1 descriptor's
`81h` interrupt endpoint.  The subsequent `OUT EP0, len 1` and STALL follow
directly; no hub or bus behaviour needs to be inferred.

### Level 36 test fix

For XC8 only, `hub_open()` now captures `bEndpointAddress` in a file-static byte
before calling `tuh_edpt_open()` and uses that stable byte afterward.  USB host
service is foreground-only on this port, so there is no concurrent hub-open
operation.  Other compilers retain the upstream code unchanged.

Expected result after flashing level 36: the hub status transfer is armed as
endpoint `81h`/IN instead of EP0/OUT, the hub completes enumeration, and a
downstream keyboard can begin its own attach and enumeration sequence.

Level 36 builds successfully.  The stable endpoint byte is at `0653h`, outside
the overlapping COMRAM call areas.  Generated assembly reads the endpoint
descriptor into that byte before preparing `tuh_edpt_open()`'s arguments, and
reads only the stable byte when assigning `p_hub->ep_in` after the call.
Program use is 56,343 of 131,072 bytes and data use is 7,005 of 12,800 bytes.
The existing unbounded hardware-stack warning remains unchanged.

### Level 36 hardware result: unchanged

The level 36 hardware capture is byte-for-byte identical to level 35, including
`HXFR=20h`, `PERADDR=03h`, EP0/OUT, length 1 and `HRSL=A5h`.  The generated-code
overlap was real, but preserving `desc_ep` did not alter the endpoint that
ultimately reached the MAX3421 driver.  It is therefore not sufficient evidence
that the post-call descriptor read was the source of the zero endpoint; that
causal claim is withdrawn.

Level 37 extends page 2 with breadcrumbs at the source boundaries:

```text
hub open ep       descriptor address captured by hub_open()
hub ep preclaim   p_hub->ep_in before usbh_edpt_claim()
hub ep postclaim  p_hub->ep_in after that nested call
submit address/ep arguments at entry to hcd_edpt_xfer()
last SETUP        most recent eight-byte control request
```

This distinguishes four cases in one run: bad configuration parsing, corruption
of retained hub state, corruption across the claim/submit wrappers, or a valid
non-control endpoint submission followed by corruption inside the MAX3421
driver.  The SETUP bytes also distinguish a real one-byte OUT control data stage
from the hub's one-byte interrupt-status transfer.

Level 37 firmware and the matching `HIDSTAT.COM` build successfully.  The five
single-byte handoff taps are in dedicated BANK6 storage and the eight SETUP
bytes are in BANK7, separate from every caller/callee argument area they are
measuring.  Program use is 56,766 of 131,072 bytes and data use is 7,018 of
12,800 bytes.  The updated COM file is also staged in the CP/M A/0 image tree.
The existing unbounded hardware-stack warning remains unchanged.

### Level 37 hardware result: endpoint lost in retained hub state

The level 37 capture reports:

```text
hub open ep       81
hub ep preclaim   00
hub ep postclaim  00
submit address    03
submit endpoint   00
last SETUP        23 03 08 00 04 00 00 00
```

The FE1.1 configuration descriptor is therefore parsed correctly and
`hub_open()` sees its interrupt-IN endpoint `81h`.  The value has become zero
in `hub_interface_t.ep_in` before `hub_edpt_status_xfer()` calls the endpoint
claim routine; the claim and MAX3421 submission wrappers merely propagate that
zero.  The final SETUP packet is also valid: class/other `SET_FEATURE`,
`PORT_POWER`, port 4, no data.  This rules out a malformed control data stage
and confirms that the subsequent one-byte EP0/OUT transaction is the hub
status poll using a lost endpoint address.

The generated map places `hub_itfs` at `07CCh..07D3h` and the last-SETUP trace
at `07DCh..07E3h`; they do not overlap.  Generated code for the hub-descriptor
callback writes only offsets 2 and 3 of `hub_interface_t`, not the endpoint at
offset 1.  The remaining ambiguity is whether the earlier uninitialised XC8
scratch byte fails to survive the nested endpoint-open call or the correctly
stored hub byte is overwritten later.

### Level 38 targeted fix and boundary test

Level 38 removes the uninitialised private scratch byte and assigns
`hub_interface_t.ep_in` from the initialized BANK6 capture that the level 37
hardware result proved still holds `81h`.  It also changes the redundant
post-claim breadcrumb into `hub after open`, a snapshot read directly from
`hub_interface_t.ep_in` immediately after the assignment.

Expected interpretation of the next capture:

```text
hub open ep     hub after open   hub ep preclaim   meaning
81              81               81                endpoint retained; hub poll should use 81h
81              81               00                a later operation overwrites hub state
81              00               00                assignment/addressing itself is still wrong
```

No USB request, enumeration order, timeout or MAX3421 transaction logic is
changed by this patch.

Level 38 firmware and the matching `HIDSTAT.COM` build successfully.  Inspection
of the generated PIC18 assembly confirms that `hub_open()` copies
`usbh_xc8_hub_open_ep` directly into offset 1 of the hub object, then reads that
same object byte into `usbh_xc8_hub_state_after_open`.  `hub_itfs` remains at
`07CCh`, the two diagnostic bytes are at `06D7h` and `06D9h`, and the SETUP
trace remains at `07DCh`; there is no range overlap.  The existing TinyUSB/XC8
warnings, including the unbounded hardware-call-stack warning, are unchanged.

### Level 38 hardware result: correct store, later loss

The level 38 hardware result is:

```text
hub open ep       81
hub after open    81
hub ep preclaim   00
submit address    03
submit endpoint   00
last SETUP        23 03 08 00 04 00 00 00
```

The endpoint assignment itself is now proven correct: the actual hub object
contains `81h` immediately after `hub_open()`.  It changes to zero later, before
the first hub interrupt-status claim.  This eliminates the descriptor pointer,
the replacement capture byte, and the immediate hub-object store as causes.

The remaining interval contains `hub_set_config()`, GET_HUB_DESCRIPTOR
completion, and four port-power control transfers.  Source and generated-code
inspection still show no intended write to `ep_in` in that interval.  A second
possibility is that `hub_open()` wrote a different hub object because its
device address was damaged across the nested endpoint-open call; the immediate
snapshot would then read back `81h` from that same wrong object while later
callbacks correctly address the still-zero object for device 3.

### Level 39 hub lifecycle trace

Level 39 adds HID status page 3 so one hardware run distinguishes the remaining
cases.  It reports:

```text
init and close call counts
hub_open device address before and after tuh_edpt_open()
hub object pointer selected by hub_open()
parsed endpoint and state immediately after open
state on entry to hub_set_config()
state before and after storing hub-descriptor fields
state on completion of port-power requests 1 through 4
state immediately before endpoint claim
the final raw eight-byte hub object
last hub_close() address
```

This page is observational.  It does not restore the endpoint, alter a request,
or change enumeration order.  Level 39 firmware and `HIDSTAT.COM` build
successfully and the COM file is staged in the CP/M A/0 image tree.  In this
build `hub_itfs` is `07BCh..07C3h`, the 25-byte trace is `07C4h..07DCh`, and the
last-SETUP trace is `07E5h..07ECh`; the ranges do not overlap.  The expected
hub-object pointer printed by HIDSTAT is therefore `07BCh`.

### Level 39 hardware result: the hub object pointer is wrong

```text
  open addr entry: 03      dev_addr correct on entry
  open addr post : 00      dev_addr is ZERO after tuh_edpt_open()
  open object ptr: 07A4    but hub_itfs is at 07BC in this build
  parsed ep      : 81
  after open     : 81
  at set_config  : 00
  descriptor pre/post: 00 / 00
  before claim   : 00
  raw hub object : 00 00 04 32 00 00 00 00
```

The arithmetic closes it. `get_hub_itf()` is

```c
return &hub_itfs[daddr-1-CFG_TUH_DEVICE_MAX];
```

With `CFG_TUH_DEVICE_MAX = 2`: `daddr = 3` gives `hub_itfs[0]` = `07BC`, and
`daddr = 0` gives `hub_itfs[-3]` = `07BC - 3*8` = **`07A4`** — exactly the
pointer reported. `sizeof(hub_interface_t)` is 8.

So `hub_open()` stored `81h` twenty-four bytes **before** the array, and
`after open` read `81h` back from that same out-of-bounds object. Every later
callback runs with an intact `dev_addr = 3` and correctly addresses the real
`hub_itfs[0]`, where `ep_in` was never written. The raw object confirms the
split: offsets 2 and 3 hold `04` (FE1.1 port count) and `32h`
(`bPwrOn2PwrGood`), written correctly by the descriptor callback, while `ep_in`
at offset 1 is still zero.

This is the alternative recorded at the end of the level 38 entry, and it is
now measured rather than suspected. It is also the same XC8 defect as the two
before it: a caller's still-live storage overlaid with a callee's argument area
across a nested call.

### Level 40 fix

`hub_open()` saves `dev_addr` before `tuh_edpt_open()` and restores the
parameter immediately after, so every later use — `get_hub_itf()` included —
sees the real address. The damaged value is still recorded into the trace
**before** the repair, so `open addr post` remains a measurement of whether XC8
still clobbers it rather than becoming a value the fix manufactures.

Expected next capture: `open object ptr` becomes `07BC`, `hub ep preclaim`
becomes `81`, and the hub status poll is submitted as endpoint `81h`/IN instead
of EP0/OUT with `HRSL = A5h` (STALL).

### Level 40 hardware result: hub state is correct end to end

```text
  open addr entry: 03      open addr post : 00     (still clobbered, as expected)
  open object ptr: 07BC    was 07A4
  parsed ep      : 81      after open     : 81
  at set_config  : 81      descriptor pre/post: 81 / 81
  port 1..4 complete: 81 81 81 81
  before claim   : 81      hub ep preclaim: 81
  submit address : 03      submit endpoint: 81
  raw hub object : 00 81 04 32 00 00 00 00
```

Every predicted value landed. `ep_in` now survives the whole hub lifecycle, and
the status poll is submitted as endpoint `81h`/IN instead of EP0/OUT.

`open addr post` still reads `00`, which is the intended outcome: XC8 continues
to clobber the parameter and the explicit restore is what carries the address.
Recording the damaged value before repairing it keeps that line a measurement
rather than a value the fix manufactures — if a future toolchain change makes
the corruption go away, this line will say so.

### HIDSTAT paging

The full dump outgrew one screen, which made the newest data scroll off exactly
when it mattered. `HIDSTAT` now takes a page argument:

```text
HIDSTAT      bring-up snapshot only (default)
HIDSTAT 1    USB debug
HIDSTAT 2    transfer decision
HIDSTAT 3    hub lifecycle
HIDSTAT A    everything, the previous behaviour
```

Page selection is parsed from the CP/M command tail at 0080h. Requesting a
detail page skips the pages before it, so each fits a screen on its own.

## 2026-08-29 — HUB ENUMERATED

```text
  mounted addrs  : 04     bit 2 set
  attach events  : 29     41 decimal
  remove events  : 00
  device descr   : 01     config descr : 01
  last enum state: 13     ENUM_CONFIG_DRIVER
  HXFRDN / xfer_done : 28 / 28      ep lookup fail : 00
  HRSL at done   : 80
```

The hub is enumerated at address 3. That closes the bring-up chain end to end:
SPI link, controller, its oscillator, the hub's missing crystal load caps, and
three separate XC8 overlay defects.

### The next failure is a different one

41 attach events, zero removes, and `last enum state` still `13` — the hub's own
final step. Any downstream enumeration would have moved that to `01`-`05` (the
`HUB_*` states or `ADDR0_DEVICE_DESC`). So `process_enumeration()` is never
entered for the device behind the hub.

`device descr` and `config descr` are both `01`, which are the hub's own. The
41 unbalanced attaches fit a port change-bit that is never cleared: the hub
re-reports the same connection on every status poll, and each one queues another
attach that goes nowhere.

That localises to one statement, the behind-hub branch of `enum_new_device()`:

```c
TU_VERIFY(dev0_bus->hub_port != 0);
TU_ASSERT(hub_port_get_status(dev0_bus->hub_addr, dev0_bus->hub_port, NULL,
                              process_enumeration, ENUM_HUB_RERSET));
```

Either of those aborts before the state machine is entered, and both failures
look identical from outside — indistinguishable from "never attempted".

### `xfer events up` is broken instrumentation, not evidence

It reads `0` after 40 completed transfers. The path was checked:
`hcd_event_handler()` falls through to `queue_event()` unconditionally, and
`queue_event()` always calls `tuh_event_hook_cb()`. So XFER_COMPLETE events do
reach the hook and the counter should be saturated.

Do not read anything into that nibble. The `setups started` half of the same
byte is fine. Most likely suspect is the `uint32_t eventid` parameter, on this
toolchain's record with argument passing — but it has not been chased, because
it is a diagnostic defect and not on the path to a working keyboard.

### Level 41: page 4

Reports whether that branch is reached, with what arguments, and what the call
answered:

```text
branch entries   times the behind-hub branch ran
hub address      dev0_bus->hub_addr at the call site
hub port         dev0_bus->hub_port
get_status ret   FFh never reached the branch
                 FEh reached, but hub_port was 0 (TU_VERIFY aborted)
                 00h hub_port_get_status() refused
                 01h accepted -- enumeration should have started
```

The return value is captured before `TU_ASSERT` swallows it. All four existing
pages are at the 26-byte transport ceiling, so this is a fifth page rather than
displaced evidence.

`HIDSTAT 4` prints it.

### Level 41 result: the branch is never reached, and the attach count was a lie

```text
  branch entries : 00
  hub address    : FF
  hub port       : FF
  get_status ret : FF     BRANCH NEVER REACHED
```

`enum_new_device()` is never called for the 41 attaches. It cannot be taking the
*root* branch either — that ends in `process_enumeration(ENUM_ADDR0_DEVICE_DESC)`
and would have moved `last enum state` to `05`, which is still `13`.

The explanation is at `usbh.c:654`:

```c
if (_usbh_data.enumerating_daddr == TUSB_INDEX_INVALID_8) {
  _usbh_data.enumerating_daddr = 0;
  enum_new_device(&event);
} else {
  // currently enumerating another device
  const bool is_empty = osal_queue_empty(_usbh_q);
  queue_event(&event, in_isr);      // re-queues the SAME event
  if (is_empty) { return; }
}
```

If `enumerating_daddr` is not `TUSB_INDEX_INVALID_8`, every attach takes the
defer path and is **put back on the queue**. And `queue_event()` calls
`tuh_event_hook_cb()` — which is the counter's only input.

**So "41 attach events" was never 41 attaches.** It is one attach event being
re-queued indefinitely, counted once per lap. That single fact accounts for all
four observations at once: the unbounded attach count, the zero removes, the
branch never being reached, and the enum state frozen at the hub's own
completion.

This is worth recording as a lesson about the instrument rather than the bug: a
counter placed on a queue-submission path counts submissions, not events, and
the two diverge exactly when something starts looping. The counter was not
wrong; the reading of it was.

`enum_full_complete()` is what releases the gate, and the hub *is* mounted, so on
a plain reading it should have run. Level 42 measures the gate instead of
reasoning about it.

### Level 42: page 4 additions

```text
enumerating      live _usbh_data.enumerating_daddr; FFh = idle and ready
defer count      times the attach path took the defer branch
enum completes   enum_full_complete() calls
attach hub addr  connection.hub_addr of the last attach event
attach hub port  connection.hub_port of the last attach event
```

`enumerating` is read live through an accessor rather than snapshotted, so it
reports the gate's state at the moment HIDSTAT asks.

Interpretation:

| enumerating | completes | meaning |
|---|---|---|
| `FF` | any | gate is idle; the defer path is not the problem after all |
| not `FF` | `00` | `enum_full_complete()` never ran despite the hub mounting |
| not `FF` | non-zero | it ran and the gate was re-armed afterwards, or the write was lost |

`attach hub addr` also says whether the pending attach is from the hub
(non-zero, a downstream port) or the root port.

## The systemic alternative: turn XC8's overlay allocator off

This is the fourth instance of one defect. XC8's static-auto model allocates
locals and parameters statically and overlays them using its call graph — and
its call graph for this codebase is known-bad, which is exactly what the
standing `(1393) ... estimated stack depth: unknown (due to recursion)` warning
reports. TinyUSB's function-pointer driver tables look cyclic to it, so the
overlay analysis is unsound, so it reuses storage that is still live. The
warning and the corruption are the same problem, not two.

`-mstack=software` removes the overlay entirely by putting locals on a real
stack. **It builds**, after two one-line fixes: `hcd_max3421.c` and `tusb.c`
each launder a pointer through `(uintptr_t)` purely to silence a const warning,
and XC8 cannot codegen that cast under this model. Casting directly is
equivalent, and those two edits are already applied.

Measured cost:

| | hybrid | software |
|---|---|---|
| Program | 42.4% (55,556) | 54.4% (71,329) |
| Data | 54.6% (6,983) | 52.3% (6,694) |
| Software stack | 512 | 5,886 |

Data space actually *falls*, because overlaid statics become stack. But
`6,694 + 5,886 = 12,580` of 12,800 bytes is **98% of RAM**, and XC8 sized that
stack using the same call graph it admits is broken. Software-stack calls are
also slower, and this firmware has hard SIO timing obligations to the Z80.

Recommendation: **not now.** Changing the memory model of a working real-time
system in the middle of a USB fault couples two large risks. Take the point fix,
get enumeration finished, then evaluate `-mstack=software` deliberately with a
regression pass over the SIO link and the SD path. The `(1393)` warning stays
open either way — it concerns the hardware return-address stack, which no
`-mstack` setting changes.

### Level 42 result: it is a stall, not a loop. Two hypotheses dead.

```text
                run 1     run 2
attach events   29        29
HXFRDN seen     28        28
xfer_done runs  28        28
last enum state 13        13
mounted addrs   04        04
int dispatches  D256      DFC8
```

Page 4 at the same time:

```text
enumerating    : FF     idle
defer count    : 00
enum completes : 01
attach hub addr: 00     ROOT port, not a hub port
branch entries : 00
```

**Both loop hypotheses are wrong.** Nothing is climbing except `int dispatches`,
which is only FRAMEIRQ ticking every millisecond because SOF is running. The
defer path was never taken and the gate is idle, so the re-queue theory is dead;
and nothing is repeating, so the root-port re-attach theory is dead too. The 41
attaches happened once during start-up and stopped.

`branch entries : 00` was also not a finding — `attach hub addr : 00` says those
attaches were **root-port** events, so they used the root branch. The behind-hub
branch was instrumented on an assumption about which path the traffic took, and
the assumption was wrong.

The real state is: **the hub is mounted and the bus is silent.** `HXFRDN` frozen
at 40 means no USB transaction of any kind has occurred since enumeration
finished. The hub's status endpoint was armed as `81h` (level 40 showed
`submit endpoint : 81`) and has never run, so downstream port changes are never
observed and no keyboard can ever be seen.

### Mechanism candidate: a transfer stranded at ATTEMPT_1

`hcd_edpt_xfer()` arms an endpoint and then only starts it if the controller is
free:

```c
ep->state = EP_STATE_ATTEMPT_1;
usbh_spin_lock(false);
if (!_hcd_data.busy_lock) { _hcd_data.busy_lock = true; has_xfer = true; }
usbh_spin_unlock(false);
if (has_xfer) { xact_generic(rhport, ep, true, false); }
return true;                    // returns success either way
```

If `busy_lock` was held, the transfer is left pending and the caller is told it
succeeded. The only thing that would later start it is the FRAME handler, which
selects:

```c
if (ep->packet_size && ep->state > EP_STATE_ATTEMPT_1)
```

**strictly greater** than `ATTEMPT_1`. An endpoint sitting at exactly
`ATTEMPT_1` is never picked up. So a transfer armed while the controller was
busy has no owner and never runs — which is exactly a frozen HXFRDN with a
mounted hub.

Whether that is what happened here depends on `busy_lock` having been set at the
moment `hub_edpt_status_xfer()` armed the endpoint, which has not been measured.

### Level 43

Page 4 gains three live reads through accessors in the MAX3421E driver:

```text
busy_lock        _hcd_data.busy_lock
hub ep state     state of (addr 3, ep 1, IN); 03h = ATTEMPT_1
hub ep pktsize   its packet size; FFh = no such endpoint
```

Interpretation:

| busy_lock | ep state | meaning |
|---|---|---|
| `01` | `03` | stranded exactly as described — armed while busy, no owner |
| `00` | `03` | armed, controller free, and still nobody started it |
| any | `FF` | the endpoint was never opened; the fault is earlier, in `tuh_edpt_open()` |
| any | `00`/`01` | idle or complete — the poll is not being re-armed at all |

Note the last row is a different bug from the first: re-arming is the caller's
job after each completion, the same contract `tuh_hid_receive_report()` has.

### Level 44 result: the hub's interrupt endpoint is not in the driver's table

```text
  hub_xfer_cb    : 00     never dispatched
  status arms    : 01     hub_edpt_status_xfer() called exactly once
  status change  : FF     never read
  busy_lock      : 00
  hub ep state   : FF     NO SUCH EP
  hub ep pktsize : FF
```

`hub ep state` read `00` with `pktsize 01` at level 43 and reads `FF` here.
Those were different boots, so **the outcome varies boot to boot** — which is a
result in itself, and one that rules out any purely deterministic explanation.

The `submit endpoint : 81` evidence from level 40 was weaker than it looked: the
tap sits at the *top* of `hcd_edpt_xfer()`, before

```c
max3421_ep_t* ep = find_opened_ep(daddr, ep_num, ep_dir);
TU_VERIFY(ep);
```

so it proved the call was made, not that the endpoint existed. With the endpoint
absent, that `TU_VERIFY` returns false silently, nothing is submitted to
hardware, nothing completes, nothing dispatches, and the hub is deaf. Frozen
HXFRDN follows directly.

### Cause: the endpoint table was configured at less than half TinyUSB's default

`hcd_edpt_open()` allocates from a fixed table and fails when it is full:

```c
ep = allocate_ep();
TU_ASSERT(ep);        // returns false; no error surfaces to the caller
```

TinyUSB's own default sizing is

```c
#define CFG_TUH_MAX3421_ENDPOINT_TOTAL (8 + 4 * (CFG_TUH_DEVICE_MAX - 1))
```

which is **12** for `CFG_TUH_DEVICE_MAX = 2`. This port's `tusb_config.h` set it
to **5**, and slot `[0]` is reserved for address 0 — leaving four usable slots
for a hub (control + interrupt-IN) and everything downstream of it. Combined
with 41 attach cycles churning through enumeration, running out is entirely
plausible, and a table that is sometimes full and sometimes not is exactly the
boot-to-boot nondeterminism observed.

### Level 45

- `CFG_TUH_MAX3421_ENDPOINT_TOTAL` raised **5 -> 12**, TinyUSB's own default.
- Page 4 reports `ep alloc fails`, `ep slots used` and `ep slots total`, so the
  hypothesis is confirmed or refuted rather than assumed.

If `ep alloc fails` is non-zero on the next run, the sizing was the fault. If it
is zero and the endpoint is still missing, `tuh_edpt_open()` is failing for a
different reason and the next look is there.

Cost: data 55.0% -> 55.8%.

### Level 45 result: table sizing refuted; the transfer completes and is not dispatched

```text
  ep alloc fails : 00      ep slots used : 02 of 0C
  submit address : 03      submit endpoint : 81
  HXFR reg       : 41
  ep_dir / ep_num: 01 / 01     PERADDR : 03
  packet_size    : 01
  total_len      : 0001    xferred_len : 0001
  ep state       : 01      EP_STATE_COMPLETE
  branch taken   : 04      completed (IN) -> xfer_complete_isr() ran
  hub_xfer_cb    : 00
```

**The endpoint-table hypothesis is refuted**: no allocation failures, and only
the two slots the hub legitimately needs are in use. Raising 5 -> 12 was still
correct — it was misconfigured against upstream's own default — but it was not
this fault. Recorded as a wrong guess, not quietly dropped.

What the page does establish is much better: the status transfer **completed
successfully**. One byte was received, the endpoint reached
`EP_STATE_COMPLETE`, and branch 4 means `xfer_complete_isr()` ran and queued the
event. `hub_xfer_cb` is still zero. So this is a **dispatch** failure inside
usbh, not a transfer failure — the completion happens and nobody is told.

#### A flaw in the level-43 instrument

`hub ep state : 00` was reported as "IDLE, i.e. completed". That reading was not
safe: `EP_STATE_IDLE` is 0 and `_hcd_data` is `tu_memclr`'d at init, so `00`
equally means "opened but never armed". The two are opposite conclusions. The
level-45 page-2 data resolves it properly, but the earlier inference was built
on an ambiguous byte.

#### Second defect visible: the endpoint is registered as isochronous

`HXFR reg : 41` decodes against the driver's own layout as ep_num 1 **plus
`HXFR_ISO` (0x40)**. The hub's status endpoint is an interrupt endpoint —
`hub_open()` asserts `TUSB_XFER_INTERRUPT == desc_ep->bmAttributes.xfer` and
that assert passed. But `hcd_edpt_open()` re-reads the same descriptor:

```c
ep->hxfr_bm.is_iso = (TUSB_XFER_ISOCHRONOUS == ep_desc->bmAttributes.xfer) ? 1 : 0;
```

and reached the opposite answer, from the very `ep_desc` pointer that level 36
showed XC8 clobbers across `tuh_edpt_open()`. The descriptor is being misread
inside the open path.

### Hypothesis: ep2drv was never bound

usbh dispatches a completion by

```c
uint8_t drv_id = dev->ep2drv[epnum][ep_dir];
usbh_class_driver_t const* driver = get_driver(drv_id);
```

and that map is filled by

```c
if (driver && driver->open(rhport, dev_addr, desc_itf, drv_len)) {
  ...
  tu_edpt_bind_driver(dev->ep2drv, desc_itf, drv_len, drv_id);
}
```

`driver->open()` — that is `hub_open()` — runs **before** the bind, and
`hub_open()` is the function already proven to clobber caller-visible state
across its nested `tuh_edpt_open()` call. If `desc_itf` or `drv_len` are damaged
the same way, the bind walks the wrong memory, `ep2drv[1][IN]` stays `0xFF`,
`get_driver(0xFF)` returns NULL and the completion is discarded silently. Same
defect class as levels 35, 36 and 40, one level further up the stack.

### Level 46

Page 4 gains a live read of `dev(3)->ep2drv[1][IN]` plus the `drv_id` and
`drv_len` the bind actually ran with:

| ep2drv | meaning |
|---|---|
| `FF` | never bound; every completion for this endpoint is discarded |
| `FE` | no device at address 3 |
| other | bound; the fault is inside dispatch or the driver itself |

`bind drv_len` also shows whether the length handed to the bind was sane — a
zero or absurd value there points straight back at the same overlay defect.

### Level 46 result: CONFIRMED — the hub's endpoint was never bound to a driver

```text
  ep2drv[1][IN]  : FF      NEVER BOUND
  bind calls     : 01
  bind drv_id    : 01
  bind drv_len   : 0010
```

`tu_edpt_bind_driver()` ran exactly once, with **correct** arguments:
`drv_len = 16` is precisely `sizeof(tusb_desc_interface_t)` (9) +
`sizeof(tusb_desc_endpoint_t)` (7) for a hub interface, and `drv_id = 1` is
valid. And `ep2drv[1][IN]` is still `0xFF`.

Its implementation is a plain walk:

```c
uint8_t const* p_desc = (uint8_t const*) desc_itf;
uint8_t const* desc_end = p_desc + desc_len;
while (p_desc < desc_end) {
  if (TUSB_DESC_ENDPOINT == tu_desc_type(p_desc)) {
    ep2drv[tu_edpt_number(ep_addr)][tu_edpt_dir(ep_addr)] = driver_id;
  }
  p_desc = tu_desc_next(p_desc);
}
```

With a correct length and nothing written, **`desc_itf` must point at memory
containing no endpoint descriptor.**

That closes the chain: `ep2drv[1][IN] = 0xFF` -> `get_driver(0xFF)` returns
NULL -> the completion is discarded with no error -> `hub_xfer_cb` never runs
-> the status poll is never re-armed -> the hub is deaf to every downstream
port change. All from one silently-dropped pointer.

### Level 47 fix

In `enum_parse_configuration_desc()`:

```c
if (driver && driver->open(rhport, dev_addr, desc_itf, drv_len)) {
  ...
  tu_edpt_bind_driver(dev->ep2drv, desc_itf, drv_len, drv_id);
}
```

`driver->open()` here **is** `hub_open()` — the function already proven at level
40 to have its caller-visible state overlaid by XC8 across a nested call. The
same defect one frame up: `desc_itf` does not survive the call, and the bind
immediately afterwards walks the wrong memory.

The port now saves `desc_itf` before the driver loop and restores it after
*every* `driver->open()` — not only the successful one, since a driver that
declines can damage it just as easily. The damaged state is recorded in
`desc_itf clobb` **before** the repair, so the line stays a measurement of what
XC8 does rather than a value the fix manufactures. This is the fourth instance
of one defect; see the cleanup and toolchain sections below.

Implementation note: the first attempt saved the pointer through
`(uint16_t)(uintptr_t)` and XC8 answered with
`(712) can't generate code for this expression` — the same limitation that
blocks `-mstack=software`. It is saved as a pointer-typed file-static instead.
A local would have been no good regardless: a local lives in exactly the storage
this defect overwrites.

Expected next capture: `desc_itf clobb : 01` (the corruption is real and being
repaired), `ep2drv[1][IN]` becomes a valid driver id, `hub_xfer_cb` starts
counting, `status arms` climbs past 1, and the hub begins reporting downstream
port changes.

### Level 47 result: desc_itf is NOT the problem

```text
  desc_itf clobb : 00      survived driver->open()
  ep2drv[1][IN]  : FF      still never bound
  bind calls     : 01      bind drv_id : 01     bind drv_len : 0010
```

The hypothesis was wrong. `desc_itf` survives the nested `driver->open()`
intact, so `tu_edpt_bind_driver()` runs with a good pointer, a correct length
and a valid driver id — and still writes nothing.

The guard added at level 47 is kept anyway. It costs one comparison, it is a
standing measurement of a defect that has appeared four times elsewhere in this
file, and `desc_itf clobb` reading `00` is now evidence rather than an
assumption.

### What that leaves

The descriptor content is known good: `hub_open()` walks the **same**
`desc_itf` with `tu_desc_next()` and correctly extracts endpoint `81h`
(`hub open ep : 81`). So the bytes the bind walks do contain the endpoint
descriptor it is looking for.

So the fault is in the **write target**, not the source:

```c
ep2drv[tu_edpt_number(ep_addr)][tu_edpt_dir(ep_addr)] = driver_id;
```

`tu_edpt_dir()` is a `TU_ATTR_ALWAYS_INLINE static inline` — the construct XC8
emits out of line and has mishandled repeatedly in this port. If it returns `0`
rather than `1`, the bind writes `ep2drv[1][OUT]` while both the reader and the
dispatcher look at `ep2drv[1][IN]`, which then reads `FF` forever.

Note a consistent error would be harmless: usbh's dispatch computes `ep_dir`
with the same helper, so both sides would agree. Only an *inconsistent* result
between the two call sites breaks it — which is exactly what an out-of-line
"always inline" helper with overlaid argument storage can produce.

### Level 48

Page 4 reports `ep2drv[1][OUT]` alongside `[IN]`, using the last byte the
transport allows:

| `[1][OUT]` | meaning |
|---|---|
| `01` | the bind wrote the wrong direction slot; `tu_edpt_dir()` is the fault |
| `FF` | the bind wrote nowhere at all; the write target itself (`dev->ep2drv`) is wrong |

### Level 48 result: the bind wrote nowhere

```text
  ep2drv[1][IN]  : FF
  ep2drv[1][OUT] : FF      empty too
  desc_itf clobb : 00      pointer was fine
  bind calls: 01   drv_id: 01   drv_len: 0010
```

Not a wrong slot — **no write happened at all**. The direction-index hypothesis
is refuted alongside the `desc_itf` one.

So `tu_edpt_bind_driver()` is entered with a verified-good pointer, a correct
length and a valid driver id, and writes neither slot. The most likely remaining
cause is `desc_len` arriving as `0` inside the callee, which makes
`desc_end == p_desc` and the loop body never execute — the same argument
corruption confirmed four times already, this time in a parameter rather than a
caller local.

### Level 49: stop bisecting, remove the hazard

Three rounds have now gone on identifying *which* value a nested call loses.
The pattern is established beyond reasonable doubt, so the bind is open-coded in
`enum_parse_configuration_desc()` instead:

```c
uint8_t const* bp = (uint8_t const*) desc_itf;
uint8_t const* bend = bp + drv_len;
while (bp < bend) {
  if (TUSB_DESC_ENDPOINT == bp[1]) {
    uint8_t const ea = bp[2];
    dev->ep2drv[ea & 0x0fu][(ea & 0x80u) ? 1u : 0u] = drv_id;
  }
  if (bp[0] == 0u) { break; }   // malformed: never spin
  bp += bp[0];
}
```

This removes the nested call entirely, so there is no argument area to overlay.
The descriptor helpers are open-coded for the same reason: `tu_desc_type()`,
`tu_desc_next()`, `tu_edpt_number()` and `tu_edpt_dir()` are all
`TU_ATTR_ALWAYS_INLINE static inline`, which this toolchain emits out of line —
each one another instance of the same hazard. Offsets are from
`tusb_desc_endpoint_t`: `bLength` 0, `bDescriptorType` 1, `bEndpointAddress` 2.

The zero-length guard is deliberate: a malformed descriptor would otherwise spin
forever, and this loop no longer has the library's own bounds checking.

No new instrumentation — `ep2drv[1][IN]` becoming `01` is the test.

**This strengthens the case for `-mstack=software` considerably.** Four confirmed
corruptions and a fifth strongly implied, all from the same allocator, and the
workaround has escalated from "save a variable" to "do not call the library
function". That is not a sustainable position for the rest of the USB stack.

### Level 49 result: the bind works, and a HID device appears behind the hub

```text
  ep2drv[1][IN]  : 01      bound (drv_id 1 = HUB)
  hub_xfer_cb    : 01      dispatched - the hub driver ran
  status change  : 04      hub reports a change on PORT 2
  attach hub addr: 03      attach from the HUB, not the root port
  attach hub port: 02
  ep slots used  : 04      was 02
  bind calls     : 02      drv_id 00, drv_len 0019
```

Open-coding the bind fixed it, and the whole chain came alive at once:
endpoint bound -> completion dispatched -> `hub_xfer_cb()` ran -> the hub
reported a downstream port change -> an attach event arrived from **hub address
3, port 2**, which is a real device behind the hub rather than another root-port
event.

The second bind identifies it. With this configuration the built-in driver
table resolves to `drv_id 0 = HID`, `drv_id 1 = HUB`, so:

- bind 1: `drv_id 1`, `drv_len 16` — the hub (9 interface + 7 endpoint)
- bind 2: `drv_id 0`, `drv_len 25` — **HID** (9 interface + 9 HID + 7 endpoint)

25 bytes with a HID descriptor in the middle is the exact shape of a boot
keyboard interface. `ep slots used` rising 2 -> 4 is that device's control and
interrupt endpoints.

`ep2drv[1][OUT]` remaining `FF` is correct, not a residual fault: a boot
keyboard has an interrupt-IN endpoint and no OUT.

### Root cause summary for this phase

The hub mounted but was deaf because `tu_edpt_bind_driver()` never wrote
`ep2drv`. Every argument it received was verified correct — pointer, length,
driver id — so the loss was inside the call itself, the fifth instance of XC8's
overlay defect. `ep2drv[1][IN]` stayed `0xFF`, `get_driver(0xFF)` returned NULL,
and each completion was discarded with no error anywhere, so the status poll was
never re-armed and no downstream port change could ever be seen.

Three hypotheses were tested and refuted along the way, each cheaply and each
recorded rather than dropped: endpoint-table exhaustion (no allocation failures,
2 of 12 slots used), `desc_itf` corruption (`desc_itf clobb : 00`), and a wrong
direction index (`ep2drv[1][OUT]` equally empty).

### Level 49 hardware: the keyboard enumerates and powers up

**The keyboard's lock LEDs came on.** That only happens after
`SET_CONFIGURATION`; the backlight alone is just VBUS. Physical confirmation
that a device behind the hub is configured and operating.

```text
  mounted addrs  : 05      bit 0 (address 1) + bit 2 (hub at address 3)
  device descr   : 02      config descr : 02
  HXFRDN seen    : 63      was frozen at 28
  HRSL at done   : 85      JSTATUS set, result nibble 5 = STALL
  USB devices    : 0
  keyboard addr  : 00      none mounted
  boot reports   : 0000
```

So two devices are fully enumerated and `tuh_mounted(1)` is true, but neither
`tuh_mount_cb()` nor `tuh_hid_mount_cb()` has fired and no reports flow. The
remaining gap is the **HID class driver's set-config chain**, which runs after
the interface is bound and ends by calling `tuh_hid_mount_cb()`.

### Where the STALL probably comes from

`process_set_config()` already tolerates a STALL on SET_IDLE and SET_PROTOCOL,
so a stall there is not fatal by itself. But note how the chain is started:

```c
bool hidh_set_config(uint8_t daddr, uint8_t itf_num) {
  tusb_control_request_t request;      // local
  request.wIndex = tu_htole16((uint16_t) itf_num);
  tuh_xfer_t xfer;                     // local
  xfer.setup = &request;               // pointer to a local...
  xfer.user_data = CONFG_SET_IDLE;
  process_set_config(&xfer);           // ...passed by pointer into a nested call
}
```

and `process_set_config()` immediately dereferences `xfer->setup->bRequest` and
derives `itf_num` from `xfer->setup->wIndex`. **Two levels of pointer-to-local
through a nested call** is the shape this toolchain has corrupted five times in
this port. A garbage `itf_num` addresses an interface that does not exist, and a
device answers that with STALL — which is what `HRSL at done : 85` shows.

### Level 50: page 5

Traces the chain rather than assuming which link breaks:

```text
hidh_open        driver open() entries
hidh_set_config  chain kick-offs
process_setcfg   process_set_config() entries
last state       0 SET_IDLE, 1 SET_PROTOCOL, 2 GET_REPORT_DESC,
                 3 COMPLETE, FFh never entered
itf_num          as read through xfer->setup->wIndex
bRequest         as read through xfer->setup->bRequest
xfer result      last result seen
mount complete   config_driver_mount_complete() entries
tuh_mount_cb     invocations from usbh
```

`itf_num` and `bRequest` are the ones to read first: if either is implausible,
the pointer-to-local hypothesis is confirmed and the fix is the same as level 49
— stop passing state through the nested call. `tuh_mount_cb` reading zero while
`mounted addrs` shows the device confirms the callback is not being reached at
all, which is a separate question from the HID chain.

`HIDSTAT 5` prints it.

### Level 50 result: the HID chain is correct — and the failure is intermittent

```text
  hidh_open       : 04     hidh_set_config : 01
  process_setcfg  : 03     last state      : 03   CONFIG_COMPLETE
  itf_num         : 00     bRequest        : 06   GET_DESCRIPTOR
  xfer result     : 00     SUCCESS
  mount complete  : 01     tuh_mount_cb    : 01
```

**HID mount completed.** The pointer-to-local hypothesis is refuted: `itf_num`
is `00` and `bRequest` is `06`, both exactly right, so `xfer->setup` was intact
after all. The whole chain — open, set-config, SET_IDLE, SET_PROTOCOL,
GET_REPORT_DESCRIPTOR, mount — runs correctly.

But the keyboard **does not mount on every restart**. That is now the entire
remaining problem, and it changes what is worth doing.

An intermittent failure on a code path that is otherwise proven correct is
exactly what a memory-overlay defect looks like when the call sequence varies
between boots. Five instances are confirmed in this port; a sixth that only
manifests on some paths fits the evidence.

### `-mstack=software` re-measured at level 50

| | hybrid | software |
|---|---|---|
| Program | 45.8% (59,971) | 56.9% (74,563) |
| Data | 55.9% (7,155) | 53.2% (6,807) |
| Software stack | 512 | 5,886 |
| **Total RAM** | — | **12,693 of 12,800 (99.2%)** |

It still builds. Data space falls, because overlaid statics become stack — but
the combined figure is 99.2% of RAM, roughly 100 bytes spare, and XC8 sized that
stack using the same call graph it reports as unbounded. Software-stack calls
are also slower, against a firmware with hard SIO timing obligations.

### Next step: capture a FAILING boot

Diagnose the failure, not the success. Restart until the keyboard does not
mount, then capture pages 1, 4 and 5 from that boot. The specific questions:

- page 1 `mounted addrs` — does the hub still come up (bit 2) with no device
  (bit 0/1 clear), or does neither appear?
- page 1 `enum failures`, `HRSL at done`, `attach events`
- page 4 `ep alloc fails`, `ep slots used`, `ep2drv[1][IN]`
- page 5 `last state` — how far the HID chain reached before stopping

Switching memory model on a hunch would repeat the endpoint-table mistake: a
plausible fix applied before the failure was characterised. One failing capture
first.

### Failing-boot capture: the endpoint is opened under an unmatchable key

A boot where the keyboard did not mount:

```text
page 1   mounted addrs  : 04     hub only, no device
         device/config descr : 01 / 01     the hub's own
         enum failures  : 00     HRSL at done : 80 (success)
page 4   ep2drv[1][IN]  : 01     BOUND -- the level 49 fix held
         hub ep state   : FF     NO SUCH EP
         hub ep pktsize : FF
         ep slots used  : 02     ...yet two endpoints are allocated
         hub_xfer_cb    : 00     attach hub addr : 00 (root port)
page 5   hidh_open      : 01     hidh_set_config : 00
         last state     : FF     HID mount never started
```

The contradiction is the finding: `find_opened_ep(3, 1, IN)` returns NULL
**while two endpoint slots are in use**. The hub's interrupt endpoint was
opened — it is simply registered under a `daddr`/`ep_num`/`dir` key that the
lookup cannot match. `hcd_edpt_xfer()` then fails its `TU_VERIFY(ep)` silently,
the status poll never runs, no downstream attach is ever reported, and no
keyboard can appear.

Everything above the driver is fine on this boot: the binding is correct, the
hub is enumerated, no enumeration failed, the last transfer succeeded.

### This was already visible once

`HXFR reg : 41` on the *working* boot had `HXFR_ISO` set on an interrupt
endpoint. That is `hcd_edpt_open()` misreading `bmAttributes` from the same
descriptor — recorded at the time as a second defect and not pursued, because
the ISO bit alone did not stop the transfer. It was the same fault with a
survivable outcome.

`hcd_edpt_open()` derives everything through `tu_edpt_number()`,
`tu_edpt_dir()`, `tu_edpt_packet_size()` and the `bmAttributes` bitfield — all
`TU_ATTR_ALWAYS_INLINE static inline`, all emitted out of line by this
toolchain. When it misreads the transfer type the result is a wrong ISO bit;
when it misreads the address the endpoint becomes unfindable. Which one happens
depends on the call path, which is why the failure is intermittent.

### Level 51

`hcd_edpt_open()` now reads the descriptor by offset — `bEndpointAddress` at 2,
`bmAttributes` at 3, `wMaxPacketSize` at 4..5 — and `hcd_edpt_xfer()` derives
`ep_num`/`ep_dir` the same open-coded way, so **the key an endpoint is stored
under cannot disagree with the key used to find it**. Same remedy as level 49,
applied one layer down.

This is the sixth instance of the same compiler defect.

### Level 51 hardware: 10 restarts, 10 mounts

The keyboard mounted on every one of ten consecutive restarts. The
intermittency is gone, and that result is what confirms the diagnosis: a
path-dependent compiler fault cannot be proven fixed by a single success, only
by repetition.

Six instances of XC8's overlay defect are now fixed in this port:

| # | Site | Symptom |
|---|---|---|
| 1 | `queue_event()` (level 35) | completion events corrupted in transit |
| 2 | `hub_open()` `desc_ep` (level 36) | endpoint address read back as 0 |
| 3 | `hub_open()` `dev_addr` (level 40) | hub object written 24 bytes out of bounds |
| 4 | `tusb_time_delay_ms_api()` (level 35) | enumeration delays completing early |
| 5 | `tu_edpt_bind_driver()` (level 49) | endpoint never bound to a class driver |
| 6 | `hcd_edpt_open()` / `hcd_edpt_xfer()` (level 51) | endpoint stored under an unmatchable key |

The remedy escalated across those: save a variable, then restore a parameter,
then stop calling the library function, then stop using the library's inline
accessors. That trajectory is the argument for the toolchain change below —
each fix was correct, and none of them generalises to the code paths not yet
exercised.

### Level 51 hardware: mounts reliably, but no reports

```text
  USB devices    : 1       tuh_mount_cb fired
  keyboard addr  : 00      none mounted
  boot reports   : 0000
```

Ten restarts, ten mounts — and still no reports. `USB devices : 1` proves
`tuh_mount_cb()` ran, and page 5's `mount complete : 01` proves
`tuh_hid_mount_cb()` ran too. So this one is **in the port's own code**, not in
TinyUSB or the hardware:

```c
if (tuh_hid_interface_protocol(dev_addr, instance) != HID_ITF_PROTOCOL_KEYBOARD)
    return;      // bails before arming the report pipeline
```

`bInterfaceProtocol` is only meaningful when the interface declares the HID boot
subclass. Plenty of keyboards report `0` there and are still perfectly good
boot-protocol keyboards, so filtering on it silently discards working hardware —
which is what happened. The check was written when the plan was "boot keyboards
only" and it was never questioned afterwards.

### Level 52

The filter now rejects only `HID_ITF_PROTOCOL_MOUSE`, whose 8 bytes genuinely
are not a keyboard report, and accepts everything else. TinyUSB has already put
the interface into boot protocol during set_config, so the reports are the fixed
8-byte layout regardless of what the interface claims.

The protocol byte is recorded rather than assumed, along with the `dev_addr` and
`instance` the callback was handed and whether the first
`tuh_hid_receive_report()` was accepted:

```text
hid_mount_cb     tuh_hid_mount_cb() entries
mount daddr      device address it was handed
mount instance   HID instance index
itf protocol     0 none, 1 keyboard, 2 mouse, FFh never called
first arm        1 accepted, 0 refused -- a refusal means no report ever arrives
```

`first arm` matters as much as the protocol: arming is a contract this port has
to honour on mount **and** on every delivery, and missing either half yields
exactly one report, or none.

### Level 52/53 results: mounted, armed, and still no reports

```text
  keyboard addr  : 01  MOUNTED     itf protocol : 00  none declared
  first arm      : 01  accepted    boot reports : 0000  (key held down)
  kbd ep state   : 00  EP_STATE_IDLE
  kbd ep pktsize : 08              kbd ep2drv   : 00  bound to the HID driver
  busy_lock      : 00
```

`itf protocol : 00` confirmed the level 52 diagnosis — the keyboard declares no
protocol and the old filter was discarding it. With the filter relaxed it
mounts, and the first `tuh_hid_receive_report()` was accepted.

But **`kbd ep state : 00`** is `EP_STATE_IDLE`, and `is_ep_pending()` requires
`state >= EP_STATE_ATTEMPT_1`. The keyboard's interrupt endpoint is not queued
at all. Its `ep2drv` is `00` (bound to the HID driver) and `packet_size` is `08`,
so the endpoint is opened correctly; it is simply never polled.

An accepted arm and an idle endpoint can only both be true if **the arm went to
a different endpoint**.

### Root cause: p_hid->ep_in is zero

`tuh_hid_receive_report()` arms `p_hid->ep_in`, which `hidh_open()` sets so:

```c
TU_ASSERT(tuh_edpt_open(daddr, desc_ep));                  // nested call
if (tu_edpt_dir(desc_ep->bEndpointAddress) == TUSB_DIR_IN) {
  p_hid->ep_in = desc_ep->bEndpointAddress;                // read AFTER it
  p_hid->epin_size = tu_edpt_packet_size(desc_ep);
}
```

Character for character the `hub_open()` bug fixed at levels 36 and 40. With
`ep_in == 0`, `usbh_edpt_xfer(daddr, 0, ...)` addresses the **control**
endpoint: it succeeds, so `first arm` reads `01`, while the interrupt endpoint
is never touched and stays `IDLE`. Every observation follows from that one zero.

### Level 54

`hidh_open()` now reads `bEndpointAddress` and `wMaxPacketSize` **by offset,
before** the nested `tuh_edpt_open()`, into dedicated file-static storage — not
locals, which live in exactly the memory this defect overwrites. The direction
test uses the captured byte rather than `tu_edpt_dir()`.

Page 5 reports `hid ep_in` so the value is visible rather than assumed: `81` is
the interrupt endpoint, `00` means arming would target control.

That is **seven** sites now:

| # | Site | Symptom |
|---|---|---|
| 1 | `queue_event()` | completion events corrupted in transit |
| 2 | `hub_open()` `desc_ep` | endpoint address read back as 0 |
| 3 | `hub_open()` `dev_addr` | hub object written out of bounds |
| 4 | `tusb_time_delay_ms_api()` | enumeration delays completing early |
| 5 | `tu_edpt_bind_driver()` | endpoint never bound to a class driver |
| 6 | `hcd_edpt_open()` / `_xfer()` | endpoint stored under an unmatchable key |
| 7 | `hidh_open()` `desc_ep` | HID endpoint address read back as 0 |

Sites 2 and 7 are **the same code shape in two different files**. Fixing one and
not looking for the other cost this round outright. That is the strongest
argument yet for `-mstack=software` over continued site-by-site patching: the
defect is systematic, and locating each instance costs a hardware capture and a
hypothesis.

### Level 54 result: endpoint fixed, and the readout itself was lying

```text
  hid ep_in      : 81      interrupt endpoint captured -- level 54 worked
  kbd ep state   : 00      kbd ep2drv : 00    kbd ep pktsize : 08
  boot reports   : 0000
  last report    : 00 00 81 00 00 00 00 00     was all zeros before
  keyboard speed : 02      impossible: HIGH on a full-speed-only controller
```

`last report` is no longer zeros while `boot reports` is still `0000` — and
those two cannot disagree. The only writer of `keyboard_last[]` is
`tuh_hid_report_received_cb()`, which fills the buffer and increments the
counter **in the same guarded block**. A written buffer with a zero count is
impossible from the callback's side.

So the corruption is on the **read** side, in this port's own code:

```c
void handler_hid_status(const IocFrame *request, IocFrame *reply) {
  HidHostProbe    probe;          // locals...
  HidHostUsbState usb;
  hid_host_probe(&probe);         // ...passed by pointer into nested calls
  hid_host_usb_state(&usb);
```

The same defect as the seven inside TinyUSB, in `handlers.c`. And it predicts
precisely the observed pattern: `report_count` and `speed` are adjacent in
`HidHostUsbState` and both read wrong, while `device_count` and `keyboard_addr`
before them and `last_report` after them survive.

**`keyboard speed : 02` was the tell and it was dismissed.** It was flagged as
"impossible, probably cosmetic, chase it later". It was not cosmetic; it was the
same corruption, visible for several rounds, in a field nobody was reading
closely. An impossible value is evidence, not noise.

### Level 55

All five reply structs in `handlers.c` — `HidHostProbe`, `HidHostUsbState`,
`HidHostXfer`, `HidHostEnum`, `HidHostCfg` — are now file-static rather than
locals. Static storage is outside the overlay, and the IOC services one command
at a time, so there is no reentrancy to guard against.

This casts doubt on **every page-level reading taken before level 55**, since
all of them travelled through a local struct passed by pointer. Values that
drove earlier conclusions were mostly corroborated by other means (register
dumps, live accessors, counters that changed in expected ways), but any
single-source reading from an earlier level should be re-taken rather than
trusted.

That is eight sites. Two of them — sites 2 and 7 — were the same code shape in
different files, and this one is the same shape again in the port's own code.

### Level 55 result: the handler-struct hypothesis was WRONG

```text
  keyboard speed : 02      UNCHANGED after the structs were made static
  hid ep_in      : 81      correct
  kbd ep state   : 00      IDLE      kbd ep2drv : 00     busy_lock : 00
  boot reports   : 0000    last report : all zeros
```

Making the five reply structs file-static changed nothing. `keyboard speed : 02`
is therefore **real, not corruption** — the previous entry's reasoning was wrong,
and the `00 00 81 00...` briefly seen in `last report` was an artefact of the
pre-fix build rather than evidence of a write.

The change is kept: passing a pointer to a local into a nested call is the
documented failure shape here and static storage costs nothing. But it explained
nothing, and claiming it did was premature. The lesson is the inverse of the
previous entry's: an impossible-looking value **can** be a real reading, and
"this resembles the defect we already know" is a hypothesis, not a diagnosis.

### Level 56: trace the report path instead of theorising

With `hid ep_in` correct, `ep2drv` bound, `busy_lock` clear and the arm
accepted, an endpoint that stays `IDLE` means either the arm never reaches the
controller, or it completes and the completion never comes back up. Three
counters separate every case:

```text
kbd submits      hcd_edpt_xfer() calls addressed to device 1
hidh_xfer_cb     entries into the HID driver's completion handler
xfer_cb ep       the endpoint it was told about
report_cb        tuh_hid_report_received_cb() entries, counted BEFORE the
                 dev_addr/instance guard
report daddr     what that callback was handed
report inst
```

| Reading | Meaning |
|---|---|
| `kbd submits : 00` | the arm never reaches the controller; fault is in `usbh_edpt_xfer`/claim |
| submits > 0, `hidh_xfer_cb : 00` | submitted, never completed into the driver — dispatch again |
| xfer_cb > 0, `report_cb : 00` | the driver ran and did not call up; `get_idx_by_epaddr()` or the `p_hid` lookup failed |
| `report_cb` > 0, `boot reports : 0000` | the callback ran and **this port's own guard rejected it** — compare `report daddr`/`inst` with `keyboard addr` |

The last row is worth pre-empting: `tuh_hid_report_received_cb()` is handed an
**instance index**, and this port stores `keyboard_instance` from the mount
callback. If those disagree the report is dropped by the port's own filter —
exactly the way `bInterfaceProtocol` dropped the whole device at level 52.

### Level 56 result: submitted, never completed — and the counter was too coarse

```text
  kbd submits    : 1A (26)     hidh_xfer_cb : 00
  xfer_cb ep     : FF          report_cb    : 00
  kbd ep state   : 00  IDLE    hid ep_in    : 81
```

26 submissions to address 1 and zero completions into the HID driver. But 26 is
not what it looks like: this port arms the report pipeline **once**, at mount,
and re-arms only from `tuh_hid_report_received_cb()` — which has run zero times.
So the counter was measuring enumeration control traffic to address 1 as well,
and could not answer the one question it was built for: *was the interrupt
endpoint ever submitted at all?*

Level 57 narrows it to `daddr == 1 && ep_addr == 0x81`.

### A likelier candidate: epin_size

`tuh_hid_receive_report()` submits with `p_hid->epin_size` as the length:

```c
if (!usbh_edpt_xfer(daddr, p_hid->ep_in, epbuf->epin, p_hid->epin_size)) {
```

`epin_size` is set in `hidh_open()` from **the same descriptor read** that
produced the zero `ep_in` fixed at level 54. `ep_in` was repaired there and
`epin_size` with it, but the value has never been observed. A zero length
submits a zero-length transfer: `usbh_edpt_xfer()` succeeds, so `first arm`
reads `01`, and no report can ever be delivered.

Note `kbd ep pktsize : 08` does **not** contradict this — that is the MAX3421E
driver's own endpoint table entry, computed independently in `hcd_edpt_open()`,
not `p_hid->epin_size`. Two different fields from the same descriptor, only one
of which was checked.

Level 57 reports `epin_size` in the last page-5 byte (reusing `report inst`,
which is meaningless while `report_cb` is zero).

### Instrumentation defect found and fixed

The `xfer_cb idx` tap added at level 56 was written into
`tuh_hid_receive_report()` rather than `hidh_xfer_cb()` — the search pattern
matched the wrong function first, and both contain the same three lines. It was
harmless because that field was not displayed, but it is a reminder that
instrumentation is code and can be as wrong as what it measures.

### Level 57 result: CONFIRMED — epin_size is zero

```text
  epin_size      : 00
  ep81 submits   : 00      NEVER SUBMITTED
  hid ep_in      : 81      correct
  kbd ep pktsize : 08      the HCD's own table entry, correct
```

`p_hid->epin_size` is zero, so `tuh_hid_receive_report()` submits a zero-length
transfer. `usbh_edpt_xfer()` reports success — which is why `first arm` has read
`01` for several levels — and endpoint `81h` is never actually submitted to the
controller. `ep81 submits : 00` confirms it now that the counter distinguishes
the interrupt endpoint from enumeration control traffic.

The interesting detail is that `ep_addr` and `wMaxPacketSize` are read from
**the same descriptor, two bytes apart, in the same statement block** — and one
came out right (`81`) while the other came out zero. Whatever the toolchain is
doing here, it is not uniform across a single structure read.

`kbd ep pktsize : 08` never contradicted this: that is the MAX3421E driver's own
table entry from `hcd_edpt_open()`, a completely separate computation.

### Level 58

Two changes:

1. `hidh_open()` validates the value. A HID interrupt endpoint cannot be
   zero-length, and a full-speed one cannot exceed 64, so an impossible read
   falls back to **8** — the boot-protocol report size this interface is put
   into during set_config regardless. Trusting a read this toolchain has already
   been caught getting wrong is not defensible when a correct value is known.
2. The raw `wMaxPacketSize` bytes are reported (`mps lo` / `mps hi`, expected
   `08 00`), so the underlying read stays visible rather than being papered
   over by the fallback.

The fallback is a workaround, not a fix, and is deliberately narrow: it triggers
only on values that cannot be valid, and it reports what it saw. If `mps lo`
reads `08` on the next capture then the read is fine and something later zeroed
the field, which is a different bug and one this page will still show.

### Level 58 result: the read is correct, the stored value is not

```text
  mps lo byte : 08     mps hi byte : 00      raw descriptor read is CORRECT
  epin_size   : 00     p_hid->epin_size at arm time
  ep81 submits: 00
```

The descriptor read is fine — `08 00` is exactly right for a boot keyboard — so
the level 58 fallback never even triggered. Yet `p_hid->epin_size` is still zero
when `tuh_hid_receive_report()` reads it.

`CFG_TUH_HID` is 1, so `find_new_itf()` and `get_hid_itf()` can only resolve to
`_hidh_itf[0]`; a wrong-slot explanation is ruled out. The write itself is not
landing, or something clears it afterwards.

### A flaw in the instrument, again

`hid ep_in : 81` was read from **the port's own static**, not from
`p_hid->ep_in`. So there has never been any evidence that the struct field was
correct either — only that the value captured before the call was. Two of the
last three rounds have been slowed by measuring a proxy instead of the thing.

### Level 59

Two changes, both narrowing rather than guessing:

1. The capture drops all 16-bit arithmetic. `usbh_xc8_hid_ep_mps` becomes a
   plain `uint8_t` assigned `epb[4]`, with no shift, no mask and no 16-bit
   static. A HID interrupt endpoint is at most 64 bytes, so the high byte cannot
   carry information — and with the raw bytes proven correct, the arithmetic
   that turned them into a 16-bit value is the remaining suspect.
2. `p_hid->epin_size` is **read straight back after the write** into
   `epin after wr`. That separates "the store never landed" from "something
   zeroed it later", which no reading so far can distinguish.

| `epin after wr` | `epin_size` | meaning |
|---|---|---|
| `08` | `08` | fixed |
| `08` | `00` | the store lands and something clears it before the arm |
| `00` | `00` | the store itself does not land — the 16-bit path was the fault |

### Level 59 result: the store lands and is cleared afterwards

```text
  epin after wr : 08     p_hid->epin_size immediately after hidh_open() writes it
  epin_size     : 00     the same field when tuh_hid_receive_report() reads it
  mps lo byte   : 08     descriptor read correct
  ep81 submits  : 00
```

Unambiguous: `hidh_open()` stores 8 and the field reads back as 8 in the same
breath, then reads 0 by the time the report is armed. The 16-bit arithmetic
suspected at level 59 was innocent — the value is correct at the point of write.

`epin_size` is assigned in exactly one place, so this is not a competing write.
Only two functions clear that memory:

```c
hidh_init()   -> tu_memclr(_hidh_itf, sizeof(_hidh_itf));
hidh_close()  -> tu_memclr(p_hid, sizeof(hidh_interface_t));   // per daddr
```

`hidh_close()` is the plausible one, and it would also explain `hidh_open : 04`:
a slot freed by a close is handed back out by `find_new_itf()` on the next open.
It calls `tuh_hid_umount_cb()` first — which this port implements — so a close
that ran without `keyboard addr` returning to 00 would mean the port's own
umount guard did not match, which is worth knowing on its own.

### Level 60

1. `hidh_init()` and `hidh_close()` entries are counted, packed into one byte
   (`itf clears`: high nibble init, low nibble close). That names the culprit
   rather than inferring it.
2. `tuh_hid_receive_report()` **refuses to submit a zero-length transfer** and
   floors `epin_size` at 8.

The floor is a floor, not a fix, and is stated as such in the code. A
zero-length interrupt IN transfer is never valid, it reports success so nothing
downstream can notice, and the boot-protocol report is 8 bytes — so refusing
zero costs nothing and restores the report path while the cause is still being
tracked. `itf clears` remains visible either way, so the underlying bug cannot
hide behind the workaround.

Expected: `boot reports` finally climbs with a key held, and `itf clears` names
whichever of the two functions is wiping the interface.

### Level 60 hardware result: neither clear ran; the floor still never submitted

```text
  itf clears     : 10     hidh_init once, hidh_close zero times
  epin_size      : 00
  first arm      : 01     accepted
  ep81 submits   : 00     never reached the controller
  kbd ep state   : 00     idle
```

This refutes the level-59 hypothesis.  No intended operation clears the HID
interface between `hidh_open()` and the first receive arm.  More importantly,
flooring `epin_size` to 8 inside `tuh_hid_receive_report()` still did not cause
an EP81 submission.  The accepted return was therefore another false-positive
boundary: the receive arm was operating on state other than the real retained
interrupt endpoint.

Generated assembly identifies the exact corruption one call earlier:

```text
  hidh_open@desc_hid    COMRAM 23h..24h
  hcd_edpt_open@ep_mps  COMRAM 23h..24h
  hidh_open@desc_ep     COMRAM 25h..26h
  hcd_edpt_open state   COMRAM 25h..29h
  hidh_open@p_desc      COMRAM 29h..2Ah
  hidh_open@p_hid       COMRAM 2Bh..2Ch
  hcd_edpt_open@ep      COMRAM 2Ah..2Bh
```

`hidh_open()` obtains `p_hid`, then keeps it live across `tuh_edpt_open()`.
The nested MAX3421E endpoint-open path writes its two-byte `ep` pointer through
`2Ah..2Bh`, overwriting the low byte of the caller's still-live `p_hid` at
`2Bh`.  The subsequent endpoint and packet-size stores therefore target a
wrong object.  Level 59's immediate `08` readback did not prove the real
`_hidh_itf[0]` was written: both its write and read used that same damaged
pointer.  This explains every level-60 value without any hidden clear.

The post-fix generated-code audit showed that this is one contiguous overlay,
not an isolated byte: the nested call spans every `hidh_open()` descriptor
local from `desc_hid` through `p_hid`.  The endpoint address and packet size
were already captured before the call, which is why enumeration got this far,
but the report-descriptor fields and next-descriptor pointer were still live
afterward.  Level 61 therefore preserves those values at the same boundary too;
leaving adjacent known-corrupted state in place would only defer the failure.

### Level 61 targeted fix

For XC8 only, `hidh_open()` now saves the selected HID-object pointer, the
report-descriptor type/length and the next descriptor pointer in initialized
file-static storage before the nested endpoint-open call.  It restores the
object pointer immediately afterward, before the first dereference, and no
longer reads any of the known-overlapped descriptor locals after that call.
USB host service is foreground-only on this port, so this storage is not
concurrently used.  Other compilers retain the upstream path.

`hid ep_in` now reads the actual retained `hidh_interface_t.ep_in` immediately
after the repaired store rather than the descriptor-side capture.  Expected
level-61 result:

```text
  hid ep_in      : 81
  epin after wr  : 08
  epin_size      : 08
  ep81 submits   : non-zero
  boot reports   : climbs when keys are pressed
```

Level 61 builds successfully.  The saved object and next-descriptor pointers
are at `06ABh` and `06A9h`, and the three saved report-descriptor bytes are at
`06BCh..06BEh`, all in dedicated BANK6 storage outside the overlapping COMRAM
call frames.  Generated assembly reloads `p_hid` from `06ABh` immediately after
`tuh_edpt_open()` returns, then stores and directly reads back offsets 2 and 10
of that restored object.  It advances from the saved next-descriptor pointer
and reloads the HID object again before storing the report-descriptor fields;
there are no post-call reads through `desc_hid` or the damaged descriptor
pointers.  Program use is 61,002 of 131,072 bytes and data use is 7,280 of
12,800 bytes.  The pre-existing unbounded hardware-stack warning and ordinary
TinyUSB/XC8 warnings are unchanged.

If EP81 submits rise but reports do not, the fault has moved downstream into
MAX3421E polling/completion.  If EP81 remains zero, the next boundary is the
actual endpoint/length arguments at `usbh_edpt_xfer_with_callback()` entry;
the enumeration and mount path should not be reopened.

### Level 61 hardware result: HID REPORTS WORK

The default page was sampled twice while typing:

```text
  keyboard addr  : 01     MOUNTED
  boot reports   : 0005   last report: 00 00 04 00 00 00 00 00
  boot reports   : 0007   last report: 00 00 09 00 00 00 00 00
```

The count advances and the keycode byte changes from `04` to `09`.  Reports
therefore pass not only through the controller and HID callback, but also
through this port's device-address/instance guard into `keyboard_last[]` and
`keyboard_reports`.  The guard is proven; there is no remaining report-path
ambiguity.

Page 5 reports:

```text
  kbd ep state   : 03       busy lock     : 01
  hid ep_in      : 81       epin after wr : 08
  ep81 submits   : 0A       epin_size     : 08
  hidh_xfer_cb   : 09       report_cb     : 09
  itf clears     : 10
```

The accounting is exact: ten EP81 submissions, nine HID completions and nine
application report callbacks means one interrupt-IN request is currently
outstanding.  Consequently endpoint state `03` and busy lock `01` are the
normal armed state at the instant of the snapshot, not a stall.  The repaired
object contains endpoint `81h` and packet size 8 at open, at first arm and
through every re-arm.  `itf clears = 10` still confirms one initialization and
zero closes.

This closes the MAX3421E/hub/keyboard report bring-up.  The next phase is
application work: boot-keyboard state-to-VT100 translation, an IOC-side input
queue, and a user-mode command path to exercise it before integrating with
BIOS `CONST`/`CONIN`.

## UPSTREAM TINYUSB: we are 1481 commits behind, and some of this is already fixed

The vendored tree is a git submodule pinned at `3af1bec1a` (tag **0.20.0**).
Upstream has moved a long way, and a fetch shows several commits that bear
directly on problems this document spent time on.

**Already fixed upstream, and we hit them independently:**

- `f615202b9` *"We must wait at least the requested amount"* — literally the
  delay-completes-early bug diagnosed here at level 35:
  ```diff
  -  at_ms = tusb_time_millis_api() + ms;
  +  // add one to ensure we wait at least 'ms' milliseconds
  +  at_ms = tusb_time_millis_api() + ms + 1;
  ```
  Independent agreement on the diagnosis. Ours is the same idea, made more
  conservative for a 10 ms tick.
- `usbh_defer_func_ms_async()` / `usbh_call_after_ms()` (`0daa444a9`,
  `56fca0076`) — enumeration delays are now **non-blocking**. That removes the
  150 ms busy-wait inside `tuh_task()` and with it the SIO-timing hazard this
  port currently just tolerates.
- `d754c0697` — asynchronous control transfer queuing. May remove the need for
  the XC8 patch that refuses callback-less control transfers.
- `3a262cb6e` / `ace993c21` — false negative and false positive in
  `tuh_task_event_ready()`. Directly relevant to a polled port.
- `f96757a19`, `4202e1e2d`, `41b8ad203` — MAX3421E start-up hang, CHIPRES reset
  logic and oscillator stabilisation timing.
- `66c4d470e` — retry hub port status if the reset change is not set within
  20 ms.
- `9d68ed65f` — endpoint state handling refactored from a struct to a plain
  `uint8_t`; touches the `EP_STATE_ATTEMPT_1` semantics examined at level 43.
- `17185428d` — `CFG_TUH_CONTROL_PENDING_QUEUE_SZ` defaults when a hub is
  enabled.

**Not fixed upstream, and never will be:** the XC8 overlay defects. Those are
compiler codegen faults, not TinyUSB bugs — `queue_event` staging, the
`hub_open` `dev_addr` restore, the weak-symbol guards. All of them would have to
be re-derived against restructured code.

**Cost of the jump:**

```text
                                           to 0.21.0   to master
commits                                        1188        1481
src/host/usbh.c            lines changed       1085        1129
src/host/hub.c                                   79         102
src/tusb.c                                      307         330
src/portable/.../hcd_max3421.c                    0          47
```

`usbh.c` is essentially rewritten. Every one of the 33 `__XC8` guards would need
re-application against that.

### Recommendation

**Not mid-debug.** We are one measurement from identifying the current fault.
Replacing 1481 commits of third-party code while holding an unexplained failure
destroys the ability to attribute anything that happens next — if the keyboard
then works, we would not know which change did it, and if it does not, we would
have two unknowns instead of one.

**But schedule it immediately afterwards, as its own task.** The evidence that
this is worth doing is that we already hand-implemented one of upstream's fixes
without knowing it existed, and the async-delay work would resolve a hazard this
port currently accepts on faith.

Note `hcd_max3421.c` is **unchanged** at 0.21.0 and only 47 lines different at
master, so the MAX3421E-specific fixes above landed after 0.21.0. That argues
for going to master rather than the tag, despite the extra 293 commits.

This also raises the value of the cleanup task below rather than lowering it: if
an upgrade is coming, having the XC8 delta as one reviewable patch file is the
difference between a day's work and an archaeology exercise.

## CLEANUP TASK — do not ship without doing this

The vendored TinyUSB tree at `third_party/tinyusb` now carries **33 `__XC8`
guards across 7 files**, plus 35 `usbh_xc8_*` debug symbols. That is a large
uncommitted delta against an upstream project, and it is not all the same kind
of thing. Sorting it is a real task, not a tidy-up.

Inventory as of level 42:

```text
src/host/usbh.c                              14 guards
src/host/hub.c                               13
src/host/hub.h                                2
src/tusb.c                                    1
src/class/hid/hid_host.c                      1
src/common/tusb_fifo.h                        1
src/portable/analog/max3421/hcd_max3421.c     1
```

### 1. Separate load-bearing patches from scaffolding

**Load-bearing — the firmware is wrong without these:**

- `usbh.c` `tuh_control_xfer`: the XC8 branch that refuses a callback-less
  control transfer instead of entering a spin that this port cannot break.
- `usbh.c` `queue_event`: staging copy of the event, because XC8 overlays the
  caller's live `hcd_event_t` with the nested FIFO call's arguments (level 35).
- `hub.c` `hub_open`: `desc_ep` capture (level 36) and the `dev_addr` restore
  across `tuh_edpt_open()` (level 40).
- `tusb.c`: `tusb_time_delay_ms_api` guard, so this port can supply a delay that
  cannot complete early on a 10 ms tick.
- Weak-stub guards in `usbh.c`, `hid_host.c` — XC8 ignores `TU_ATTR_WEAK`, so
  the port must supply those callbacks.
- The two `(uintptr_t)` cast removals in `hcd_max3421.c` and `tusb.c`. Harmless
  today; required if `-mstack=software` is ever adopted.

**Scaffolding — delete or keep deliberately, but decide:**

- All 35 `usbh_xc8_*` counters and traces in `usbh.c`, `hub.c`,
  `hcd_max3421.c`.
- HIDSTAT pages 1-4 and the `HidHostDebug` / `HidHostXfer` / `HidHostEnum`
  plumbing behind them.

Some of the scaffolding has earned its place — `mounted addrs`, the enumeration
milestones and the `enumerating` gate are genuinely useful for field
diagnosis. Others were built to answer one question and have answered it. The
`xfer events up` nibble is actively misleading and should go regardless.

### 2. Make the patches survive a TinyUSB update

Right now these are scattered in-tree edits with no record. A `git pull` of
TinyUSB, or a fresh checkout, silently drops every one of them and the
firmware regresses to a state whose failure modes took this entire document to
diagnose. Options, roughly in order of preference:

1. A single `patches/tinyusb-xc8.patch` applied by the build, so the delta is
   reviewable in one place and fails loudly if it stops applying.
2. Upstream the genuinely general fixes. The `queue_event` staging and the
   `hub_open` lifetime bugs are real defects for **any** compiler that uses a
   static-auto/overlay model, not XC8 quirks — TinyUSB may well take them.
3. At minimum, a `third_party/tinyusb/XC8-PATCHES.md` listing each guard, why
   it exists, and which level introduced it.

### 3. Revisit the toolchain decision

`-mstack=software` builds and removes the overlay allocator that caused three
of these bugs. It was deferred for good reasons (98% RAM, slower calls, SIO
timing risk) — see the section above. Once the keyboard works, that trade
should be re-measured rather than left as folklore, because every future
TinyUSB call path carries the same latent risk.

## Phase 3: keyboard input is one keystroke behind

Reports work and `HIDKEY.COM` echoes them to the console, but each keypress
prints the **previous** character: `a`, `b`, `c` produce `ab` and then `c` on the
fourth press.

### What was measured, and what it ruled out

| Observation | Rules out |
|---|---|
| `N` presses before starting hidkey yield `N-1` characters | a timing race; the deficit is exactly one, always |
| Holding `a` gives `last report : 00 00 04` | the report not arriving; decode does see the press |
| Pressing `a`,`b`,`c` prints `ab` | a lost first report — it is a genuine shift, not a dropped head |
| hidkey never prints `!` | the byte sitting undelivered in the queue |

That last row needs a caveat: the `!` detector only fires when a poll returns
zero bytes *while* the queue is non-empty. If a byte is drained on the very next
poll — microseconds later — that window never exists, so no `!` is equally
consistent with correct operation. It was presented at the time as though it
discriminated, and it did not. The `a`/`b`/`c` test is what actually settled the
shape.

The full path was read line by line — decode ordering, `translate_key`, the ring
buffer, `handler_hid_input`, the frame offsets, the main loop and hidkey's emit
loop — and every piece is correct in isolation.

### Hypothesis: zero-length completions

```c
uint8_t copy = (len < 8u) ? (uint8_t)len : 8u;
for (i = 2u; i < copy; i++) { ...decode... }     // len == 0: never runs
for (i = 0u; i < copy; i++) keyboard_last[i] = report[i];
for (; i < 8u; i++) keyboard_last[i] = 0u;       // ...and clears the history
```

A completion carrying **no data** decodes nothing *and* wipes `keyboard_last`.
The following completion then presents the previous keystroke against an empty
history, so it decodes as new. That produces exactly the observed shift: press
`a` emits nothing, press `b` emits `a`.

A plausible source is `hcd_int_handler()` servicing `HXFRDN` in a pass where
`RCVDAV` has not yet been latched: the transfer completes with the buffer
untouched, and the data arrives against the next armed transfer.

### Level 63

The callback records the length of every completion and counts the zero-length
ones:

```text
last rpt len    len of the most recent completion; 08 expected
zero-len rpts   completions that carried no data
```

`zero-len rpts` climbing in step with keypresses confirms it. If it stays at
zero, the shift is elsewhere and the decode is being fed full reports that are
themselves stale, which is a different fault in the HCD buffer path.

### Level 63/64: the zero-length hypothesis dies, and so does the queue

`zero-len rpts` read `00`. Every completion carried a full eight bytes, so the
decode was never fed an empty report and `keyboard_last` was never wiped. The
hypothesis above is wrong; it is left in place because the reasoning was sound
and only the measurement settled it.

Level 64 then instrumented the two ends of the ring buffer itself —
`input_put_total` and `input_get_total`, reported on HIDSTAT page 5 as
`queue put tot` / `queue get tot`. That produced the measurement that ended the
hunt:

```text
queue put tot = 00      queue get tot = 00      (idle)
press "a"
queue put tot = 01      queue get tot = 00      (hidkey not running)
start hidkey, press "b", Ctrl-C to exit
queue put tot = 03      queue get tot = 03
```

Three bytes in — `a`, `b`, Ctrl-C — and **three bytes out**. The queue accepted
and handed over every byte. One character reached the screen.

That single line retires the entire controller-side search. Combined with two
properties of the transport that were then read out of the code rather than
guessed at:

- `external_sync_send()` is LEN-driven and CRCs the length word and exactly
  `data_len` payload bytes; `ioc_command_recv_frame` validates that CRC before
  mapping the packet into the mailbox. hidkey never reported a transport error,
  so the host provably received the exact bytes and the exact count the IOC
  sent.
- `IOC_HID_INPUT_META_LEN` is 2, the handler sets `LEN = 2 + count`, and hidkey
  computes `byte_count = LEN - 2`. The two ends agree.

So `HIDKEY.COM` called BDOS CONOUT once per byte, for every byte. The USB stack,
the ring buffer, the frame layout and the wire were all correct the whole time.

### The lag was the console, and it was never a HID fault

`text_put_printable` does not display anything:

```asm
text_put_printable:
	call v9958_append_printable	; accumulate into print_run_buffer
	ld a,(text_col)
	cp #(TEXT_LOG_COLUMNS - 1)	; only at end of line...
	jr nz,text_put_printable_advance
	call v9958_flush_print_run	; ...does the run get published
```

Printable characters are batched into one `OP_TEXT_RUN` — deliberate, to avoid a
packet per character. The run is published (flush, cursor write, `OP_PRESENT`)
from **`vdrip_console_const` and `vdrip_console_conin` only**, and
`vdrip_console_const` carries a comment that describes this exact trap:

> Publish pending output before input polling. Programs such as TP3 poll CONST
> between echoed characters without necessarily entering CONIN, so a flush
> without OP_PRESENT would leave each character invisible until the next
> keypress.

Every normal program gets that publish for free, because the CCP and BDOS poll
console input constantly. hidkey does not: it polls the IOC through IOCALL and
never touches console input.

What turned "invisible" into "exactly one behind" is CP/M 2.2's own output
routine, `OUTCHAR` in `cpm22.asm`:

```asm
OUTCHAR:...
        CALL    CKCONSOL        ;check console (we don't care whats there).
        ...
        CALL    CONOUT          ;output (C) to the screen.
```

`CKCONSOL` calls CONST **before** CONOUT. So every BDOS function 2 call
publishes the run accumulated so far — all *previous* characters — and then
appends the current one, which stays invisible until the next call. One
character behind, released one at a time by the following character.

This accounts for every observation at once, including the two that were most
misleading:

| Observation | Explanation |
| --- | --- |
| `N` presses yield `N-1` characters | the last character is still in the run buffer |
| `a`,`b`,`c` prints `ab` then `c` later | each CONOUT publishes the previous character |
| `put == get` | the controller side was always correct |
| hidkey never printed `!` | the queue was never stuck; it was being drained normally |
| HIDSTAT always looked fine | it exits to the CCP, whose CONST loop publishes the run |

Fix, in `hidkey.asm` only — no firmware change:

```asm
emit_done:
	call console_publish
	jp poll

console_publish:
	push hl
	ld c,#BDOS_CONSTAT	; BDOS 11 -> BIOS CONST -> flush, cursor, present
	call BDOS
	pop hl
	ret
```

`vdrip_console_const` returns immediately when the run is empty and is
documented as safe for hot polling loops, so this costs nothing when idle. The
stuck-detector output is routed through the same helper.

This is a test-harness artifact, not a defect in the console driver: the
batching design is intentional and its publish points are documented. It will
not recur once HID input is delivered through CONST/CONIN, because those are the
very calls that publish the run. It is recorded here because it cost a long
hunt on the wrong side of the link, and because **any** future polling program
that writes to the console without touching console input will hit it again.


## Keymap survey

With the display lag closed, the keymap was surveyed key by key. Working as
intended: printable US layout, Caps Lock (no LED, expected), backspace,
keypad (always NumLock, no LED, expected), no auto-repeat (expected), and Tab —
`term_tab` advances to the next 8-column stop, which from column 0 is
indistinguishable from eight spaces but is the correct VT100 behaviour.

Everything that looked wrong turned out to be the **terminal output parser**,
not the keymap. `HIDKEY.COM` echoes IOC input straight to CONOUT, so escape
sequences generated by the keyboard are fed to `term_process_byte` and
*executed* as terminal commands rather than displayed. The survey was measuring
the wrong direction.

The reference measurement settles it: on the VDrip console, F1 reads `^[OP` and
Ctrl-C reads `^C`. That is CP/M echoing console input in caret notation, and
`^[OP` is `1B 4F 50`. `translate_key()` emits `input_put_escape('O', 'P')` —
the same three bytes. **The USB keymap agrees byte-for-byte with the proxy
keyboard already in use.**

| Observation | Cause |
| --- | --- |
| Home goes upper left | `ESC[H` is CUP; the terminal *executes* cursor-home rather than delivering a Home key |
| Insert reads `^[[2~` | correct — it is Insert's sequence, not a misdispatched Home. Home reads `^[[H` |
| End does nothing | `ESC[F` is correct; `'F'` is not a final byte in `ansi_dispatch_public`, so it is consumed |
| F5–F12 do nothing | `ESC[15~`..`ESC[24~` are correct; `'~'` is likewise not a handled final |
| F1–F4 print `P`/`Q`/`R`/`S` | **real parser bug** — see below |
| Ctrl-`n` does nothing | correct: 0x01–0x1A are generated, and the terminal ignores control bytes below 0x20 except BS/TAB/CR/LF. Ctrl-C only exits because hidkey intercepts 0x03 |

### SS3 leaked its final byte

`term_process_esc` recognised `ESC #`, `ESC (`, `ESC )` and a list of single-byte
finals, but not `ESC O` — SS3, the application keypad/function-key introducer.
The `'O'` fell through unmatched and was swallowed, leaving the *final* byte to
arrive in NORMAL state and print as text. F1 typed a literal `P`.

Fixed by routing `'O'` to the existing `TERM_STATE_CHARSET` one-byte-consume
path, alongside `ESC (` / `ESC )`. This is a genuine defect independent of the
keyboard — any program printing an SS3 sequence would have leaked a stray
character.

`ESC[F` and the `~` finals were deliberately **not** added. Those are input
sequences: a keyboard sends them, programs do not print them, and inventing a
display action for "End" as an output command is meaningless. They are consumed
silently, which is correct.

### hidkey now shows bytes instead of executing them

`HIDKEY.COM` renders control bytes in caret notation, matching the CP/M echo
convention that produced the `^[OP` reference above, so a key's sequence is
legible instead of disappearing into the ANSI parser. CR and LF still pass
through raw — their display action is more useful than their name, and without
them the survey runs off one line.

Note that this stops hidkey exercising the terminal parser at all: it no longer
emits raw ESC, so the SS3 fix is not observable through it. That fix is verified
by inspection and by any program that prints SS3 directly.

### Survey re-run: clean

With the ROM and the caret-notation harness in place, every key reads correctly:

```text
F1-F4    ^[OP ^[OQ ^[OR ^[OS      SS3 -- these are the VT100 PF1-PF4 keypad keys
F5-F12   ^[[15~ ^[[17~ ^[[18~ ^[[19~ ^[[20~ ^[[21~ ^[[23~ ^[[24~
Home     ^[[H          End       ^[[F
Insert   ^[[2~         Delete    ^[[3~
PgUp     ^[[5~         PgDn      ^[[6~
Tab      ^I            Backspace ^H
```

Two things in that table look like defects and are not, so they are recorded
here to stop a later "fix":

- **F5-F12 skip 16 and 22.** The sequence is 15,17,18,19,20,21,23,24. That is
  the historical VT220/xterm numbering, not an off-by-one.
- **F1-F4 use a different form from F5-F12.** SS3 rather than CSI-tilde,
  because on a real VT100 they are the PF1-PF4 keypad keys.

The keymap is complete. What remains is delivery, not translation.


## Level 65: LEDs and auto-repeat

**Keyboard LEDs.** Caps Lock and Num Lock now drive the physical lights via a
HID SET_REPORT (output report, one byte: NumLock 0x01, CapsLock 0x02).

Two things constrain where that call can live:

- The report buffer **must be static**. SET_REPORT is an asynchronous control
  transfer and TinyUSB still references the buffer after
  `tuh_hid_set_report()` returns. A local would be a use-after-return that
  works right up until the stack is reused promptly.
- It is issued from `hid_host_task()`, not from `translate_key()`. Calling it
  from inside the report callback would re-enter the control pipe in the middle
  of USB processing. If the pipe is busy the call fails and `led_dirty` simply
  stays set for the next pass, so a lost race costs one task iteration.

`led_dirty` is forced true at mount rather than going through `led_refresh()`:
a freshly enumerated keyboard has its LEDs dark, so the state we want and the
state it is in agree numerically while disagreeing physically.

**Num Lock became real.** The keypad was unconditionally numeric, which was
invisible and therefore harmless. With a light on the key it would be a lie, so
Num Lock off now puts the keypad on its navigation layer (7/8/9 -> Home/Up/PgUp
and so on). That test has to run **before** the ASCII table, which has entries
for the keypad digits and would otherwise answer first. Power-on and mount both
default to Num Lock on, matching the previous behaviour.

**Auto-repeat.** Boot keyboards report on state change only -- nothing at all
arrives while a key is simply held -- so repeat is synthesised in
`hid_host_task()` against `tusb_time_millis_api()`: 500 ms initial delay, then
60 ms period.

- The newest pressed key takes over the repeat and restarts the delay; the
  current one continues only while still held. `keyboard_last` is updated
  before the check, so `key_was_down()` reads there as "is still held".
- Lock keys are excluded -- repeating them would flap the state.
- Modifiers are re-sampled every report, so shifting mid-repeat changes what
  repeats.
- Repeat is skipped while the queue is more than half full. A key held with
  nothing draining would otherwise spend the whole buffer and start counting
  drops, losing real keystrokes behind it.

`task_now_ms` is a file-static, not a local. It lives across a call into
`translate_key()` and its nested helpers, which is exactly the shape XC8's
static-auto overlay corrupts.

Build at level 65: program 49.5%, data 58.1%. The 100% data-stack figure is the
fixed `hybrid:512` reservation, not a warning.


## Still open

1. BIOS CONST/CONIN integration. Decode, the IOC-side queue and the
   `CMD_HID_INPUT` transport all work end to end, and `HIDKEY.COM` exercises
   them. What remains is delivering those bytes through the BIOS console
   entry points instead of a polling test program, so that ordinary CP/M
   programs see USB keystrokes. hidkey stays a harness and is not the
   destination.
2. `possible hardware stack overflow detected; estimated stack depth: unknown
   (due to recursion)` at `main.c` appeared once the enumeration path became
   reachable. This is the PIC18 **hardware** call stack, not the data stack
   whose 100% figure was a false alarm. XC8 cannot bound the depth because
   TinyUSB's function-pointer callback tables look cyclic to its call-graph
   analysis. It was not implicated in enumeration or report delivery, but
   remains an explicit risk to assess before declaring the USB path production
   ready.
