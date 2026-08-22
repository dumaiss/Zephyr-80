# IO Controller Transport

The Z80 and the PIC talk over the two SIO1 channels, which are **one transport
with two lanes** rather than two independent protocols:

```text
                    IOCALL
                       |
              +--------+--------+
              |                 |
          SIO1/B             SIO1/A
          COMMAND             BULK
              |                 |
      command / READY      raw N bytes
          / DONE
              |                 |
              +--------+--------+
                       |
               single transaction
                     state
```

The command lane is always authoritative: it decides when the bulk lane is
valid, in which direction, and how many bytes it carries.  The bulk lane has no
framing of its own.

Both lanes are Z80 SIO channels in External Sync mode with the PIC as clock
master, and both ride the same SPI2 module and the same RB1/RB3 pins -- only the
select and the External Sync strobe differ:

```text
                select        sync       Z80 ports
  command lane  /SIOB_CS RA4  /SYNCB RA7  32h data, 33h ctrl
  bulk lane     /SIOA_CS RA5  /SYNCA RA6  30h data, 31h ctrl
```

Command lane implementation: `src/external_sync.c`.
Bulk lane implementation: `src/bulk_channel.c`.

The rest of this document covers the command lane, the mailbox and per-command
wire formats, the lifecycle that joins the two lanes, and finally the bulk lane
and the low-level command-lane timing.

## Command Lane

The link is intentionally simple.  The Z80 BIOS configures SIO1/B for External
Sync mode and polls the SIO data/status registers.  The PIC does not program the
SIO.  The PIC only drives the serial-side wires: clock, data into the SIO, and
the SIO `/SYNCB` input.

## Hardware Signals

```text
PIC18F57Q84                            Z80 SIO1/B
-----------                            ----------
RB3  SIO_SCK    ------------------->    RXTXCB
RB1  SIO_MOSI   ------------------->    RXDB
RB2  SIO_MISO   <-------------------    TXDB
RA7  /SYNCB     ------------------->    /SYNCB
RA4  /SIOB_CS   ------------------->    bus select / TXDB buffer enable
RF0  /SIO1B_INT <-------------------    service request
```

Important board detail: clock and data are a board-wide shared bus.  `/SIOB_CS`
is what puts SIO1/B on `SIO_MISO` and keeps the SD card, USB bridge and
controller latch off the bus, so it must be asserted for the whole transaction.
`/SYNCB` is a separate pin carrying only the External Sync strobe.

On the previous revision both jobs lived on a single pin (`RA1`).  They are now
split, so a change to sync timing no longer changes bus ownership.

## Transport: SPI2

The bulk of every transfer runs on the SPI2 hardware module.
SPI2 is the correct module for this bus because its reset-default PPS inputs are
already `SCK = RB3` and `SDI = RB2`; SPI1's defaults are RC3/RC4, the port C
peripheral bus.  Neither `SPI2SCKPPS` nor `SPI2SDIPPS` therefore needs touching,
and only the two output routes (`RB1PPS`, `RB3PPS`) are claimed.

The SPI path is a hybrid:

- **Receive** is entirely hardware.  `/SYNCB` is asserted for the whole window
  and MOSI only idles marking, so shifting out `FFh` reproduces it exactly.
- **Reply byte 0 stays bit-banged.**  `/SYNCB` has to fall between bit 1's
  rising and falling edges, and a hardware shift register cannot be interrupted
  mid-word.  `sync_assert()` is idempotent, so bytes 1..31 and the trailing
  flush byte need no intra-byte GPIO and go through SPI2.
- `RB1PPS`/`RB3PPS` are switched between LATB and SPI2 around the bit-banged
  phase.  The changeover is glitch-free because `CKP = 0` idles SCK low, which
  is the level LATB3 already holds.

The SPI clock is `SPI2CLK = 0` (Fosc) with `SPI2BAUD = 31`, giving
`64 MHz / (2 * 32)` = **1.000 MHz**.

Bit rate is not what protects the host.  The BIOS polls RR0 in software behind
a 3-byte SIO FIFO, so the *byte* rate is the constraint, and it is held at the
800 us the bit-banged path produced.  The inter-byte gap is derived from the
baud rate (`EXTSYNC_BYTE_GAP_US = EXTSYNC_TARGET_BYTE_US - EXTSYNC_SPI_BYTE_US`)
so changing the baud alone cannot silently change the pacing the host depends
on.  At 1 MHz that is 8 us of clocking plus a 792 us gap.

