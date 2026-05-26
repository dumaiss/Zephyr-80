# PMU Firmware

Power management unit firmware for the Zephyr-80 system.

The project is intentionally self-contained so additional MCU firmware projects
can be added beside it under `Code/MCU/`.

## Layout

```text
PMU/
  Makefile          AVR-GCC build and flash targets
  include/          Project headers and configuration
  src/              Firmware source
  docs/             Device-specific notes, pinout, and programming details
  build/            Generated objects and firmware images
```

## Toolchain

Expected tools:

- `avr-gcc`
- `avr-objcopy`
- `avr-size`
- `avrdude`

On Debian/Ubuntu systems these are usually provided by:

```sh
sudo apt install gcc-avr avr-libc avrdude
```

## Build

```sh
make
```

Generated files are written to `build/`.

## Test

The power-control policy is implemented as a host-testable state machine.

```sh
make test
```

The tests compile with the host C compiler and do not require the AVR toolchain.

## Flash

Update `PROGRAMMER`, `PORT`, and fuse values in `Makefile` before programming a
real device.

```sh
make flash
```

Fuse programming is separated from firmware flashing:

```sh
make fuses
```

## Power-Control Signals

| Signal | Port | Direction | Active State |
| --- | --- | --- | --- |
| `PWR_OFF_RQ` | PB4 | Input | Low |
| `PWR_STATE` | PB3 | Output | High holds reset, low allows run |
| `PWR_SW` | PB2 | Input | Low |
| `PWR_OK` | PB1 | Input | High |
| `PS_ON` | PB0 | Output | High at PB0, low at ATX `PS_ON#` |

See `docs/pinout.md` for the full pinout and signal behavior.

## IO Controller Bypass

Set `PMU_IGNORE_IO_CONTROLLER_SIGNALS` to `1` in `include/config.h`, or pass it
as a compiler define, to build the PMU without the IO Controller handshake. In
that mode the PMU ignores `PWR_OFF_RQ` and leaves `PWR_STATE` as a high
impedance input instead of driving reset/run state toward the IO Controller.
The 5 second force-off button hold remains available when the handshake is
disabled.

## Power-Off Handshake

When the system is already powered and the enclosure power switch is pressed,
the PMU sets `PWR_STATE` high. This tells the IO Controller to hold the
system in reset and finish its shutdown work. The PMU keeps the PSU enabled
until the IO Controller asserts `PWR_OFF_RQ` low. At that point PB0 is turned
off, disabling the `PS_ON#` MOSFET and allowing the ATX supply to shut down.

If the enclosure power switch is held for 5 seconds while the system is powered,
the PMU turns PB0 off directly and shuts the PSU down without waiting for the IO
Controller.

## Power-On Sequence

When the enclosure power switch is pressed while the system is off, the PMU
turns PB0 on immediately, pulling ATX `PS_ON#` low to start the PSU.
`PWR_STATE` remains high during this startup window so the IO Controller holds
the system in reset. When `PWR_OK` is asserted, the PMU sets `PWR_STATE` low to
allow the IO Controller to run.
