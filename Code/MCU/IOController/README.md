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

Bulk data CRC calculation and verification are bypassed by default with
`IOC_BULK_CRC_BYPASS=1` in `include/config.h`, matching the current Z80 bypass.
This applies to both directions of the SIO1/A bulk lane: IOC sends a two-byte
zero CRC trailer and ignores the received CRC. Packet framing and metadata
checks remain active; command-lane CRC and SD-card SPI CRC are unchanged.
The Z80 must keep its bulk receive CRC bypass enabled with this setting.

To restore IOC bulk CRC generation and verification:

```sh
make DEFS=-DIOC_BULK_CRC_BYPASS=0
```

Use `make` (or `make DEFS=-DIOC_BULK_CRC_BYPASS=1`) to return to bypass mode.
Restoring end-to-end verification also requires disabling the Z80's separate
`IOC_BULK_CRC_BYPASS` setting.

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

The MAX3421E and FE1.1 hub now support up to two HID interfaces in the
foreground TinyUSB task.  One boot keyboard may be used alongside a Logitech
F310 in DirectInput mode (USB `046d:c216`), or two F310s may feed the two
Coleco controller bytes.  F310 interrupt-IN requests are paced at 10 ms in the
application because TinyUSB's MAX3421E scheduler does not yet enforce endpoint
`bInterval`.  Passive `CMD_HID_STATUS` page 6 reads TinyUSB's live non-hub
device table and exposes USB/F310 enumeration, report-arm, report-count and
decoded-latch state to `PADSTAT.COM` in a normal build.  Boot-keyboard press transitions are translated
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

The cascaded 74AHC595 pair on the port C bus (SPI1) is driven by
`controller_latch.c`. Both controller bytes start at the standard Coleco idle
value `7Fh`.  Each changed F310 report is decoded to the active-low Coleco data
bus and committed at SPI1's 32 MHz maximum.  Mount order assigns controller 1
and then controller 2; unplugging a pad restores that byte to `7Fh`.

**D7 is low.**  It was high until Montezuma's Revenge exposed it.  The BIOS
complements every controller read, so a game sees `~latch`; Monte merges the
two mode bytes and tests the result with `AND 0C0h` / `CP 0C0h` at `90FFh`.
With D7 high that compare can never match and the jump button is dead.  The
BIOS itself only reads D3:D0 and D6, and no other title in the test set looks
at D7 of a controller byte, so `CONTROLLER_LATCH_IDLE` is the single point to
revert should one turn up.

The F310 mapping is d-pad (or left stick while the Mode LED is on) to Coleco
directions, A/B to fire, X/Y to the existing keypad 1/2 selections, and
Back/Start to the Coleco `*`/`#` codes used by game-over/restart paths. The board
does not capture the Coleco keypad/joystick mode-select writes, so these keypad
substitutes temporarily override the direction nibble while held. The raw latch
codes are `0Dh` for key 1, `07h` for key 2, `09h` for `*`, and `06h` for `#`;
with the idle upper nibble these appear at the controller port as `7Dh`, `77h`,
`79h`, and `76h` respectively.

### USB keyboard keypad

The four gamepad substitutes cover only `1`, `2`, `*` and `#`. Titles that need
the rest of the keypad -- the music cartridge, and games whose title screen
waits on a digit the pad cannot produce -- are served from an attached USB
keyboard instead, which is otherwise idle once ColecoGo has taken the machine
over.

The number row and the numeric keypad both give `0`-`9`. `Shift+8` and
`Shift+3` give `*` and `#`, which is just typing the character; keypad `*` is an
alias for `*`. The mapping drives controller port 0 and does **not** consume the
keystroke, so digits still reach the CP/M console while CP/M is running.

A keypad code held from the keyboard overrides the direction nibble of every
gamepad report until it is released, matching the existing substitute
behaviour: a real controller cannot report a keypad key and a direction at the
same time. Releasing parks the nibble idle, and an attached pad restores real
directions on its next report.

The nibbles come from the BIOS decode table at `10F5h`, which is indexed by the
complement of the port read, so the latch value is `~index`:

| Key | Latch | Key | Latch | Key | Latch |
| --- | --- | --- | --- | --- | --- |
| 0 | `0Ah` | 4 | `02h` | 8 | `01h` |
| 1 | `0Dh` | 5 | `03h` | 9 | `0Bh` |
| 2 | `07h` | 6 | `0Eh` | `*` | `09h` |
| 3 | `0Ch` | 7 | `05h` | `#` | `06h` |

`make test` runs `tools/test_coleco_keypad.py`, which extracts the mapping
function from `src/ioc_hid.c`, compiles it for the host, and checks all twelve
keys plus the negative cases against that BIOS table rather than against a
transcribed copy of it.  It also replays the whole latch byte through the
BIOS complement, so a regression in D7 or the fire line fails the test rather
than reaching hardware.

`CONTROLLER_LATCH_COUNTER_TEST` still defaults to **0**, which compiles
`controller_latch_tick()` down to an empty call.

Build with `CONTROLLER_LATCH_COUNTER_TEST=1` to get the bring-up behaviour --
an incrementing pair `(n, n+1)` written to the two latches every 500 ms. This
section previously described that pattern as if it always ran, which it has not
since the flag was added. See [docs/pinout.md](docs/pinout.md) for the timer and
SPI1 settings.

See [docs/external_sync_protocol.md](docs/external_sync_protocol.md) for the
wire-level walkthrough, timing notes, and Z80 SIO references.
