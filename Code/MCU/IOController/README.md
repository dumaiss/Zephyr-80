# IO Controller Firmware

Firmware project for the Zephyr-80 IO Controller MCU.

The default target is `PIC18F57Q84`.

## Build Firmware

```sh
make
```

The build emits firmware output into `build/`. Override paths when needed:

```sh
make DEVICE=PIC18F47Q84
make XC8=/path/to/xc8-cc DFP=/path/to/device/support
```

## Current Behavior

At boot the firmware asserts the host reset pair for 100 ms:

- `RF2` / `RESET` is driven low, then released high.
- `RF3` / `RESET_HIGH` is driven high, then released low.

After boot, the main loop polls `/SIO1B_INT` on `RF0`. A falling edge starts
one External Sync command transaction:

```text
select:  PIC RA4 /SIOB_CS puts SIO1/B on the SIO bus
request: Z80 SIO1/B TXDB -> PIC RB2 SIO_MISO, clocked by PIC RB3 SIO_SCK
reply:   PIC RB1 SIO_MOSI -> Z80 SIO1/B RXDB, clocked by PIC RB3 SIO_SCK
sync:    PIC RA7 drives SIO1/B /SYNCB
```

The bulk of the transfer runs on SPI2. A disposable byte is clocked by hand only
while establishing that lane's persistent `/SYNC` boundary; the complete
`A5 5A` packet marker then follows through SPI. See
[docs/external_sync_protocol.md](docs/external_sync_protocol.md) for what stays
bit-banged and why.

Throughput is set by `EXTSYNC_TARGET_BYTE_US` in `include/external_sync.h`,
currently 16 us (500 kbit/s). That is paced against the Z80 BIOS receive loop,
not against the SPI clock — see the header for the T-state budget.

See [docs/pinout.md](docs/pinout.md) for the full pin map.

Both lanes use `A5 5A LEN TYPE SEQ STATUS DATA CRC` packets. The 32-byte
`IocFrame` is only the command-side compatibility mailbox. Active commands are:

- `CMD_PING`: return `RSP_PING` with the sequence, status, length, and payload
  echoed.
- `CMD_RESET`: assert `RESET` / `RESET_HIGH`, then reset the PIC.

The transport maps command mailboxes to variable-length CRC-protected packets.

## Two-Lane Transport

The two SIO1 channels are one transport with two lanes: SIO1/B carries commands
and SIO1/A carries large DATA. Both use the same packet framing and persistent
External Sync discipline.
Commands that move more than a mailbox-worth of data use an explicit
READY -> BULK -> DONE lifecycle:

```text
CMD_SD_READ_BULK(LBA) -> READY(id, dir, 512) -> one 512-DATA packet on SIO1/A
                      -> CMD_XFER_STATUS -> DONE(id, status)
```

The card is read into MCU SRAM before READY is sent, so SD latency sits outside
the bulk transaction. See
[docs/external_sync_protocol.md](docs/external_sync_protocol.md) for the wire
formats, the state machine and the bulk-lane timing.

## SD Card

`CMD_SD_READ` (03h) reads block 0 over SPI1 on the port C bus, select
`/IO_SD_CS` on RA2, and returns its first 16 bytes in the reply payload. The
card initialises lazily on the first read. Failures come back as status codes
10h-14h rather than a transport error, so the host can tell which stage gave up.
Block reads verify the card's CRC-16 and retry on failure. Several timing and
retry settings are deliberately conservative while the SD path is still
marginal; see the **BELT AND SUSPENDERS** block at the top of
[include/sd_card.h](include/sd_card.h) for what each one costs and the order in
which to relax them.

`ioc_sd_read.asm` in the HelloWorld project exercises it; `ioc_sdblk.asm`
exercises the full-sector bulk path and `ioc_bulk.asm` tests the bulk lane on
its own with a ramp.

## USB HID Bring-Up

TinyUSB 0.20.0 supplies the MAX3421E host, hub and HID class code.  The IOC's
adapter is isolated in `src/ioc_hid.c`; it shares SPI1 only through the central
one-hot selector, so selecting the MAX3421E always releases the SD card and
controller latch first.

The MAX3421E, FE1.1 hub and one boot keyboard now enumerate in the foreground
TinyUSB task.  `CMD_HID_STATUS` exposes controller, enumeration and live-report
diagnostics to `HIDSTAT.COM`.  Boot-keyboard press transitions are translated
inside the HID module to ASCII/control bytes and VT100 key sequences, then held
in a 128-byte queue.  The nonblocking `CMD_HID_INPUT` dequeues up to 24 bytes;
`HIDKEY.COM` exercises that path directly without changing BIOS `CONST` or
`CONIN`.  See the bring-up log for the command layout and current limitations.

**Nothing can be read from the MAX3421E until `PINCTL.FDUPSPI` is set.**  The
part powers up in half-duplex SPI, where it tri-states MISO and drives read data
back out of its own MOSI pin — which this board cannot receive, because MOSI
reaches it through a one-way CD74HC4050.  The first access must therefore be a
blind PINCTL *write*; writes work in both modes.  `RES` is strapped high, so
that setting survives every PIC reset and only a 3V3 power cycle undoes it.
See [docs/max3421-bring-up-debug.md](docs/max3421-bring-up-debug.md) for the
full root-cause trail, what has been ruled out, and the bisection guide.

## Controller Latch Bring-Up

The cascaded 74HC595 pair on the port C bus (SPI1) is driven by
`controller_latch.c`. In a normal build the outputs are parked at zero by
`controller_latch_init()` and nothing writes them afterwards:
`CONTROLLER_LATCH_COUNTER_TEST` defaults to **0**, which compiles
`controller_latch_tick()` down to an empty call.

Build with `CONTROLLER_LATCH_COUNTER_TEST=1` to get the bring-up behaviour --
an incrementing pair `(n, n+1)` written to the two latches every 500 ms. This
section previously described that pattern as if it always ran, which it has not
since the flag was added. See [docs/pinout.md](docs/pinout.md) for the timer and
SPI1 settings.

See [docs/external_sync_protocol.md](docs/external_sync_protocol.md) for the
wire-level walkthrough, timing notes, and Z80 SIO references.
