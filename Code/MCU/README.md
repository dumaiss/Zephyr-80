# MCU Firmware

This directory contains firmware projects for microcontrollers used by the
Zephyr-80 hardware.

Each MCU target should live in its own subdirectory so device-specific source,
build settings, fuse settings, programmer configuration, and documentation stay
isolated.

## Projects

- `PMU/` - Power management unit firmware project.
- `IOController/` - PIC18F57Q84 IO Controller firmware project.

## Suggested Layout

```text
MCU/
  <mcu-target>/
    README.md
    Makefile
    include/
    src/
    docs/
    build/
```

Keep shared protocol notes or board-level interface documentation in this
directory only when they apply to more than one MCU target.
