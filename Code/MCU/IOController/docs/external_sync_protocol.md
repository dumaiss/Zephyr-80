# External Sync Command Link

This document describes the working PIC-to-Z80 SIO1/B command link implemented
in `src/external_sync.c`.

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
01h  CMD_PING     echo the payload back
02h  CMD_RESET    assert the host reset pair, then self-reset the PIC
03h  CMD_SD_READ  read SD block 0, return its first 16 bytes
```

Current response classes:

```text
81h  RSP_PING
83h  RSP_SD_READ
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
```

The SD status codes map one-to-one onto `SdStatus`, so a host-side dump of the
status byte says which stage of the card bring-up gave up.

### SD_READ

```text
request   class=03h seq=01h status=00h len=00h, payload unused
reply     class=83h seq echoed, status per the table above
          len=10h and bytes 4..19 = first 16 bytes of block 0 on success
          len=00h and no payload on failure
```

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
- `src/external_sync.c`: GPIO clocking and mailbox extraction.
- `src/dispatch.c`: command class dispatch.
- `src/handlers.c`: `PING`, `RESET`, and unknown-command handlers.
- Host BIOS receive side:
  `/home/kitamura/Documents/Zephyr-80/Code/HOST/CPM2.2/src/cbios_ioc_command.asm`

## References

- Zilog Z80-SIO Technical Manual, hosted by Manx / Howard Harte archive:
  https://manx-docs.org/details.php/40,10863
- Z80 CPU Peripherals User Manual, SIO External Sync discussion:
  https://www.manualsdir.com/manuals/753750/zilog-z08470.html
- Zilog SCC/SIO-family External Sync behavior, useful cross-reference:
  https://www.alldatasheet.net/html-pdf/96934/ZILOG/Z8530/11218/87/Z8530.html
