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
| 1 | `41h` | 3.6864 MHz | `TO1` is routed outward |
| 2 | `42h` | 7.3728 MHz | `TO2` is routed outward |
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

During VGM player bring-up, CTC0 at port `40h` produced stable periodic IM2
interrupts using timer mode, `/256`, automatic trigger, and a constant of 217.
It is the currently verified application time source. That bring-up predates
the banked operating system and used a private IM2 table; `SDSOAK` now drives
CTC0 through callback registration.

Attempts to obtain usable playback interrupts from CTC1 and CTC2 did not
succeed during that bring-up. This is an unresolved observation, not proof that
either channel or its clock is defective. Before assigning those channels to a
game, use a minimal counter-only ISR and verify the channel's vector, daisy-chain
acknowledgement, control word, and board routing on the actual hardware.

The VGM player also proved that a compact ISR can coexist with the BIOS SIO
console and foreground SD streaming. Moving stream decoding, PSG writes and
BDOS reads into the ISR caused instability; moving all of that work back to
foreground code made playback reliable.

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
own interrupt stack. It saves `AF`, `BC`, `DE` and `HL`, `CALL`s the callback,
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
- use only `AF`, `BC`, `DE` and `HL`, which the BIOS saves, and preserve `IX`,
  `IY` and the alternate register set
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
