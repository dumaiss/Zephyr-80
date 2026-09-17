# CTC and Real-Time Programming on Zephyr-80

This note records the CTC and real-time constraints found while bringing up
ColecoGo and the streamed VGM player. It is guidance for games and other timed
applications running on the current Zephyr-80 hardware and CP/M BIOS. It does
not reserve a CTC channel.

Unless a section says otherwise, clock rates and timing figures below apply to
the currently committed fixed **10.000 MHz** CPU board.

## Hardware and BIOS ownership

The Z80 CTC occupies four consecutive I/O ports:

| Channel | Port | External `CLK/TRG` input | Other connection |
| ---: | ---: | ---: | --- |
| 0 | `40h` | 1.8432 MHz | `TO0` clocks the application-owned SIO0/A user port |
| 1 | `42h` | 3.6864 MHz | `TO1` is routed outward |
| 2 | `41h` | 7.3728 MHz | `TO2` is routed outward |
| 3 | `43h` | 7.3728 MHz | General application timer/counter |

The CTC's Z80 bus and internal timer clock run from the 10 MHz system clock.
The frequencies in the third column are separate external trigger/counter
inputs derived from the I/O board's 14.7456 MHz oscillator. They are not the
clock used by an automatically triggered channel in timer mode.

The CTC channels belong to programs, but their interrupt vectors belong to the
BIOS. The BIOS resets all four channels with their interrupt enables clear and
programs the CTC vector base at cold and warm boot. A program that wants a
channel's interrupt registers a callback with the BIOS (see
[Interrupts under CP/M](#interrupts-under-cpm)). Consequently:

- a transient may program the CTC, and should stop its channels and unregister
  before returning to CP/M;
- warm boot resets the CTC and clears every registration, and so does ZCPR2 when
  a transient returns to it;
- a channel that interrupts without a registration is reset by the BIOS;
- CTC0 is not entirely consequence-free: changing `TO0` changes the clock seen
  by SIO0/A, even though the BIOS does not currently use that serial channel;
- code that takes over the machine, such as ColecoGo, should explicitly reset
  every CTC channel rather than inherit a transient's setup.

The interrupt daisy-chain order is:

```text
IEI -> CTC -> SIO0 -> SIO1 -> IEO
```

An enabled CTC source therefore has higher hardware priority than the BIOS
console SIO. This makes a bounded CTC ISR especially important: a CTC interrupt
held in service can delay console receive and lower-priority devices.

## Timer-mode rate calculation

In timer mode the periodic interrupt rate is:

```text
rate = 10,000,000 / (prescaler * time_constant)
```

The prescaler is 16 or 256. A programmed time constant of `00h` means 256, not
zero. The control word used by the current VGM player is `A7h`:

```text
D7  interrupt enabled
D6  timer mode
D5  prescaler 256
D4  rising edge (irrelevant with automatic trigger)
D3  automatic trigger
D2  time constant follows
D1  software reset
D0  control word
```

Some useful 10 MHz examples are:

| Prescaler | Constant | Interrupt rate | Period |
| ---: | ---: | ---: | ---: |
| 256 | 4 | 9,765.625 Hz | 0.1024 ms |
| 256 | 20 | 1,953.125 Hz | 0.5120 ms |
| 256 | 39 | 1,001.603 Hz | 0.9984 ms |
| 256 | 217 | 180.0115 Hz | 5.5552 ms |
| 256 | 256 (`00h`) | 152.5879 Hz | 6.5536 ms |

A direct 60 Hz timer interrupt cannot be obtained from the internal 10 MHz
timer clock: even `/256` with a constant of 256 is still about 152.6 Hz. The
working solution is a 180.0115 Hz base using `/256` and 217, followed by a
software divide by three. That produces approximately **60.0038 Hz**.

For rates other than an integer divisor, use a phase accumulator. VGMPLAY adds
the requested metadata rate on each approximately 180 Hz interrupt and emits a
logical tick whenever the accumulator crosses 180. This supports logical rates
from 1 through 180 Hz without changing the hardware CTC setup. It introduces
the normal one-base-tick scheduling jitter; 60 Hz is the clean divide-by-three
case and has no alternating interval pattern.

## What has been verified on hardware

**Read the dates.** The per-channel results below were measured while the
machine was taking stray NMIs, which is fixed as of 2026-09-17 (see "The
machine takes an NMI" further down). After the fix, `TIMTEST 0` through
`TIMTEST 3` all pass, `MANDEL` reports interrupts on every channel, and
ColecoGo's NMI route works. The channel-by-channel failures recorded here were
symptoms of the NMI, not of the channels. The separate BIOS channel-port defect
described below has since been corrected as part of the IRQ core cleanup.

The observations below predate the [IRQ core cleanup](irq-core-cleanup.md).
That cleanup fixes BIOS channel shutdown mapping and SIO0/A ownership, but
the physical TIMTEST restart regression has not yet been rerun.

During VGM player bring-up, CTC0 at port `40h` produced stable periodic IM2
interrupts using timer mode, `/256`, automatic trigger, and a constant of 217.
It is the currently verified application time source. That bring-up predates
the banked operating system and used a private IM2 table; `SDSOAK` now drives
CTC0 through callback registration.

Attempts to obtain usable playback interrupts from CTC1 and CTC2 did not
succeed during that bring-up.

Measured again on 2026-09-15 with `ZephyrC/tests/timtest.c`, which registers a
callback through BDOS 200, programs the channel for 180 Hz, and reports both the
interrupt count and the channel's own down-counter:

| Channel | Counts | Interrupts | Notes |
|---|---|---|---|
| 0 | yes | yes | The machine restarts part way through a run, after a varying number of samples. |
| 1 | — | **none** | Timer programmed identically to CTC3. |
| 2 | once | **none** | The down-counter readback moves once, then stays put, when the control word has its interrupt enabled. With the interrupt **disabled** (`MONITOR`: `O 42 27`, `O 42 D9`), `I 42` returns changing values, so the channel does count. |
| 3 | yes | yes | Ten one-second samples complete normally. |

**The CTC chip was replaced and the behaviour is identical**, so this is not a
defective part.

Zero callback counts do not prove that CTC1/CTC2 never vector. Source inspection
on 2026-09-15 found that both the schematic and PCB wire IC1 CS0 (pin 18) to A1
and CS1 (pin 19) to A0. If the running board matches, ports 41h and 42h address
physical channels 2 and 1 respectively, whose vectors are 04h and 02h. The
software assumes the opposite mapping and therefore dispatches to the wrong
callback slots. See issue 4 in `../../ZephyrC/DOC/KNOWN-ISSUES.md` for evidence
and the confirmation still needed. The ownership and port tables above describe
the current software assumptions; no mapping fix has been applied. CTC3 avoids
this mismatch, but its long-run stability has not been established.

After the test-local port correction, the operator reports that `TIMTEST 1`,
`TIMTEST 2`, and `TIMTEST 3` work most of the time, while `TIMTEST 0` works only
sometimes. This supports the channel-select diagnosis but leaves intermittent
warm boots unresolved. `MANDEL` still uses the uncorrected shared library;
its channel 1/2 results therefore still include the mapping fault. The latest
test results and a separate chime tick-backlog issue are recorded in
`../../ZephyrC/DOC/KNOWN-ISSUES.md`.

CTC0 delivers interrupts, but starting it makes the machine restart part way
through a run. Note that masking SIO0/A first, which the paragraph below
suggested as the cause, does **not** stop it: `zep_timer_start` does that and
`TIMTEST 0` still restarts. The BIOS write described below is real and worth
fixing, but it is not the whole explanation. `TO0` is SIO0/A's clock, and that channel's `WR1` holds `08h` --
"interrupt on first received character" -- because `sio_core_enable_interrupts`
writes its chip-wide enable to `SIO_MASTER_CTRL_PORT`, which is SIO0/A's own
control port, and a Z80 SIO has no `WR9`: pointer 9 selects `WR1`. Once `TO0`
clocks the channel it receives whatever its unconnected input floats to and
raises interrupts that vector to the console handler, which reads only channel
B and so never clears them. `zep_timer_start` masks SIO0/A before starting
CTC0; the BIOS write itself has not been changed.

### The BIOS resets the wrong channel for sources 1 and 2 (fixed)

**Corrected in the IRQ core cleanup.** `ctc_stop_channel` / `irq_stop_channel`
in `cbios_bank.asm` now index a four-entry `ctc_ports` table, and
`tests/irq_core.cpp` asserts the port written for each source, so a regression
here fails the test rather than the machine. The original finding follows.

Because A0/A1 reach the CTC's CS0/CS1 in reverse, `CTC0_CTRL + channel` is the
wrong port for channels 1 and 2. Two places in `cbios_irq.asm` do that
arithmetic:

- `irq_stop_channel` (line 246), used by `irq_unregister` and by the
  program-exit sweep, stops the neighbouring channel instead.
- `ctc_isr_unowned` (line 81), which exists to shut a channel off when it
  interrupts with no registration, disables the neighbour. The unregistered
  channel keeps its interrupt asserted and the dispatcher is re-entered
  indefinitely.

A four-entry port table fixes both, which is what the BIOS now does;
`ZephyrC/src/zep_timer.c` carries the same table. `ctc_disable_interrupts` needs no change, since it resets all four ports.

The open symptoms, what has been ruled out, and the experiments worth running
next are kept in `../../ZephyrC/DOC/KNOWN-ISSUES.md`. The operator clarified on
2026-09-15 that spontaneous restarts are warm boots; full hardware resets are
manual. The earlier IOC-reset hypothesis does not fit that observation.
Register, SP and return-address corruption remain hypotheses. `TICKTEST` tests
the callback directly, not IM2 entry, the BIOS stack switch or `RETI`.

The VGM player also proved that a compact ISR can coexist with the BIOS SIO
console and foreground SD streaming. Moving stream decoding, PSG writes and
BDOS reads into the ISR caused instability; moving all of that work back to
foreground code made playback reliable.

### Standalone ROM test: the fault survives removing CP/M

A standalone bare-metal ROM (written for this hunt, since removed) was that runs one CTC channel, one
IM2 vector and a six-byte ISR with no CP/M, no BIOS, no banking and no other
interrupt source. Two builds are identical except that one never enables
interrupts. On 2026-09-17:

| Image | Result |
|---|---|
| `control.rom` (interrupts never enabled) | runs indefinitely, no failure |
| `ctc0.rom` | `FAIL 05: REGISTER MISMATCH`: `reg=BC found=0000 expected=1357`, `sp=EFF6`, after 36 interrupts |
| `ctc0t.rom` | `FAIL 02: SP MISMATCH`, `sp=EFFC`, after 17 interrupts; all eight traced interrupts clean |

The foreground stress, the stack guards, the register checks and the memory map
are the same in both, so the corruption follows interrupt activity rather than
the CPU, the SRAM or the test loop. **Both failures decode to an NMI.** Each leaves a pushed PC that nothing popped
and the foreground resumed at 0066h, the Z80's NMI entry: in one run the pushed
word was `copy4`'s own entry address with `BC`/`DE` holding that routine's
`LDIR` residue, in the other it was an address inside the register verifier.
The traced build's eight recorded interrupts were all clean, so the CTC, the
daisy chain and the IM2 acknowledge are working. Under CP/M nothing sits at
0066h, so a stray NMI runs off through page zero and the 0080h DMA buffer into
the TPA at 0100h -- the restart that has been reported since the beginning. Two
bytes at 0066h (`ED 45`, `RETN`) would make it harmless; what pulls /NMI is not
yet known, and the ROM now counts NMIs to find out.

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

`sp=EFF6` is the load-bearing part: the verifier that
reported it is called from the main loop, where SP must be EFFE, and EFF6 is
four words deeper -- the depth inside the nested stress routine. So control
reached the check from somewhere it should not have, with the stack still
holding registers the return path should have restored. The failure takes about
a fifth of a second to appear, so it is cheap to reproduce. It ran one CTC
channel, one IM2 vector and a six-byte ISR with no CP/M, no BIOS and no banking
after startup.

## Interrupts under CP/M

The BIOS owns IM2. The operating system runs from SRAM bank 7, which replaces
`2000h-DFFFh` of the running program's bank while it executes. An interrupt can
therefore arrive while almost all of the program's memory is unmapped, and only
common memory, `E000h-FFFFh`, is guaranteed to be there.

So `I` always selects the BIOS vector page at `FD00h`, whose 256 entries all
lead to BIOS code in common memory:

```text
00h-06h   CTC channels 0-3   BIOS dispatcher -> the registered callback
10h-1Eh   SIO0               BIOS console receive
others                       EI, RETI
```

Programs never load `I`, change interrupt mode, write the CTC vector byte or
install a vector table. A private table, as the VGM player once built, is no
longer safe: the table and its handlers would be in the program's bank, which is
not mapped while the BIOS runs.

A program gets a channel's interrupt this way:

1. Copy the callback, and all the code and data it touches, into
   `E000h-E3FFh`. That 1 KiB is reserved for the running program and is mapped
   in both modes.
2. Call BDOS function 200 with `B` = channel 0-3 and `DE` = the callback entry.
   `A = 00h` means registered. `A = FFh` means refused: no such channel, an
   entry outside `E000h-E3FFh`, or a channel already registered.
3. Program the channel's mode and time constant, with its interrupt enabled.
4. To stop, call BDOS function 201 with `B` = channel. The BIOS resets the
   channel and clears the slot.

When the channel fires, the BIOS saves the interrupted `SP` and switches to its
own interrupt stack. It saves `AF`, `BC`, `DE`, `HL`, `IX`, `IY` and the
alternate registers, calls the callback,
restores everything, and ends with `EI` / `RETI`. `SDSOAK`
(`../../Utilities/src/ioc_sdsoak.asm`) is a small complete example.

`../../Utilities/src/zbdos.inc` defines the function numbers
(`ZB_REGISTER_ISR`, `ZB_UNREGISTER_ISR`) and the reservation
(`ZB_ISR_AREA`).

A machine-taking program such as ColecoGo, which never returns to CP/M, can
still build its own interrupt environment. It must first quiesce the BIOS
interrupt sources and establish the whole environment explicitly, as it does
today.

## ISR contract

Treat the timer ISR as a scheduler, not as the game loop.

The proven pattern is:

```text
CTC callback
-> update phase
-> increment a pending-tick counter
-> RET

foreground loop
-> atomically consume pending ticks
-> update game/audio state
-> perform bounded rendering work
-> refill inactive buffers
-> poll input and CP/M services
```

A callback runs on the BIOS interrupt stack with interrupts disabled, possibly
while the operating system's bank is mapped. It must:

- keep its code, callees and data in `E000h-E3FFh`, and touch no memory below
  `E000h`
- use the general, index and alternate registers saved by the BIOS; keep
  callback pushes and callee return addresses within the 40-byte stack budget
- end with `RET`; the BIOS issues `EI` / `RETI`
- never enable interrupts
- never call BDOS or the BIOS, write the banking latch, access the disk, print
  diagnostics, redraw the screen, wait on an I/O port, or decode an unbounded
  command stream

Registration checks only the entry address. The rest is the program's
responsibility.

A pending counter is preferable to a single Boolean flag because an interrupt
blackout can span more than one logical tick. Saturation is safer than wrapping,
but saturation still loses elapsed time if foreground work is blocked too long.
Game code should decide deliberately whether to catch up, drop rendering while
simulation catches up, or clamp the backlog. Running many catch-up frames with
full rendering usually makes an overload worse.

## The 60 Hz budget

At 60 Hz one frame is 16.667 ms, or about **166,667 Z80 T-states at 10 MHz**.
That is the total budget, not the amount safely available to one uninterrupted
routine. Video interrupts, CTC and SIO entry/exit, wait-stretched I/O, storage
critical sections, and foreground housekeeping all consume part of it.

Known blocking or interrupt-masked intervals in the current software include:

| Operation | Approximate interval | Real-time consequence |
| --- | ---: | --- |
| ROM-disk 128-byte `LDIR` | 0.27 ms | Maskable interrupts deferred briefly |
| IOC command frame transfer | 1.1 ms | Maskable interrupts disabled for the frame |
| IOC bulk SD read, 512 bytes | 3.1 ms | Maskable interrupts disabled; timer ticks coalesce |
| IOC bulk SD write, 512 bytes | about 12.3 ms | Nearly a full 60 Hz frame with interrupts disabled |

These are bounded transport windows, not guaranteed CP/M file-call times. An SD
operation also includes controller/card latency while interrupts may be enabled,
and an error or retry can be much longer. A game cannot assume that a BDOS read
will complete inside one frame just because the wire transfer normally does.

The maskable-interrupt blackout does not stop the CTC from reaching terminal
count. It only prevents the CPU from servicing the request. Multiple expiries
from one CTC channel do not form a timestamped event queue, so a periodic timer
is a scheduling wake-up, not an infallible accounting clock across long `DI`
windows.

For streamed game data or music:

- preload enough data before enabling the real-time clock;
- use at least two buffers, and never let the producer write the active one;
- publish a buffer as ready only after its length and contents are complete;
- refill incrementally, servicing pending ticks between CP/M records;
- make an underrun an explicit state rather than parsing beyond valid data;
- expect card errors and decide whether to pause, silence audio, or abort.

VGMPLAY's two 6144-byte buffers and one-128-byte-record-at-a-time refill are the
current reference implementation. They reduced a large refill stall to a small
block-boundary glitch without moving disk work into interrupt context.

## Video timing and Coleco compatibility

For Coleco-compatible games, the V9958 vertical interrupt routed to NMI is the
natural frame source. It remains independent of maskable CTC/SIO interrupt
state, but its service routine must still be short and must acknowledge the VDP
correctly. During ColecoGo bring-up, leaving the V9958 status-register pointer
on status register 4 prevented the expected status-0 read from releasing the
vertical interrupt request. The line remained asserted and games stalled at
transitions such as game-over. Restore/select status register 0 before the
Coleco NMI path relies on reading it.

The CTC is still useful for audio, profiling, input pacing, or a scheduler that
is deliberately independent of vertical blank. Do not use a second 60 Hz CTC
tick to advance the same simulation already advanced by VDP NMI; that creates
two clocks that will slowly drift.

ColecoVision software also expects a CPU near 3.58 MHz. Running it at 10 MHz
does not merely shorten instruction delays: title code may advance fuel,
animation, collision or other state per loop iteration rather than strictly per
vertical interrupt. Donkey Kong was largely playable at 10 MHz, while Zaxxon
consumed fuel noticeably too quickly. The present loader therefore provides
"mostly compatible" behavior, not cycle-accurate Coleco timing. Game code
written specifically for Zephyr-80 should use frame/timer events for elapsed
time and reserve calibrated busy loops only for very short hardware setup
delays.

If a future CPU board offers selectable CPU clocks, all instruction-time and
internal CTC timer-mode figures in this document scale with that clock. The
external 1.8432/3.6864/7.3728 MHz `CLK/TRG` references come from a different
oscillator and do not automatically scale with the CPU. Software must know the
selected clock or measure a stable reference before calculating CTC constants.

## Practical game-loop checklist

- Choose one authority for simulation time: normally VDP NMI for a video game,
  or CTC for a non-video real-time task.
- Keep NMI and CTC ISRs bounded; publish work to foreground code.
- Budget for the worst interrupt-masked interval, not only average CPU load.
- Never call BDOS or perform streamed I/O from an ISR.
- As a CP/M transient, get timer interrupts by registering a callback in
  `E000h-E3FFh`; never load `I` or install a vector table.
- Stop and unregister every channel the program uses before exiting.
- Use double buffering and incremental reads for streamed assets.
- Count and expose missed ticks, underruns and unexpected interrupts during
  development, but print those counters only after timing-critical work stops.
- Test on hardware with simultaneous keyboard, storage, video and sound load.
- Recheck every constant if the CPU clock changes.

## Source references

- `src/platform_zephyr80.inc` — CTC ports and reset command.
- `src/cbios_irq.asm` — IM2 vector page, CTC dispatcher, registration and the
  callback contract.
- `src/cbios_boot.asm` — cold/warm-boot CTC reset and registration clearing.
- `src/cbios_ioc_command.asm` — interrupt-masked command and bulk-transfer
  timing constraints.
- `../../Utilities/src/ioc_sdsoak.asm` — CTC0 through callback registration.
- `../../VGMPlayer/src/vgmplay.asm` — CTC0 timing, phase accumulator and
  foreground tick processing.
- `../../ColecoGo/src/colecogo.asm` — machine takeover and V9958 NMI setup.
- `../../../../Clock Architecture.md` and
  `../../../../Z80 Peripherals Controller.md`
  — board clock domains, CTC inputs and daisy-chain order.
