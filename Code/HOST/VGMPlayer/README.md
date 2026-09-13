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

Press any key to stop playback. On every playback exit path the player stops
CTC channel 0, unregisters its callback, and silences PSG0. PSG1-PSG3 are
unchanged.

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

The compact ZVGC v2 stream begins with a 16-byte header and uses these commands.
The player also accepts existing v1 streams and their `01h ddh` writes.

| Byte | Meaning |
| ---: | --- |
| `00h` | End playback. |
| `01h ddh` | Write byte `ddh` to PSG0. |
| `02h lo hi` | Wait 1-65535 ticks. |
| `40h-7Fh` | Wait 1-64 ticks. |
| `80h-8Fh data...` | Write 1-16 ordered PSG0 bytes; low nibble plus one is the data length. |

## Runtime design and memory use

CTC channel 0 is configured for approximately 180.01 interrupts per second
from the 10 MHz CTC clock. A phase accumulator derives the ZVGC header's
requested rate; 60 Hz retains an exact divide-by-three schedule. The CTC ISR
decodes complete compact commands from a common-RAM ring and writes PSG0.
Foreground code produces that ring from the file buffers and performs all
keyboard polling and CP/M disk access; the ISR never calls BDOS.

Two alternating 6144-byte buffers occupy `8000h-AFFFh`. Both are filled before
playback starts. During playback the inactive buffer is refilled one 128-byte
CP/M record per foreground pass. ZVGC v2 write runs reduce `song.zvg`'s storage
bandwidth so the foreground refill can stay ahead of playback.

The BIOS owns IM2 and its vector page. VGMPlayer copies its CTC callback to
`E000h`, keeps the callback's state at `E120h-E136h`, and uses
`E140h-E3FFh` as a 704-byte producer/consumer ring. These all fit in the
architecture's program-owned 1 KiB common reservation, so the callback remains
valid while the banked OS is active. It is registered as CTC channel 0 through
Zephyr BDOS function 200 and removed with function 201; the program never
changes `I`, builds an IM2 table, or writes a CTC vector byte.

The transient and both file buffers remain ordinary application-bank memory.
The private stack is at `BFF0h`; the BIOS dispatcher supplies its own common
interrupt stack while the callback runs.

During a sequential disk read, the interrupt callback takes a roughly
60-T-state fast path that only queues raw CTC expirations. Foreground code
replays those expirations through the phase scheduler and common decoder
immediately after each 128-byte read. This keeps both phase bookkeeping and PSG
bursts out of the timing-sensitive storage transaction without pausing the song
for an entire 6144-byte refill.

## Project layout

- `src/vgmplay.asm`: CP/M player.
- `tools/compile_vgm.py`: VGM/VGZ to ZVGC compiler.
- `tools/ihx_to_com.py`: Intel HEX to CP/M COM converter used by the build.
