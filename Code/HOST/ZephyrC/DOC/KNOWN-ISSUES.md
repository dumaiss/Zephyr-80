# Known issues

Open problems seen on hardware, with what has been ruled out, so the hunt can be
picked up later without repeating it. Measurements are dated; hypotheses are
labelled as such and are **not** established fact.

## 1. The machine restarts when CTC interrupts are running

**Status: RESOLVED 2026-09-17.** The cause was a stray NMI on a floating /NMI
line, not anything in the CTC, the BIOS or this library. The IOC now holds the
net with a weak pull-up (`HOST_NMI_WPU = 1`); with that flashed, `TIMTEST 0`-`3`,
`MANDEL` on every channel, `TONETEST` and `PCTRACE 0`/`1` all pass, ColecoGo
runs, and the standalone endurance ROM recorded no NMIs at all. The reasoning and
the evidence are below, kept because the method is worth more than the answer:
the CTC chip and the Z80 were each replaced along the way, and neither changed
anything.

Everything from here to the end of this section is the investigation as it
stood, in the order it was learned.

**The cookie evidence holds, 2026-09-16.** The operator's `TIMTEST` cookie is a
zero-initialised static, and the build places `_cookie` in `data_compiler` with
its byte in the `.COM` image, so a reload from disk would set it back to zero.
Seeing "bad restart" therefore means control reached 0100h **without a reload**.

Worth knowing for the next diagnostic: this z88dk CP/M startup includes no
BSS-clearing at all (no `crt_init_bss`), so an *uninitialised* static keeps
whatever the previous run left in that memory. A cookie must be explicitly
initialised, as this one is, or it proves nothing.

**Operator clarification, 2026-09-15:** the spontaneous restart is a **warm
boot**. Full hardware resets occur when the operator presses reset. The earlier
IOC-driven reset hypothesis does not fit this observation. Register, stack, or
return-address corruption is a working hypothesis, not yet a diagnosis.

### Symptoms, hardware, 2026-09-15

| Test | Result |
|---|---|
| `TIMTEST 0` | Prints healthy one-second lines, then the machine restarts. The number of lines before it varies between runs. |
| `TIMTEST 1` | Registers and runs, no interrupts ever arrive. |
| `TIMTEST 2` | No interrupts. The down-counter readback moves once and then stays put. |
| `TIMTEST 3` | Normal: ten samples, interrupt counts as expected. |
| `MANDEL 3` | Render restarted when nearly complete; on the next pass it completed, chimed, reached the BIOS `[any key]` pause, then crashed. |
| `VDPTEST` | Clean. Draws and exits on a key. No timer involved. |
| `MONITOR`, `I 42` with the interrupt **disabled** (`O 42 27`, `O 42 D9`) | Changing values: the channel counts. |

### Follow-up after the TIMTEST port correction, 2026-09-15

These are operator observations with the corrected `TIMTEST`. `MANDEL` still
uses the shared library's original, incorrect mapping for channels 1/2.

| Test | Result |
|---|---|
| `TIMTEST 1`, `TIMTEST 2`, `TIMTEST 3` | Work most of the time; intermittent failures remain. |
| `TIMTEST 0` | Works sometimes. |
| `TONETEST` | Works fine. |
| `MANDEL 0` | Completes the render, then crashes; no audible chime. |
| `MANDEL 1` | Completes, chimes, reports no interrupts. |
| `MANDEL 2` | Crashes midway through the render. |
| `MANDEL 3` | Completes the render, then crashes; no audible chime. |

**Fixed in the library, 2026-09-16.** `zep_timer.c` now maps channel to port
(0,1,2,3 -> 40h,42h,41h,43h), because A0/A1 are wired to the CTC's CS0/CS1 in
reverse. Every ZephyrC call — `zep_timer_*`, `zep_ctc_*` — takes the channel
number, as registration does, and `zep_ctc_port` reports the real port.
`TIMTEST` and `IRQTEST` no longer apply their own swap: that mapping is an
involution, so keeping both would have landed back on the wrong port. `MANDEL`
is correct on every channel from this build on.

