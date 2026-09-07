# VGMPlayer

VGMPlayer is a CP/M transient program for the Zephyr-80. It streams compiled
SN76489 music from disk to Afternoon Blend PSG0 at I/O port `E0h`.

## Build

The project requires the SDCC ASxxxx Z80 assembler and linker:

```sh
make
```

This produces `build/VGMPLAY.COM`. Copy that file to a CP/M disk image or SD
volume using the normal image tooling.

## Play a file

At the CP/M prompt, pass a compiled `.ZVG` file. For example, for a file on the
SD-backed B drive:

```text
VGMPLAY B:MUSIC.ZVG
```

Press any key to stop playback. On every exit path the player stops CTC channel
0, restores the original IM2 page, and silences PSG0. PSG1-PSG3 are unchanged.

## Compile VGM or VGZ input

Run the host-side compiler from this project directory:

```sh
python3 tools/compile_vgm.py music.vgm music.zvg
python3 tools/compile_vgm.py music.vgz music.zvg --loops 3
```

The compiler extracts PSG0 `50h` writes, combines intervening waits, and
quantizes the VGM 44.1 kHz timestamps to the playback rate declared in the VGM
header. A zero rate defaults to 60 Hz. Supported rates are 1-180 Hz. `--loops`
expands the VGM loop section a finite number of times.

The compact ZVGC v1 stream begins with a 16-byte header and uses these commands:

| Byte | Meaning |
| ---: | --- |
| `00h` | End playback. |
| `01h ddh` | Write byte `ddh` to PSG0. |
| `02h lo hi` | Wait 1-65535 ticks. |
| `40h-7Fh` | Wait 1-64 ticks. |

## Runtime design and memory use

CTC channel 0 is configured for approximately 180.01 interrupts per second
from the 10 MHz CTC clock. A phase accumulator derives the ZVGC header's
requested rate; 60 Hz retains an exact divide-by-three schedule. The ISR only
publishes pending ticks. Stream decoding, PSG writes, keyboard polling, and all
CP/M disk access remain in the foreground.

Two alternating 6144-byte buffers occupy `8000h-AFFFh`. Both are filled before
playback starts. During playback the inactive buffer is refilled one 128-byte
CP/M record per foreground pass, allowing pending music ticks to be serviced
between SD transfers and allowing files larger than the Z80 address space.

The transient starts at `0100h`, installs a private IM2 page at `7F00h`, mirrors
the BIOS SIO vector from `DD10h` to `7F10h`, and uses a private stack at `BFF0h`.
These addresses are platform-specific and must remain clear while the program
runs.

## Project layout

- `src/vgmplay.asm`: CP/M player.
- `tools/compile_vgm.py`: VGM/VGZ to ZVGC compiler.
- `tools/ihx_to_com.py`: Intel HEX to CP/M COM converter used by the build.
