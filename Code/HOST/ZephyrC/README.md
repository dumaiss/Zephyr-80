# ZephyrC

The C library for Zephyr-80 programs, cross-compiled on a PC. It gives C
programs the machine's serial ports, V9958, sound card, CTC timers, banked
memory, input devices and operating system services, under the same ownership
rules the BIOS and the assembly and Turbo Modula-2 programs already follow.

`DOC/API.md` is the contract: what each call does, what the hardware demands,
and what is still missing. This file is how to build and run it.

It is the C counterpart of `../Zephyr80Lib` (Turbo Modula-2). Where both cover
the same hardware they describe it the same way.

## Building

```sh
make            # library, example and tests
make lib        # build/zephyr.lib
make examples   # build/MANDEL.COM
make tests      # build/TICKTEST.COM, build/SERTEST.COM
```

Needs z88dk (`zcc`, `z88dk-z80asm`), the SDCC assembler and linker
(`sdasz80`, `sdldz80`) for the common-memory stubs, and Python 3.

z88dk is a snap on this host and cannot read `/tmp`, so build inside the home
tree.

## Using it in a program

```c
#include <zephyr/vdp.h>
#include <zephyr/input.h>

int main(void)
{
    if (zep_vdp_acquire() != ZEP_OK)
        return 1;
    zep_vdp_mode(ZEP_VDP_G6, ZEP_VDP_LINES_212 | ZEP_VDP_INTERLACE);
    /* ... draw ... */
    while (zep_kbd_getc() < 0)
        ;
    zep_vdp_release();
    return 0;
}
```

```sh
zcc +cpm -compiler=sdcc -O2 -I$(ZEPHYRC)/include prog.c \
    -L$(ZEPHYRC)/build -lzephyr -o PROG.COM
```

The classic C library gives you `<stdio.h>` with CP/M file I/O, `malloc` and
`<cpm.h>`; ZephyrC adds the machine. Modules that take hardware give it back
at exit on their own, whichever way the program ends.

A program ends in a warm boot, which clears the screen, so ZephyrC waits for a
key first and prints `[any key]`. Call `zep_exit_pause(0)` if a program must not
block on the way out.

## What is in the box

| Header | Covers |
|---|---|
| `zephyr/bdos.h` | `zep_sysinfo`, the BDOS 210-217 register block, IOCALL and bulk transfers, the ZSDOS clock and file stamps |
| `zephyr/serial.h` | SIO0/A (RS-232) and SIO0/B (the USB console port, borrowed from the BIOS) |
| `zephyr/vdp.h` | V9958: registers, palette, modes, VRAM, the command engine, sprites |
| `zephyr/timer.h` | CTC ticks at 1-180 Hz, raw CTC, common memory and interrupt callbacks |
| `zephyr/sound.h` | Four PSGs as 16 channels, plus the PCM DAC |
| `zephyr/bank.h` | Banks 1-6 as data, and calls into code placed in a bank |
| `zephyr/input.h` | USB keyboard through BDOS, gamepads from the controller latches |

## Example and tests

- `examples/mandel/mandel.c` — `MANDEL.COM`, the direct-V9958 Mandelbrot from
  `../HelloWorld/src/mandelbrot_v9958_real.asm`, ported to C. Same screen, same
  fixed-point arithmetic and palette, so the two images can be compared. It also
  uses the timer, sound, input and `zep_sysinfo`.
- `tests/ticktest.c` — `TICKTEST.COM` drives the tick callback the way the BIOS
  dispatcher does and checks the phase accumulator, saturation and counters. It
  needs no CTC and runs under an emulator.
- `tests/sertest.c` — `SERTEST.COM` exchanges a line over the console port with
  a peer on the PC.
- `tests/timtest.c` — `TIMTEST.COM` runs the tick service on one CTC channel and
  touches no video or sound, so a failure is the timer path alone. It separates
  "the CPU is ignoring interrupts" from "the channel is not counting" from "the
  channel counts but never vectors", by printing the interrupt-enable state and
  the CTC's own down-counter. `TIMTEST [channel] [rate]`.
  Channels are physical CTC/BIOS interrupt sources: 0, 1, 2, 3 use ports
  40h, 42h, 41h, 43h. The test adapts setup, readback and shutdown for the
  swapped select lines; the shared timer library and BIOS remain unchanged.
- `tests/vdptest.c` — `VDPTEST.COM` draws colour bands through the VDP calls and
  waits for a key, using raw HID input so the console cannot draw over it.
- `tests/irqtest.c` and `tests/irq_probe.asm` — `IRQTEST.COM` checks AF, BC, DE,
  HL, IX, IY, the alternate register set, and SP across real BIOS interrupts.
  It tests application and OS memory mappings using the correct CTC ports.

### Interrupt register/SP diagnostic

Start with channel 3 and compare the two callback bodies:

```text
IRQTEST 3 MIN
IRQTEST 3 TICK
```

`MIN` registers an eight-byte counter callback. `TICK` registers the production
ZephyrC tick callback. Both use the running BIOS's IM2 vectors, dispatcher and
interrupt stack; neither installs a private interrupt environment. Each run
defaults to 1000 pairs of application/OS mapping windows, about 14 seconds at
10 MHz. An optional final argument selects 1–5000 pairs.

The foreground probe runs from E100h-E207h with its test stack at E300h and a
guard at E2D0h-E2FDh. It checks known register values after each window, stops
on the first mismatch, and stops the timer before printing. No console, IOC,
video or sound work runs during the windows. Counts reported around each mode's
windows establish interrupt activity, not exact per-mode timing; a few ticks
can arrive in the surrounding foreground bookkeeping. Zero coverage produces
`INCONCLUSIVE`, not `PASS`.

If a run unexpectedly warm boots, run **`IRQTEST R` before another test**, using
the same binary. The record at E000h survives the current BIOS warm boot:

- Stage 1 means the current window did not complete its snapshot; register
  values from that window are unavailable.
- Stage 2 means the assembly probe captured its state but the C checker did
  not finish validating it.
- Stage 3 means the last snapshot passed; stage 4 records a mismatch.

A bad return address can prevent the probe from reaching its capture code.
Passing therefore narrows the investigation; it does not prove interrupt
handling is safe under foreground I/O or full OS workloads. `MANDEL` remains
useful as that stress workload.

## Where it has run

`TICKTEST` and `SERTEST` pass, and `MANDEL` draws a correct set, under RunCPM
with a patched I/O layer standing in for the SIO and the V9958. **Nothing has
run on the real machine yet.** What the emulator cannot show: VDP and SIO
timing, RTS/CTS flow control, real CTC interrupts, banked memory (RunCPM has no
BDOS 210-217), and the gamepad latches.

`DOC/API.md` section 11 lists the BIOS, firmware and hardware work the
unfinished parts wait on. `DOC/KNOWN-ISSUES.md` records the problems seen on
hardware — chiefly that the machine restarts when CTC interrupts run — with
what has been ruled out and what to try next.
