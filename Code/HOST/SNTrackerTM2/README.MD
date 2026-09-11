# SNTracker TM2

This directory contains the native Turbo Modula-2 port of SNTracker.  It is an
ordinary CP/M transient program and does not require BIOS changes.  The
assembly implementation in `../SNTracker` remains the behavioral reference.

Every source filename is CP/M 8.3-compatible in the repository.  Copying or
editing sources on the Zephyr therefore requires no filename mapping.

## Modules

```text
SRC/SNTRACK.MOD   application and rate-limited key polling
SRC/ZTR.DEF       bounded ZTR v1 reader interface
SRC/ZTR.MOD       binary loading and structural validation
SRC/PLAYER.DEF    tracker playback interface
SRC/PLAYER.MOD    typed channel state, sequencing, effects and rendering
SRC/SOUND.DEF     logical 16-channel sound interface
SRC/SOUND.MOD     Afternoon Blend/SN76489 implementation
SRC/TIMER.DEF     pending-tick timer interface
SRC/TIMER.MOD     timer ownership and TM2-facing state
SRC/CTCLOW.DEF    private foreign-module definition
SRC/CTCLOW.Z80    CTC0, private IM2 table and minimal ISR
SRC/TRKUI.DEF     compact status interface
SRC/TRKUI.MOD     order-boundary CP/M console updates
```

`PLAYER.MOD` implements the current ZTR v1 behavior, including typed channel
state, instrument sequences, release points, legacy Furnace effects,
envelope-preserving legato, persistent notation arpeggios, hairpins and
notation reset events.

## Building on the PC

The complete build runs the original CP/M tools under RunCPM, avoiding the
physical Zephyr's smaller TPA.  From this directory run:

```text
make
```

The Makefile creates an isolated temporary CP/M drive, stages uppercase CRLF
copies of all sources, and then:

1. assembles `CTCLOW.Z80` with ZMAC;
2. compiles all definition modules;
3. runs the TM2 REL converter in a fresh IDE session;
4. compiles all implementation and main modules;
5. builds `TLINK.COM` and links outside the IDE;
6. runs the ZTR and complete-song regression tests; and
7. publishes five executables in `BUILD`.

The default uses the verified x86-64 Linux `TOOLS/RUNCPM` executable and the
TM2 distribution already under `Code/HOST/Software`.  All inputs can be
overridden, for example on a different host:

```text
make RUNCPM=/opt/runcpm/RunCPM
```

See `TOOLS/README.MD` and `make help` for the complete list.

## Building on the Zephyr

Place the source files, Turbo Modula-2 system files, `SYSLIB.LIB`, `ZMAC.COM`
and the songs on a CP/M work drive.  In the TM2 Options menu enable Native and
Extensions.  Native is an IDE option and cannot be enabled from source.

Compile definition modules before implementations:

```text
CTCLOW.DEF
TIMER.DEF
SOUND.DEF
ZTR.DEF
PLAYER.DEF
TRKUI.DEF
```

Assemble and convert the private CTC module:

```text
ZMAC CTCLOW.Z80
```

Then use TM2's Run command:

```text
REL CTCLOW CTCLOW
```

This combines `CTCLOW.SYM` and `CTCLOW.REL` into `CTCLOW.MCD`.  REL public
symbols are limited to six characters, which is why only the private shim uses
short procedure names.

Compile the implementation and main modules:

```text
TIMER.MOD
SOUND.MOD
ZTR.MOD
PLAYER.MOD
TRKUI.MOD
SNTRACK.MOD
```

The physical Zephyr may run out of memory while compiling `PLAYER.MOD`, running
`REL CTCLOW CTCLOW`, or performing the final link.  This is tool workspace
pressure, not necessarily an oversized final program.  When memory permits,
build a standalone linker from the TM2 Link menu:

```text
main module: LINK
output file: TLINK.COM
include all needed modules: Y
```

Run `TLINK.COM`, select `SNTRACK` as the main module, `SNTRACK.COM` as the
output, and include all needed modules.  The PC build links the original
single-module player without relying on the physical Zephyr's available TPA.

The PC Makefile is the reproducible full build when either operation exceeds
the Zephyr's TPA.  The resulting COM files can then be copied to the SD card for
hardware acceptance.

## RunCPM during the port

RunCPM is useful for native compilation, linking and hardware-independent
tests.  Its directory-backed drives are case-sensitive on Linux, so stage CP/M
filenames in uppercase.  The TM2 compiler and ZMAC also require CP/M CRLF text
when used in that environment.

RunCPM can validate:

- ZTR loading and bounds checks;
- typed player state and complete song traversal;
- TM2/REL symbol resolution;
- final COM linking and command-line handling.

RunCPM does not validate Zephyr CTC interrupts or Afternoon Blend writes.  Use
the physical Zephyr for `TIMTEST.COM`, `SNDTEST.COM` and audible playback.

## Tests

```text
TEST/TIMTEST.MOD  600 logical ticks at 60 Hz
TEST/SNDTEST.MOD  tones/noise on all four PSGs
TEST/ZTRTEST.MOD  loads NIGHT.ZTR and prints its structure
TEST/PLYTEST.MOD  traverses NIGHT.ZTR and RUNAWAY.ZTR without a timer
```

The RunCPM player traversal currently completes with:

```text
NIGHT.ZTR    11518 ticks, 3:11, 34496 PSG writes
RUNAWAY.ZTR  13056 ticks, 3:30, 43363 PSG writes
```

Runaway Circuit uses 62 Hz, explaining the relationship between its tick count
and elapsed time.

## Runtime ownership

While active, `Timer` exclusively owns CTC0 and a dynamically aligned private
IM2 page allocated in its TM2 data.  It copies the active BIOS SIO handler into
the private page, changes I only while active, and restores the previous I
value on stop.  CTC registers are write-only, so a prior CTC0 configuration
cannot be restored; callers must treat CTC0 as an exclusive application
resource.

The pending counter saturates at 255.  `QueueOverflows` counts ticks rejected
at that boundary.  It cannot detect hardware expirations lost while interrupts
were disabled.

`Sound` exclusively owns all four Afternoon Blend PSGs while the application
runs.  It mutes them on initialization, normal stop and shutdown.  The PSGs are
write-only, so their prior state cannot be restored.

Console polling occurs once per logical second and only in foreground code.
The ISR performs no BDOS, parsing, rendering, or PSG work.

## Hardware acceptance

Before replacing the assembly executable in normal use, verify on Zephyr:

1. `TIMTEST.COM` reaches 600 ticks in approximately ten seconds and returns to
   CP/M with the console still working.
2. Repeated timer start/stop leaves BIOS SIO input operational.
3. `SNDTEST.COM` addresses all four PSGs and mutes cleanly.
4. Night Market and Runaway Circuit play at the expected pitch and tempo.
5. The status line advances once per order and queue overflows remain zero.
6. Natural completion and Q/Escape both stop CTC0 and mute every PSG.