Still wrong in the BIOS, and worse than "harmless" in one case. Two places
compute the port as `CTC0_CTRL + channel`, which is the *other* channel for
sources 1 and 2 on this board:

- `irq_stop_channel` (`cbios_irq.asm:246`), used by unregister and by the
  program-exit sweep. Harmless for a single-timer program, because ZephyrC stops
  the real channel first.
- `ctc_isr_unowned` (`cbios_irq.asm:81`), the path that is supposed to shut a
  channel off when it interrupts with no registration. It disables the wrong
  channel, so the unregistered one keeps interrupting and the handler is
  re-entered forever.

That second one is a plausible mechanism for the pre-fix chaos: before
2026-09-16 the library registered one channel and started another, so a channel
with no registration was interrupting — exactly the case the BIOS cannot switch
off for sources 1 and 2. It does **not** explain CTC0, which is identity-mapped,
nor does it explain a restart that still happens with the mapping corrected.

The library cannot fix this from outside: it is the BIOS's own ISR arithmetic.
The fix is a four-entry table in `cbios_irq.asm`, the same one `zep_timer.c`
now uses. Note that `ctc_disable_interrupts` is fine as it stands: it resets all
four ports, so the order does not matter.

The corrected TIMTEST results support the swapped-port diagnosis for the
missing callbacks. They do not establish reliable interrupt operation. The
MANDEL channel 1/2 results still include that mapping fault. Absence of a chime
also has a separate software explanation (issue 5), so it does not locate the
crash at the first sound write. TONETEST does not exercise CTC/sound concurrency.

### After the channel/port fix, 2026-09-16

With `zep_timer.c` mapping channels to ports correctly, the operator reports the
fault is **much harder to provoke**, and when it does happen the machine
**hangs** rather than returning to 0100h. That is consistent with the swapped
mapping having been the dominant cause: before the fix the library started a
channel it had not registered, and `ctc_isr_unowned` cannot switch that channel
off for sources 1 and 2, so the dispatcher was re-entered without end.

**CTC0 is not covered by that fix and still fails.** The operator reports
`TIMTEST 0` still restarts after the mapping correction, which is expected:
channel 0 is at port 40h either way, so neither the library's remap nor the
BIOS's `ctc_isr_unowned` arithmetic changes anything for it. The SIO0/A mask in
`zep_timer_start` does not cure it either. CTC0 therefore has a fault of its
own, separate from the channel 1/2 mapping bug.

It is also the easiest one to capture: a restart keeps RAM, so `PCTRACE 0`
followed by `PCTRACE R` should read back the ring. Prefer channel 0 for the next
capture attempt.

What remains is rarer and different in kind, and a hang is harder to capture: it
has to be ended with the reset button, and cold boot copies ROM over
C000h-FFFFh, erasing the ring in E000h-E3FFh along with it.

`PCTRACE` therefore carries a watchdog. The foreground bumps a heartbeat; if it
stops moving for about five seconds while interrupts are still arriving, the
callback warm boots deliberately instead of returning. A warm boot leaves
E000h-E3FFh alone, so the next `PCTRACE` prints the ring and says the watchdog
fired — showing where the foreground was stuck, in which mapping.

**Nothing survives the reset button.** `boot_shadow_copy.asm` copies the common
window C000h-FFFFh, then bank 0, then loops over banks 1 through 7, so cold boot
overwrites every bank. Keeping a copy of the ring in an unused bank does not
work; only a warm boot preserves E000h-E3FFh. That is why the watchdog ends a
hang with a warm boot instead of leaving it to the operator's reset.

`PCTRACE` also records the lowest interrupted SP it ever sees. The C stack grows
down from EC06h through the CCP area; anything below E400h means it has reached
the reservation holding the ring and the tick stub, which would corrupt both.

**Its blind spot:** a hang with maskable interrupts disabled never reaches the
callback, so nothing is captured. If the watchdog never fires on a hang, that is
itself the finding — it means interrupts were off or not being delivered, and
the next step is an NMI-based probe (the V9958 can be routed to NMI through the
configuration latch) rather than a CTC one.

