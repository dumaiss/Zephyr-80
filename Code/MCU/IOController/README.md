# IO Controller Firmware

Firmware project for the Zephyr-80 IO Controller MCU.

The default target is `PIC18F57Q84`, matching the IO Controller hardware notes
and schematics.

## Layout

```text
IOController/
  Makefile
  include/
  src/
  tests/
  docs/
  build/
```

## Toolchain

Expected firmware compiler:

- Microchip XC8 command-line compiler, defaulting to
  `/opt/microchip/xc8/v3.10/bin/xc8-cc`
- PIC device support files, defaulting to `/home/kitamura/Downloads/xc8`

There is currently no host-testable policy code; `make test` reports that
status.

## Build Firmware

```sh
make
```

The build emits firmware output into `build/`. Override the PIC target if
needed:

```sh
make DEVICE=PIC18F47Q84
```

Override the compiler or device-support paths if they move:

```sh
make XC8=/path/to/xc8-cc DFP=/path/to/device/support
```

## Run Tests

```sh
make test
```

## Clean

```sh
make clean
```

## Current Behavior

At MCU boot the firmware asserts the host reset pair for 100 ms, then releases
it and idles forever:

- `RB2` / `RESET` is driven low for 100 ms, then high.
- `RB5` / `RESET_HIGH` is driven high for 100 ms, then low.
