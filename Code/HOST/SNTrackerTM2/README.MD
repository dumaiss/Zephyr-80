# SNTracker TM2

This directory contains the native Turbo Modula-2 port of SNTracker.  It is an
ordinary CP/M transient program and does not require BIOS changes.  The
assembly implementation in `../SNTracker` remains the behavioral reference.

Every source filename is CP/M 8.3-compatible in the repository.  Copying or
editing sources on the Zephyr therefore requires no filename mapping.

## Modules

```text
SRC/SNTRACK.MOD   command line, UI, clock wiring and rate-limited key polling
```

All playback, ZTR loading, sound and timer implementation comes from the
sibling `../Zephyr80Lib` project. This directory intentionally keeps no copies
of those modules.

## Building on the PC

The complete build runs the original CP/M tools under RunCPM, avoiding the
physical Zephyr's smaller TPA.  From this directory run:

```text
make
```

The Makefile first rebuilds `../Zephyr80Lib/BUILD/ZEPHYR80.LIB`. It then creates
an isolated temporary CP/M drive, stages the library and uppercase CRLF copies
of the standalone tracker source, and:

1. selects `SYSLIB ZEPHYR80` as the TM2 archive search path;
2. compiles `SNTRACK.MOD` against the public library definitions;
3. extracts the required implementation members from `ZEPHYR80.LIB`;
4. builds `TLINK.COM` and links outside the IDE;
5. checks the usage and missing-file command paths; and
6. publishes only `BUILD/SNTRACK.COM`.

The default uses the toolchain embedded in `../Zephyr80Lib/TOOLS`. All inputs
can be overridden, for example on a different host:

```text
make RUNCPM=/opt/runcpm/RunCPM
```

See `TOOLS/README.MD` and `make help` for the complete list.

## Building on the Zephyr

Place `SNTRACK.MOD`, `ZEPHYR80.LIB`, Turbo Modula-2 system files and
the desired ZTR songs on a CP/M work drive. In the TM2 Options menu enable
Native and Extensions. Native is an IDE option and cannot be enabled from
source.

Choose `Path to search` and append `ZEPHYR80` to the default path:

```text
SYSLIB ZEPHYR80
```

Compile the application modules in this order:

```text
SNTRACK.MOD
```

The integrated linker may run out of memory on the complete program. Use the
TM2 Librarian to copy these members from `ZEPHYR80.LIB` to the work disk:

```text
PLAYER.MCD  ZTR.MCD  PLYCORE.MCD
SOUND.MCD   TIMER.MCD  CTCLOW.MCD
```

Build a standalone linker from the TM2 Link menu with `LINK` as the main
module and `TLINK.COM` as output. Run it with `SNTRACK` as the main module,
`SNTRACK.COM` as output, and include all needed modules.

The PC Makefile is the reproducible full build when either operation exceeds
the Zephyr's TPA. The resulting COM file can then be copied to the SD card for
hardware acceptance.

## RunCPM during the port

RunCPM is useful for native compilation, linking and hardware-independent
tests. Its directory-backed drives are case-sensitive on Linux, so stage CP/M
filenames in uppercase. The TM2 compiler also requires CP/M CRLF text when used
in that environment.

RunCPM validates archive resolution, compilation, linking, usage handling and
the missing-file path. The library's own build validates ZTR loading and
complete-song traversal. Neither can validate live CTC interrupts or Afternoon
Blend writes; those checks require the physical Zephyr.

## Runtime ownership

`SNTRACK.MOD` owns the standalone clock policy. After `Player.Load`, it starts
`Timer` at `Player.TickRate` and passes every consumed timer event to exactly
one `Player.Tick` call. `Player` itself never owns CTC0.

The library's private `CTCLow` bridge follows the current BIOS-owned IM2
contract. It registers CTC0 through Zephyr BDOS function 200, keeps its callback
at `E3C0h-E3F6h` and state at `E3F8h-E3FEh`, and resets and
unregisters through function 201.

TM2 retains its stock `LD SP,(0006h)` startup, giving the tracker a stack at
`EC06h`. The callback's high placement avoids the tracker's data/heap tail and
leaves about 2 KiB for the descending player stack before the callback area.

The callback only publishes pending ticks in the program-owned common
reservation and returns with `RET`; the BIOS dispatcher supplies the common
interrupt stack, register preservation, `EI`, and `RETI`. Callers must still
treat CTC0 as an exclusive application resource.

The pending counter saturates at 255.  `QueueOverflows` counts ticks rejected
at that boundary.  It cannot detect hardware expirations lost while interrupts
were disabled.

`Player` owns all four Afternoon Blend PSGs during playback and mutes them on
normal completion or user stop. The PSGs are write-only, so prior state cannot
be restored.

Console polling occurs once per logical second and only in foreground code.
The ISR performs no BDOS, parsing, rendering, or PSG work.

## Hardware acceptance

Before replacing the assembly executable in normal use, verify on Zephyr:

1. Night Market and Runaway Circuit play at the expected pitch and tempo.
2. The status line advances once per order and queue overflows remain zero.
3. Natural completion and Q/Escape both stop CTC0 and mute every PSG.
4. Repeated runs return to CP/M with BIOS console interrupts still working.
