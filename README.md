# Zephyr-80 Single-Board Computer

Retro Soul, Modern Flow -- The Zephyr-80 Way!

A compact Z80-based single-board homebrew computer designed to run CP/M and provide classic retro I/O and expansion.

## Overview

This board implements a banked-memory Z80 system with modern conveniences (SD storage, USB peripherals) while keeping vintage-compatible subsystems (TMS9928 video, SN76489 sound). It's intended for hobbyists building or experimenting with CP/M and retro software.

## Features

- **CPU**: Z80-compatible core
- **RAM**: 512KB, banked (Z80 address banking for CP/M usage and extended RAM experiments)
- **ROM**: 32KB EEPROM for bootloader/firmware
- **Storage**: SD Card support for disk images and CP/M volumes
- **USB Serial**: USB serial port for terminal access and debug console
- **USB Input**: USB keyboard plus D-Pad support for interactive input
- **Sound**: SN76489-compatible sound chip for PSG audio
- **Video**: TMS9928-based output; YPbPr analog video output supported
- **Expansion**: mini-PCIe style expansion slot for additional cards or peripherals
- **Power**: Designed to run from a regulated 5V wall power supply

## Hardware Notes

- The 512KB RAM is banked to map into the Z80 64KB address space as needed by the firmware or CP/M.
- The 32KB EEPROM contains the primary bootloader/firmware; update via the board's programming interface (refer to device-specific docs).
- Video uses a TMS9928-compatible video pipeline exposed as YPbPr analog output; a compatible monitor or converter is required.
- Sound is provided by an SN76489-compatible PSG; connect to an amplifier or powered speakers for audio output.
- The mini-PCIe expansion slot exposes power, bus, and selected signals for optional modules; treat it as an extension header for retro or modern expansion boards.

## Getting Started

1. Prepare an SD card with a CP/M image or disk set compatible with the board.
2. Insert the SD card into the board's slot.
3. Connect YPbPr video to a compatible display, or use the USB serial console and a USB keyboard.
4. Attach a regulated 5V wall power supply (check current rating in hardware docs before powering).
5. Power on the board — the bootloader in EEPROM should initialize and boot from the SD card if present.

Notes:
- Use a terminal program (e.g., `screen`, `minicom`, or a serial terminal application) to connect to the USB serial console if you prefer working without the video output.
- If flashing firmware to the EEPROM or updating boot code, follow the project's programming instructions or tooling.

## Power

The board is designed to operate from a single regulated 5V DC wall supply. Verify the supply can deliver sufficient current for attached peripherals (SD, USB devices, any expansion cards). Avoid using unregulated or higher-voltage supplies.

## Files

See the project Licence: [Licence.md](Licence.md)

## Contributing

Contributions, improvements, and bug reports are welcome. Open issues or pull requests with hardware notes, firmware updates, or SD images that improve the CP/M experience.

---

If you want, I can add wiring diagrams, pinouts, a sample CP/M SD image guide, or a small troubleshooting section next.