Consequently, raising the baud rate on its own buys almost nothing -- the gap is
99% of the byte period.  `EXTSYNC_TARGET_BYTE_US` is the knob that actually
makes the link faster, and the one that risks overrunning the host.

External Sync counts clock edges and is indifferent to gaps between bytes.

The two PPS output source codes come from Table 21-2 "PPS Output Selection
Table" in DS40002213D: `0x35` for SPI2 SDO and `0x34` for SPI2 SCK.  The table
also confirms both are reachable on port B for the 48-pin package.  These values
are in neither the XC8 headers nor the DFP device file, which carry only the
register layout -- the routing table exists only in the datasheet.

For the port C bus later, the same table gives `0x32` for SPI1 SDO and `0x31`
for SPI1 SCK, both available on port C.

## SIO Mode

The Z80 BIOS owns all SIO register writes.  The PIC assumes the BIOS has placed
SIO1/B in External Sync mode:

- `/SYNCB` is an input driven by external logic, not an output from the SIO.
- Receive character assembly is aligned by the external `/SYNCB` transition.
- The SIO receives and transmits serial data LSB-first.
- The BIOS polls RX-ready/TX-ready instead of using SIO1/B interrupts.

The SIO manual behavior that matters here is:

- In External Sync mode, the external circuit drives `/SYNC` low after the sync
  timing condition.
- The SIO starts assembling receive characters relative to the receive-clock
  edge just before `/SYNC` falls.
- Once synchronized, synchronous receive continues until the CPU disables the
  receiver, resets the SIO, or re-enters hunt mode.

## Mailbox Format

Every command transaction carries one fixed 32-byte mailbox.

```text
byte 0      command / response class
byte 1      sequence
byte 2      status
byte 3      payload length
bytes 4-19  payload
bytes 20-31 reserved / command-specific
```

Current command classes:

```text
01h  CMD_PING          echo the payload back
02h  CMD_RESET         assert the host reset pair, then self-reset the PIC
03h  CMD_SD_READ       read SD block 0, return its first 16 bytes inline
04h  CMD_BULK_TEST     stream a 00 01 02 ... ramp on the bulk lane
05h  CMD_SD_READ_BULK  read one sector, stream it on the bulk lane
06h  CMD_XFER_STATUS   query the DONE record of the last bulk transfer
```

`CMD_SD_READ` and `CMD_BULK_TEST` are bring-up scaffolding.  `CMD_SD_READ` is
the only SD path that does not depend on the bulk lane, which keeps it useful
for isolating a fault to one lane or the other.

Current response classes:

```text
81h  RSP_PING
83h  RSP_SD_READ
84h  RSP_BULK_TEST
85h  RSP_SD_READ_BULK
86h  RSP_XFER_STATUS
FEh  RSP_UNKNOWN_COMMAND
```

Status bytes (byte 2 of a reply):

```text
00h  IOC_STATUS_OK
01h  IOC_STATUS_ERROR
02h  IOC_STATUS_UNKNOWN_CMD
10h  IOC_STATUS_SD_NO_RESPONSE   card never answered a command
11h  IOC_STATUS_SD_UNUSABLE      answered, but not a supported card
12h  IOC_STATUS_SD_NOT_READY     ACMD41 never reported ready
13h  IOC_STATUS_SD_READ_FAIL     CMD17 rejected, or no data token
14h  IOC_STATUS_SD_BUS           the SPI module itself stalled
20h  IOC_STATUS_BULK_FAIL        bulk lane stalled mid-transfer (DONE only)
```

The SD status codes map one-to-one onto `SdStatus`, so a host-side dump of the
status byte says which stage of the card bring-up gave up.

## Command Wire Formats

### SD_READ

```text
request   class=03h seq=01h status=00h len=00h, payload unused
reply     class=83h seq echoed, status per the table above
          len=10h and bytes 4..19 = first 16 bytes of block 0 on success
          len=00h and no payload on failure
```

### SD_READ_BULK

```text
request   class=05h seq=01h status=00h len=04h
          [4..7]  32-bit LBA, little-endian

reply     class=85h seq echoed
          success: status=00h len=04h, READY payload (see below), bulk follows
          failure: status=SD code, len=04h, xfer_id=0 and length=0,
                   and NO bulk phase is staged
```

### XFER_STATUS