### Standalone ROM, 2026-09-17

A standalone bare-metal ROM (written for this hunt, since removed) reproduced
the fault with CP/M removed entirely: no
BDOS, no BIOS, no banking after startup, no library, one CTC channel, one IM2
vector, and an ISR that pushes AF and HL, bumps a counter and `RETI`s.

| Image | Result |
|---|---|
| `control.rom` — interrupts never enabled | runs indefinitely, no failure |
| `ctc0.rom` | `FAIL 05: REGISTER MISMATCH`: `reg=BC found=0000 expected=1357`, `sp=EFF6`, after 36 interrupts |
| `ctc0t.rom` | `FAIL 02: SP MISMATCH`, `sp=EFFC`, after 17 interrupts; all eight traced interrupts clean |

Both builds run the same foreground stress, stack guards, register checks and
serial reporting from the same memory map; the only difference is whether
interrupts are ever enabled. So the corruption follows interrupt activity, and
the software above the interrupt path — CP/M, the BIOS framework, the C runtime
and this library — is no longer needed to produce it.

**The machine takes an NMI.** Both failures decode to a pushed PC that nothing
popped, with the foreground resumed at 0066h -- the Z80's NMI entry. In the
`ctc0.rom` run the stack held the return chain `main_loop` -> `ticks_check` ->
`ticks_snapshot` -> `copy4` and then `copy4`'s own entry address as a pushed
PC, with `BC=0000` and `DE=8214` exactly matching what `copy4`'s `LDIR` leaves;
`HL`, `IX` and `IY` were correct because 0066h is the instruction after the two
the CPU skipped. In the `ctc0t.rom` run the pushed PC was 00AAh, inside the
verifier, and the eight traced interrupts were all clean -- so the CTC, the
daisy chain and the IM2 acknowledge work.

**This is the restart under CP/M.** A CPU with nothing at 0066h carries on
executing whatever lives there, one stack word deeper than it should be. Under
CP/M that is unused page zero, and execution slides through it and the 0080h
DMA buffer into the TPA at 0100h -- the jump back to the start of the program
that has been observed all along. What is still unknown is what pulls /NMI; the
ROM now handles and counts NMIs, which measures rate and whether they occur
with interrupts disabled.

**For the BIOS:** two bytes at 0066h (`ED 45`, `RETN`) in whatever page zero a
program runs under makes a stray NMI harmless instead of fatal. That is worth
doing regardless of what the source turns out to be.

