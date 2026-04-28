# IO Controller Firmware

Template firmware project for the Zephyr-80 IO Controller MCU.

The default target is `PIC18F57Q84`, matching the IO Controller hardware notes
and schematics. The project is structured so hardware-independent policy code
can be tested with the host compiler while the firmware target builds with
Microchip XC8.

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

- Microchip XC8 command-line compiler, `xc8-cc`

Host tests use `gcc` by default and do not require XC8.

## Build Firmware

```sh
make
```

The build emits firmware output into `build/`. Override the PIC target if
needed:

```sh
make DEVICE=PIC18F47Q84
```

## Run Tests

```sh
make test
```

## Clean

```sh
make clean
```

## Current Template Behavior

The template focuses on the PMU shutdown handshake:

- `PWR_STATE` high from the PMU means the IO Controller should hold the system in
  reset and finish shutdown work.
- The IO Controller waits until local work is idle.
- Once idle, it asserts `PWR_OFF_RQ` so the PMU can remove ATX power.
- If `PWR_STATE` returns low, the shutdown request is cleared.

Pin mapping is intentionally left in `src/main.c` as TODOs until final board pin
assignments are confirmed.