```text
request   class=06h seq=01h status=00h len=00h, payload unused
reply     class=86h seq echoed status=00h len=02h
          [4]  xfer_id of the last bulk transfer
          [5]  DONE status: 00h OK, 20h bulk stalled
```

### BULK_TEST

```text
request   class=04h seq=01h status=00h len=02h
          [4..5]  requested length, little-endian; 0 means 256

reply     class=84h seq echoed status=00h len=04h, READY payload
          then a 00 01 02 ... ramp of that length on the bulk lane
```

## Transaction Lifecycle

Commands that move more than a mailbox-worth of data hand off to the bulk lane
through an explicit **READY -> BULK -> DONE** lifecycle:

```text
Z80                              PIC
 |-- SD_READ_BULK(LBA) --------->|   command lane
 |                               |-- read the sector into MCU SRAM
 |<-- READY(id, dir, length) ----|   command lane
 |                               |
 |<========== length bytes ======|   bulk lane
 |                               |
 |-- XFER_STATUS --------------->|   command lane
 |<-- DONE(id, status) ----------|   command lane
```

A write would be symmetrical, with the bulk arrow reversed and `DONE` withheld
until the card has actually committed the data.

State on the PIC:

```text
        IDLE --command--> PREPARE --READY--> BULK_ACTIVE --length bytes--> IDLE
```

Rules that matter:

- **The card is read before READY is sent.**  READY is therefore a promise that
  the bytes are already in SRAM, which keeps SD latency out of the bulk
  transaction and leaves room for double-buffered multi-sector reads later
  without changing this API.
- **READY and DONE mean different things.**  READY means "a buffer is prepared
  and this many bytes are coming".  DONE means "the operation actually
  succeeded".  For a write those are very different claims: 512 bytes arriving
  intact over the bulk lane says nothing about whether the card committed them.
- **A failure before READY suppresses the bulk phase entirely.**  On an SD
  error the reply carries the SD status with `length = 0` and `xfer_id = 0`, and
  no transfer is staged, so the host must not enter its read loop.  That is the
  difference between `READY 512 / <bytes> / DONE SD_TIMEOUT` and a bare
  `ERROR WRITE_PROTECTED` where bulk never starts.
- **One transfer at a time.**  No second IOCALL is issued while a bulk phase is
  outstanding.  The Z80 is inside a synchronous BIOS call anyway, so concurrency
  would buy nothing and add races.  An `ABORT` on the command lane during bulk
  is the one exception worth adding eventually; it is not implemented.

### READY payload

Status is already frame byte 2, so the payload carries the rest:

```text
byte 4  xfer_id      0 means "no transfer"; never reused consecutively
byte 5  direction    00h = MCU -> Z80, 01h = Z80 -> MCU
byte 6  length low
byte 7  length high
```

Length is 16-bit, which is ample for single-sector transfers; widening it later
does not disturb anything else.

### DONE payload

```text
byte 4  xfer_id
byte 5  status       00h OK, 20h bulk stalled
```

The `xfer_id` is not decoration.  The host records the id from READY and
compares it against DONE; a mismatch means a transfer was lost or overlapped,
and catching that costs one byte:

```text
SD_READ_BULK request:  xfer=27
READY:                 xfer=27, 512 bytes
DONE:                  xfer=27, OK
```

A `DONE xfer=26` says immediately that something went sideways.

## Bulk Lane

Once READY has said `direction = MCU -> Z80, length = 512`, SIO1/A carries
exactly 512 bytes:

```text
<byte 0>
<byte 1>
...
<byte 511>
```

No packet header, no command byte, no escaping, no terminator.  The command lane
already supplied every piece of framing information, so the host side is a plain
poll-and-read loop.

### Byte 0 carries the sync edge

The one thing that is not quite dumb: SIO1/A is also in External Sync mode, so
the PIC must provide a `/SYNCA` transition for the receiver to leave hunt and
start assembling characters.  That edge lands inside the first clocked byte,
exactly as the 7Eh preamble works on the command lane.  The byte is still
delivered as data, so the host still reads exactly `length` bytes.

### /SYNCA drops one bit earlier than /SYNCB

`clock_sync_byte_a()` drops `/SYNCA` during **bit 0**, where the command lane
drops `/SYNCB` during **bit 1**.  That is measured, not chosen.

With the drop mirroring channel B, a `00 01 02 ...` ramp read back as `80h` for
its first byte.  On the wire, LSB-first:

```text
byte 0 = 00 : 0 0 0 0 0 0 0 0
byte 1 = 01 : 1 0 0 0 0 0 0 0
```