**/NMI is floating.** `Code/MCU/IOController/src/main.c` leaves the PIC's /NMI
pin (RF5) high-impedance (`HOST_NMI_TRIS = 1`, "the PIC does not currently
implement the manual NMI request"), and the IPC netlists give the /NMI net
exactly four pins across both boards -- the Z80's NMI input (U3-17), that PIC
pin (U15-13) and the two bus connector pins (J2-A12, J4-A12). No pull-up
appears on it. An edge-triggered CMOS input with no driver and no pull-up is
free to fire on coupled noise; the coupling itself has not been measured.

That also answers why the control build never failed and why CTC3 is the one
channel that works: the Z80 CTC has ZC/TO output pins on channels 0, 1 and 2
only. `control.rom` starts no channel, and a running channel 3 switches nothing
outside the chip. CTC0's TO0 drives the UART baud clock net.

Two fixes, independent of each other:

- **Hold /NMI.** A pull-up on the net, or the PIC's weak pull-up on RF5
  (`WPUFbits.WPUF5`) with the pin left an input so a card can still pull it
  low. Driving it push-pull would fight the bus and is what the current comment
  avoids.
- **Make a stray NMI harmless.** Two bytes at 0066h (`ED 45`, `RETN`) in
  whatever page zero a program runs under. Worth doing regardless: under CP/M
  0066h lands inside the default FCB (005Ch-007Fh), so what a stray NMI
  executes depends on the command line -- which is why the same fault has
  appeared as a restart, a warm boot and a hang.

**It is interrupt delivery, not the channel running.** A timer-only image
(`ctc0o.rom`: channel 0 counting at 180 Hz, driving TO0, interrupt never
enabled) collects no NMIs, while `ctc0t.rom` on the same channel does. So the
aggressor is /INT being asserted and the M1+IORQ acknowledge cycle, not the
channel or its ZC/TO output. On the Z80 those two nets meet at adjacent package
pins -- /INT on 16, /NMI on 17 -- which is a plausible coupling site, though
that is read off the pinout and has not been measured. Why CTC3 has always
worked under CP/M is still unexplained; `ctc3t.rom` tests it.

**Applied 2026-09-17:** the IOC now enables the weak pull-up on RF5
(`HOST_NMI_WPU = 1` in `Code/MCU/IOController/src/main.c`), keeping the pin an
input so any card can still pull /NMI low. IOC_FW_LEVEL is deliberately
unchanged, so no host utility needs rebuilding; the check is behavioural --
the endurance ROM's `nmi=` count should stay at zero.

**Confirmed fixed 2026-09-17.** With `HOST_NMI_WPU = 1` flashed on the IOC,
`ctc0t.rom` and `ctc3t.rom` collect no NMIs at all. Before that the CTC chip
and then the Z80 itself had both been swapped with no change: the fault was a
bus signal nothing was holding, not a failing part. What remains to be re-run
is the CP/M-level evidence -- `TIMTEST 0`-`3`, `MANDEL`, `TONETEST`, `PCTRACE`
-- and the BIOS channel-port defect below, which is a real bug independent of
the NMI.

The SP is the more informative half. The verifier that reported the mismatch is
called from the main loop, where SP must be EFFE; EFF6 is four words deeper,
which is the nested stress routine's own depth. Control therefore reached the
check from the wrong place, with the stack still holding registers that the
return path should have restored -- the same shape as the "jumps back to 0100h"
symptom under CP/M, and consistent with a corrupted return address rather than
a single flipped register bit. BC reading 0000 is not a value the foreground
loads anywhere.

Traced ROM images (`ctc0t.rom` and friends) now record the address each
interrupt was going to return to, plus the SP it acknowledged with, and print
the last eight at failure alongside a window of the failing stack.

### Ruled out

- **A defective CTC.** The chip was replaced; behaviour is identical.
- **CP/M, the BIOS interrupt framework and this library as the sole cause.** The
  standalone ROM above corrupts a register with none of them present. They may
  still make it worse or more frequent, but they are not required for it.
- **The tick callback's tested arithmetic.** `TICKTEST` passes its cases,
  including saturation and per-channel isolation. Its assembly wrapper calls
  `E300h` directly with C = channel and saves IX/IY itself. It does **not** test
  interrupt acknowledge, IM2 dispatch, the BIOS stack switch, register
  restoration, or `RETI`; those paths remain under investigation.
- **The VDP path and raw HID input.** `VDPTEST` is clean, and `MANDEL` renders
  correctly once it stops polling the console (issue 2).
- **`ld a,i` interrupt-state restore.** That erratum is NMOS-only and this
  machine has a CMOS Z80. The library no longer uses `__critical` regardless.
- **Interrupts being disabled at program start.** z88dk's CP/M startup emits
  neither `DI` nor `EI`; a program inherits the CCP's state, which is enabled.
  ("Interrupts off" under RunCPM is an emulator artifact.)
- **`zep_sysinfo` returning nothing.** That was z88dk's `bdos()` destroying the
  HL result; fixed, and BDOS 200 registration now succeeds.

### Hypotheses, untested

1. **Corrupted registers, SP, or return address.** Inspect the path into warm
   boot and the interrupted context. CTC and SIO share the saved-SP word at
   `FE80h` and the interrupt stack `FE82h-FEBFh`. The normal CTC dispatcher plus
   ZephyrC callback uses at most 12 of those 62 stack bytes; the CPU also pushes
   its two-byte return address onto the interrupted stack. No missing primary
   register save is apparent in the source. An overwrite or unintended nested
   interrupt is still possible and needs runtime evidence.
2. **CTC0 specifically: SIO0/A noise.** `TO0` is SIO0/A's clock, and that
   channel's `WR1` holds `08h` because `sio_core_enable_interrupts` writes its
   chip-wide enable to `SIO_MASTER_CTRL_PORT`, which is SIO0/A's control port; a
   Z80 SIO has no `WR9`, so pointer 9 selects `WR1`. Clocking the channel would
   then receive noise and raise interrupts that vector to the console handler,
   which reads only channel B and never clears them. `zep_timer_start` masks
   SIO0/A before starting CTC0 — and `TIMTEST 0` still restarts, so this is
   **not** the whole story, though the BIOS write is still worth fixing.
3. **CTC1/CTC2 channel numbering.** The schematic and PCB connect the channel
   select bits in reverse order; see issue 4. A zero application callback count
   does not establish that no interrupt was acknowledged.

### Experiments worth running next

- Run `PCTRACE 3` (or `PCTRACE 0`), let the fault happen, then run `PCTRACE`
  again — or `PCTRACE R` — to read the retained ring. Its callback records the
  interrupted PC, SP, bank latch and channel for every interrupt into
  E000h-E2FFh, which survives both a warm boot and the jump to 0100h, and it
  keeps a marker for which part of its own loop was running. This aims straight
  at the operator's finding that control returns to 0100h with RAM intact: the
  last entries say what was executing, in which mapping, just before it. A
  clean run erases its own ring, so anything reported is a real fault.
- Run `IRQTEST 3 MIN` and `IRQTEST 3 TICK`. This new hardware diagnostic checks
  registers/SP across real BIOS interrupts in application and OS mappings,
  comparing a minimal counter callback with the production tick callback.
  After an unexpected warm boot, run `IRQTEST R` before another test to inspect
  its retained stage and last snapshot. See the README for limits: a corrupted
  return address may prevent capture, and no foreground I/O is exercised.
- `TIMTEST 3` for a minute or more: is the good channel stable over time, or
  does it simply restart later?
- A timer-plus-sound test smaller than `MANDEL`, since `MANDEL 3` died at a
  point where both were active.
- `SDSOAK` (in `../../Utilities`), which drives CTC0 from assembly through the
  same BDOS 200 registration. If it is stable, the difference is in the C
  program or its runtime, not the BIOS interrupt path.
- Watch whether a restart correlates with console output or HID polling by
  making `TIMTEST` print nothing until the end.

Diagnostic caveat: `DIAGCHK` deliberately provokes a rejected bulk request and
overwrites the BIOS last-failure record with that synthetic failure. It is a
record-capture test, not a passive post-crash reader. Preserve any original
record before running it.

### Interrupt source review, 2026-09-15

MANDEL is a machine/OS stress workload, not the feature being repaired. Its
successful channel 1 run with zero callback ticks is relevant to the interrupt
investigation; because that build has the wrong port mapping, it is not proof
that the CTC made no interrupt requests. Chime timing is secondary.

No missing primary register save or early EI was found in the normal CTC
dispatcher plus ZephyrC callback. Executing the built BIOS handlers and callback
in qkz80 CPU emulation passed 12,288 register/SP/return checks over CTC vectors,
SIO with no RX data, the FFh guard vector, several stack addresses and varied
register values. This does not model physical bus timing or reproduce the full
OS stress workload.

The new IRQTEST probe passed 192 emulated checks across all four CTC channels,
both memory mappings and both callbacks. Those checks included deliberate
corruption of each of its 11 register-pair/SP observations and verified detection
and caller-context restoration. Its hardware results are still pending; the
warm-boot fault is not fixed.

## 2. The console draws into the VDP — fixed in the library, worth knowing

`v9958_console_const` flushes the pending print run, writes the cursor sprite
attributes and presents. A **console input poll therefore writes to the VDP**,
not just console output.

`MANDEL` used to poll ESC through BDOS once per rendered row while holding the
VDP, which let the console scribble into the registers and VRAM being drawn, and
could leave the address latch half-set between the program's own two-byte
writes. Symptoms were timing-dependent crashes that looked like a timer fault.

It now reads keys straight from the IO Controller (`zep_kbd_raw_getc`). The rule
for any program holding the VDP: no console I/O at all until `zep_vdp_release`.

## 3. `TONETEST`'s delays were optimised away

**Fixed 2026-09-15.** Its `hold()` used empty `for` loops, which SDCC removes, so
the chord, the fade and the noise all ran in microseconds: the run played three
notes in quick succession and printed "fade" and "noise" with nothing audible.
That output says nothing about the sound card. The counters are now `volatile`.

Any timing loop in a C program here needs `volatile`, or a timer.

## 4. CTC1/CTC2 port and interrupt channel numbering disagree

**Source finding, 2026-09-15; hardware confirmation pending.** Both
`Schem/Zephyr-80-IO/IO Controller.kicad_sch` (exported netlist) and
`Schem/Zephyr-80-IO/Zephyr-80-IO.kicad_pcb` connect IC1 pin 18 (`CS0`) to A1 and
pin 19 (`CS1`) to A0. Paths are relative to the repository root.

Using the channel-select truth table in the
[Zilog manual, Table 4, printed page 13](https://www.zilog.com/docs/z80/um0081.pdf#page=31),
that wiring gives:

| CPU port | Physical CTC channel | Interrupt vector with base 00h |
|---|---|---|
| 40h | 0 | 00h |
| 41h | 2 | 04h |
| 42h | 1 | 02h |
| 43h | 3 | 06h |

The shared library assumes port = `40h + channel`. Thus the original `TIMTEST 1`
registered slot 1 but started physical channel 2; `TIMTEST 2` did the reverse. The BIOS would
dispatch to an unregistered slot and its unowned-channel reset would also
address the wrong physical channel. This explains missing callback counts if
the running board matches these files, but does not yet explain the reported
frozen readback or warm boots on channels 0/3.

`TIMTEST` now adapts channels 1/2 locally: it registers the physical channel,
programs and reads the swapped port, and explicitly resets that port before
unregistering. The library and BIOS mappings remain unchanged. The BIOS's
unregister also resets the opposite channel, which is unused in this
single-timer test. The original measurements predate this correction; the
follow-up reports that channels 1/2 now work most of the time, supporting the
mapping correction while leaving the intermittent warm boots unresolved.

Use CTC3 for further warm-boot isolation because its select bits are unaffected;
this is not a claim of long-run stability. CTC0 is additionally entangled with
SIO0/A's clock (hypothesis 2 above).

`../../CPM2.2/docs/ctc-and-real-time-programming.md` carries the same
measurements for readers coming from the BIOS side.

## 5. MANDEL's chime consumes ticks accumulated during rendering

**Confirmed on hardware and fixed, 2026-09-17.** With the NMI fault out of the
way, `MANDEL 0` ran to completion with a working timer and produced no audible
chime, while `MANDEL 1` -- whose channel reported zero interrupts -- took the
spin-delay path and chimed normally. That is this bug exactly, and the reading
below was right. `chime()` now drains the pending queue before the fade, so the
fade waits only on ticks that arrive during the chord.

The original reading, 2026-09-15: the render reads the raw
interrupt count but never consumes logical ticks. The pending queue can hold
255 ticks, while `chime()` consumes only 13 fade steps times 8 ticks = 104 ticks.
If at least 104 ticks are pending, every fade step can consume old ticks without
waiting for a new timer interval, making the chord too brief to hear.

This explains why a working timer can produce no audible chime while a silent
timer takes the bounded spin-delay path and produces an audible one. It never
explained the warm boots, and did not have to: those were the stray NMI.

`MANDEL 1`'s zero interrupt count turned out to be a stale `.COM` on the disk,
not a library fault: a fresh copy from `build/` reports interrupts on every
channel.

The fade also needed a real time floor. Its fallback was `spin < 4000`, an
iteration count rather than a duration -- a few milliseconds -- so a fade that
fell back on it for all 13 steps finished before it could be heard. Steps that
do not get their ticks now hold for about 60 ms, and the run prints
`chime: N of 13 steps paced by the floor, M ticks consumed` so the pacing is
visible rather than guessed at. `MANDEL <channel> P` additionally probes the
raw count before the VDP is acquired.
