# Zephyr80Lib

`Zephyr80Lib` is the reusable Turbo Modula-2 library for Zephyr-80 programs.
It provides the public `Sound`, `Timer`, and `Player` modules in one
`ZEPHYR80.LIB` archive. The current implementation targets the four
SN76489-compatible PSGs on Afternoon Blend and the Zephyr BIOS-managed CTC0
interrupt service.

The project is independent of the TM2 SNTracker application. SNTracker has not
yet been changed to consume this archive, so its existing source copies remain
in place until that separate migration is requested.

All CP/M-visible source and output filenames are 8.3-compatible.

## Public modules

- `Sound` controls 16 logical channels across the four PSGs.
- `Timer` exposes logical ticks from 1 through 180 Hz. CTC0 and the assembly
  callback bridge remain private implementation details.
- `Player` loads a ZTR file and advances complete singleton music playback one
  application-supplied tick at a time.

`CTCLow`, `ZTR`, and `PlyCore` are archive implementation modules, not public
application APIs. See `DOC/API.MD` for the complete public contract and an
embedding example.

## PC build

The repository contains the verified RunCPM executable, ZCPR3 CCP image, Turbo
Modula-2 distribution, ZMAC, and the hosted build driver needed by this
project. On the x86-64 Linux development host, only Python 3 and `make` are
required:

```text
make clean
make
```

The build uses the original CP/M compiler, assembler, REL converter,
librarian, and linker. It creates an isolated directory-backed CP/M drive,
builds `ZEPHYR80.LIB`, proves that consumers can compile with the loose library
modules removed, links the test programs, and runs the hardware-independent
regressions.

Generated files are written to `BUILD`:

```text
ZEPHYR80.LIB   distributable TM2 library
LIBTEST.COM    public-interface and archive smoke test
TIMTEST.COM    physical CTC/timer test
SNDTEST.COM    physical four-PSG test
ZTRTEST.COM    hosted ZTR loader regression
PLYTEST.COM    hosted complete-song player regression
```

The default song inputs are the Night Market and Runaway Circuit ZTR files in
the sibling `SNTracker/songs` directory. Their paths and every tool path can be
overridden through Make variables; run `make help` for the common commands.

## Installing in Turbo Modula-2

Copy `ZEPHYR80.LIB` to the TM2 work disk. In the TM2 Options menu, choose
`Path to search` and append `ZEPHYR80` to the default, leaving this path:

```text
SYSLIB ZEPHYR80
```

TM2 can then resolve the public `.SYM` interfaces and implementation `.MCD`
members directly from the archive.

The integrated linker can run out of memory for an application that embeds the
complete `Player`. In that case, use the TM2 Librarian to copy the required
`.MCD` members from `ZEPHYR80.LIB` to the work disk:

```text
PLAYER.MCD  ZTR.MCD  PLYCORE.MCD
SOUND.MCD
```

Add `TIMER.MCD` and `CTCLOW.MCD` only when the application chooses `Timer` as
its clock. Then link with a standalone `TLINK.COM`. This is also the procedure
automated by the PC build after it proves archive-based compilation.

## Runtime ownership

`Timer` exclusively owns CTC0 while active. It follows the current Zephyr
interrupt contract: the callback and its state occupy the application-owned
top of the `E000h-E3FFh` reservation, registration uses Zephyr BDOS function 200, and
unregistration uses function 201. It does not install an IM2 table or change
`I`.

Turbo Modula-2 initializes `SP` from CP/M page-zero address `0006h`, which is
`EC06h` on the current Zephyr OS. `CTCLow` places its 55-byte callback at
`E3C0h-E3F6h` and seven state bytes at `E3F8h-E3FEh`. This keeps the callback
above the linked tracker's data/heap tail and leaves about 2 KiB above it for
TM2's descending runtime stack. Applications using `Timer` must likewise keep
their static data and heap below `E3C0h` and ensure their maximum stack depth
does not descend into the callback.

`Player` never configures or owns a timer. A successful `Player.Load` exposes
the song's authored rate through `Player.TickRate`; the application advances
music by calling `Player.Tick` exactly once per supplied music tick. The source
can be `Timer.TakeTick`, a foreground VBlank event, or a game clock.

Looping is an explicit player policy. `SetLooping(TRUE)` restarts the retained
ZTR at each natural end without disk I/O, while `Finished`/`TakeFinished`
publish completion at every pass. With looping disabled, ticks after completion
are harmless; looping can be enabled later to restart on the next tick.

`Player` exclusively owns all four PSGs from a successful `Load` until `Stop`
or natural completion. Applications must not call `Sound` directly during that
interval. `Timer` remains independent and under application control.

## Hardware acceptance

The hosted build checks parsing, archive resolution, linking, and full traversal
of both regression songs. Run these checks on a Zephyr before treating a build
as hardware-qualified:

1. `TIMTEST.COM` reaches 600 ticks in about ten seconds, reports zero queue
   overflows, and returns with console interrupts working.
2. Repeated timer start/stop cycles do not disturb BIOS interrupt handling.
3. `SNDTEST.COM` addresses tone and noise voices on all four PSGs and mutes on
   exit.
4. A small game loop calling `Player.Tick` from its foreground VBlank or timer
   event plays a ZTR at the expected pitch and tempo and stops cleanly.