A receive window starting one bit late assembles wire positions 1..8 =
`0,0,0,0,0,0,0,1`, which LSB-first is `80h`.  A window one bit *early* would
have produced `00h` -- indistinguishable from correct -- so the direction was
unambiguous.  Moving the drop one bit earlier put the window back in alignment,
and the full 512-byte sector then verified including its `55 AA` signature.

**Why the two channels differ is not established.**  The BIOS configures them
through different paths -- `sio1_ioc_init` runs once at boot for channel A,
while `sio_command_init` runs at the start of every IOCALL for channel B -- and
they write different WR3/WR4 sequences.  That is the first place to look if this
ever needs revisiting.  Until it is understood, the two hand-clocking routines
should stay separate rather than being unified behind a channel parameter that
would hide the discrepancy.

`BULK_SYNC_DROP_BIT` in `src/bulk_channel.c` exists so the position can be
bisected from the bench without restructuring the sequence.

### Start guard

The PIC is clock master and there is no ready signal from the Z80 on this lane,
so after sending READY it waits `BULK_START_GUARD_MS` (20 ms) before clocking.
That delay is the only thing preventing the transfer from starting before the
host's read loop is running; the SIO's 3-byte receive FIFO covers about 48 us at
the current byte rate, nowhere near enough to absorb the gap.

Consequences worth knowing:

- The host must not print or do other work between IOCALL returning and its read
  loop, and should put the bulk receiver into hunt *before* issuing the command.
- The guard dominates throughput.  A sector costs roughly 52 ms end to end, of
  which about 30 ms is guard delay (20 ms here plus the 10 ms reply guard on the
  command lane) and only 8 ms is actual data movement.

`/SIO1A_INT` on RF1 is wired but unused.  Having the Z80 assert RTS on channel A
and the PIC wait for that edge would remove this guard entirely and make the
handoff deterministic instead of timed.  That is the obvious next improvement if
sector throughput starts to matter.

Adding a command class means touching three places in the firmware: the
constants in `include/ioc_frame.h`, a case in `src/dispatch.c`, and a clause in
`find_frame_start()` in `src/external_sync.c`.  That last one is easy to miss --
it is the fallback used when the host's alignment byte is not found, and its
per-class length match is what keeps the bit-offset scan from locking onto a
wrong alignment.  No host-side change is needed, because replies lead with the
7Eh alignment byte.

## Transaction Walkthrough

```text
Z80 BIOS                          PIC firmware
--------                          ------------
prepare SIO1/B
assert /SIO1B_INT low  ---------> detect RF0 high-to-low edge
write request bytes to SIO        clock request window from TXDB
                                  decode one 32-byte mailbox
                                  dispatch command
                                  clock reply mailbox to RXDB
read reply bytes from SIO
release /SIO1B_INT
```

The PIC services only the falling edge of /SIO1B_INT.  The line stays low during
the host IOCALL, so a level-triggered loop would repeatedly clock idle windows
after the real request had already passed.

## Request Receive

During request receive:

```text
/SIOB_CS low     -> SIO1/B owns the shared bus, TXDB buffer enabled
/SYNCB low       -> SIO /SYNCB asserted
SIO_MOSI high    -> marking idle toward SIO RXDB
SIO_SCK          -> 80 byte-times generated by the PIC
SIO_MISO         -> sampled into rx_window[]
/SYNCB high      -> sync idle
/SIOB_CS high    -> bus free
```

The receive window is longer than the 32-byte mailbox because the Z80 request
may not begin on the first PIC-generated clock.  The firmware then extracts the
mailbox from the captured bit stream.

The current BIOS may place a single `7Eh` alignment byte immediately before the
mailbox.  The PIC accepts both shapes:

```text
direct:
  [32-byte mailbox]

with alignment byte:
  7E [32-byte mailbox]
```

The decoder first handles the already-byte-aligned case, then searches the
captured bit stream for the alignment byte, then falls back to a direct frame
search over the first 16 bit positions.  That last search is deliberately
limited and only accepts headers that look like current tiny commands:

```text
PING:    class=01h seq=01h status=00h len=00h or 10h
RESET:   class=02h seq=01h status=00h len=00h
SD_READ: class=03h seq=01h status=00h len=00h
```

That keeps the code readable while still tolerating the bit phase observed on
the bench.

## Reply Transmit

The reply leads with a 7Eh alignment byte, then the 32-byte mailbox.

