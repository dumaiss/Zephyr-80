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

- `RB2` / `RESET` is driven low, then released high.
- `RB5` / `RESET_HIGH` is driven high, then released low.

After boot, the main loop polls SIO1/B `RTSB` on `RF1`. A falling edge starts
one External Sync command transaction:

```text
request: Z80 SIO1/B TXDB -> PIC RA6, clocked by PIC RA7
reply:   PIC RA5 -> Z80 SIO1/B RXDB, clocked by PIC RA7
sync:    PIC RA1 drives SIO1/B /SYNCB and the SIO->PIC buffer gate
```

Frames are fixed 32-byte `IocFrame` mailboxes. The active commands are:

- `CMD_PING`: return `RSP_PING` with the sequence, status, length, and payload
  echoed.
- `CMD_RESET`: assert `RESET` / `RESET_HIGH`, then reset the PIC.

The PIC transport clocks the raw 32-byte frame only.

See [docs/external_sync_protocol.md](docs/external_sync_protocol.md) for the
wire-level walkthrough, timing notes, and Z80 SIO references.
