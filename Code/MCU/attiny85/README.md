# ATTiny85 Firmware

Firmware project for an ATTiny85 microcontroller used in the Zephyr-80 system.

The project is intentionally self-contained so additional MCU firmware projects
can be added beside it under `Code/MCU/`.

## Layout

```text
attiny85/
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

## Power-Off Handshake

When the system is already powered and the enclosure power switch is pressed,
the ATTiny85 sets `PWR_STATE` high. This tells the IO Controller to hold the
system in reset and finish its shutdown work. The ATTiny85 keeps the PSU enabled
until the IO Controller asserts `PWR_OFF_RQ` low. At that point PB0 is turned
off, disabling the `PS_ON#` MOSFET and allowing the ATX supply to shut down.

If the enclosure power switch is held for 5 seconds while the system is powered,
the ATTiny85 turns PB0 off directly and shuts the PSU down without waiting for
the IO Controller.

## Power-On Sequence

When the enclosure power switch is pressed while the system is off, the ATTiny85
records a pending power-on request. PB0 is activated only after `PWR_OK` is
asserted. `PWR_STATE` remains high during this startup window so the IO
Controller holds the system in reset. When `PWR_OK` is asserted, the ATTiny85
sets `PWR_STATE` low to allow the IO Controller to run.
