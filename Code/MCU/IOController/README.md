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
select:  PIC RA4 /SIOB_CS puts SIO1/B on the shared bus
request: Z80 SIO1/B TXDB -> PIC RB2 SIO_MISO, clocked by PIC RB3 SIO_SCK
reply:   PIC RB1 SIO_MOSI -> Z80 SIO1/B RXDB, clocked by PIC RB3 SIO_SCK
sync:    PIC RA7 drives SIO1/B /SYNCB
```

See [docs/pinout.md](docs/pinout.md) for the full pin map.

Frames are fixed 32-byte `IocFrame` mailboxes. The active commands are:

- `CMD_PING`: return `RSP_PING` with the sequence, status, length, and payload
  echoed.  As a bring-up diagnostic, the first two payload bytes are then
  shifted into the cascaded controller 74HC595s and latched by releasing
  `/CTRL_LAT_CS` on RA1.
- `CMD_RESET`: assert `RESET` / `RESET_HIGH`, then reset the PIC.

The PIC transport clocks the raw 32-byte frame only.

See [docs/external_sync_protocol.md](docs/external_sync_protocol.md) for the
wire-level walkthrough, timing notes, and Z80 SIO references.