That byte is not decoration.  The Z80 BIOS reply scanner (`IOC_CMD_RECV_SYNC`)
locks onto a frame start only on 7Eh or on a hard-coded `IOC_RSP_PING` (81h), so
a bare mailbox works for PING and nothing else -- any other response class is
scanned past and reported as `IOC_XPORT_BAD_FRAME` with the host's receive
buffer untouched.  Leading with 7Eh puts every reply on the BIOS's generic path,
so response classes can be added without touching the host.

The byte count is unaffected: both shapes sit at the same margin against the
SIO's one-byte RX-ready lag.

```text
bare:     32 + 1 flush = 33 clocked, 32 readable; host reads 1 scan + 31 body
preamble: 1 + 32 + 1   = 34 clocked, 33 readable; host reads 1 scan + 32 body
```

The reply timing is intentionally written out in `clock_reply_byte()` rather
than hidden behind a generic byte shifter.  This is the timing that produced a
working `PING OK`.

Before the first reply byte, the PIC sends two setup clocks while `/SYNCB` is
high:

```text
setup bit 0: SIO_MOSI=1, clock pulse
setup bit 1: SIO_MOSI=0, clock pulse
```

Then each reply byte is clocked LSB-first.  For every byte, `/SYNCB` is asserted
while bit 1 is being clocked, immediately after that bit's rising edge:

```text
clock idle low

bit 0:
  put data bit on SIO_MOSI
  wait
  SIO_SCK high
  wait
  SIO_SCK low

bit 1:
  put data bit on SIO_MOSI
  wait
  SIO_SCK high
  wait
  /SYNCB low
  wait
  SIO_SCK low

bits 2..7:
  put data bit on SIO_MOSI
  wait
  SIO_SCK high
  wait
  SIO_SCK low
  wait
```

ASCII timing sketch for the first reply byte:

```text
          setup        setup        byte0 bit0    byte0 bit1    byte0 bit2
SIO_SCK   ___/^\___    ___/^\___    ___/^\___     ___/^\___     ___/^\___
SIO_MOSI       1            0          b0[0]         b0[1]         b0[2]
/SYNCB  ----------------------------- high -------\_____________________
                                                   assert low here
```

After the 32 mailbox bytes, the PIC clocks one extra `FFh` marking byte while
`/SYNCB` remains asserted.  Bench behavior showed that the SIO RX-ready status
lags the clocked serial stream by one byte in this setup; the trailing marking
byte makes the final mailbox byte visible to the Z80 poller.  The BIOS reads
only the fixed 32-byte reply and discards stale state when it initializes the
next transaction.

## Why the Code Is Not More Abstract

The reply clocking is intentionally not collapsed into a generic "send byte"
helper.  Small timing changes in the setup clocks and `/SYNCB` edge placement
previously produced a host receive buffer filled with untouched `A5h` values.
The explicit sequence is easier to compare against a scope capture and against
the SIO External Sync timing rules.

## Related Source

- `src/main.c`: boot reset, /SIO1B_INT falling-edge detection, transaction flow.
- `src/external_sync.c`: command lane -- SPI2 setup, clocking, mailbox
  extraction.  Also exports the shared SPI2 primitives via `include/sio_link.h`.
- `src/bulk_channel.c`: bulk lane -- /SYNCA hand-clocking, staged transfers,
  DONE record.
- `src/sd_card.c`: SD card in SPI mode on the port C bus.
- `src/dispatch.c`: command class dispatch.
- `src/handlers.c`: all command handlers.
- Host bring-up programs in the HelloWorld project: `ioc_ping.asm`,
  `ioc_sd_read.asm`, `ioc_bulk.asm` (bulk lane ramp), `ioc_sdblk.asm` (full
  READY/BULK/DONE sector read).
- Host BIOS receive side:
  `/home/kitamura/Documents/Zephyr-80/Code/HOST/CPM2.2/src/cbios_ioc_command.asm`

## References

- Zilog Z80-SIO Technical Manual, hosted by Manx / Howard Harte archive:
  https://manx-docs.org/details.php/40,10863
- Z80 CPU Peripherals User Manual, SIO External Sync discussion:
  https://www.manualsdir.com/manuals/753750/zilog-z08470.html
- Zilog SCC/SIO-family External Sync behavior, useful cross-reference:
  https://www.alldatasheet.net/html-pdf/96934/ZILOG/Z8530/11218/87/Z8530.html
