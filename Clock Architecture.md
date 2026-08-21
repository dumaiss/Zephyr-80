# Zephyr-80 Clock Architecture

This document describes the clock domains in the currently committed Zephyr-80
CPU and I/O schematics. It is intentionally limited to the clocks that cross
subsystem boundaries or affect software-visible timing.

Zephyr-80 does **not** use one master oscillator for the entire machine. The CPU
system clock, asynchronous serial reference clocks, I/O Controller MCU clock,
and synchronous I/O Controller link clock are separate domains.

## Clock-domain summary

| Domain or net | Source | Frequency | Primary use |
| --- | --- | ---: | --- |
| `CLK_10M` | CPU-board Y1, ECS-2100AX-100 oscillator | 10.000 MHz | Z80 CPU and Z80 peripheral system clocks; exported on the pBITz bus |
| I/O baud reference | I/O-board Y1, 14.7456 MHz oscillator | 14.7456 MHz | Input to U8, the 74HC4040 divider |
| `CLK_7M3728` | U8 Q0, 14.7456 MHz / 2 | 7.3728 MHz | CTC trigger/reference inputs 2 and 3 |
| `CLK_3M6864` | U8 Q1, 14.7456 MHz / 4 | 3.6864 MHz | CTC trigger/reference input 1 |
| `CLK_1M8432` | U8 Q2, 14.7456 MHz / 8 | 1.8432 MHz | SIO0/B console RxC/TxC and CTC trigger/reference input 0 |
| User-serial bit clock | CTC channel 0 `TO0` | Programmable | SIO0/A user-port RxC/TxC |
| I/O Controller serial clock | I/O Controller MCU through the SIO clock buffers | Transaction-dependent | SIO1/A and SIO1/B synchronous serial shifting |
| I/O Controller MCU core | PIC18F57Q84 HFINTOSC | 64 MHz | Current committed MCU firmware |

The 14.7456 MHz oscillator and its divided outputs are local timing references
on the I/O board. They do not clock the Z80 CPU.

## Z80 system clock

The CPU board contains a fixed 10 MHz oscillator, Y1 (`ECS-2100AX-100`). Its
output is named `CLK_10M`.

`CLK_10M` clocks the Z80 and is exported through the pBITz interface. On the I/O
board it drives the system-clock inputs of the Z80 peripherals, including the
CTC and both SIO devices.

The system-clock input of a Z80 SIO is distinct from its serial `RxC` and `TxC`
inputs. Supplying a 10 MHz SIO system clock does not imply a 10 Mbit/s serial
rate. Each SIO channel shifts serial data according to its separate serial-clock
inputs and its WR4 clock-multiplier configuration.

### 10 MHz versus 20 MHz

The currently committed hardware is the fixed 10 MHz configuration. A note in
the CPU schematic mentions 10 or 20 MHz, but the fitted oscillator value and
distributed net are 10 MHz; there is no runtime clock switching.

Running the CPU at 20 MHz while retaining 10 MHz-class CTC and SIO devices is a
separate design option. It would require an explicit peripheral-clock and
wait-state strategy and is not part of the clock architecture documented here.

## I/O-board reference clocks

The I/O board uses a separate 14.7456 MHz oscillator and an SN74HC4040 binary
divider. The first three divider outputs provide exact binary divisions:

```text
14.7456 MHz / 2 = 7.3728 MHz
14.7456 MHz / 4 = 3.6864 MHz
14.7456 MHz / 8 = 1.8432 MHz
```

These frequencies feed the CTC trigger inputs as convenient timing references:

| CTC channel | Trigger/reference clock |
| ---: | ---: |
| 0 | 1.8432 MHz |
| 1 | 3.6864 MHz |
| 2 | 7.3728 MHz |
| 3 | 7.3728 MHz |

The CTC itself remains a 10 MHz Z80-bus peripheral through its `CLK` input.
Its trigger inputs are independent timing sources for the four counter/timer
channels.

## Asynchronous serial clocks

### SIO0/B console

SIO0/B receives `CLK_1M8432` directly on its receive and transmit clock inputs.
The BIOS configures the channel for asynchronous x16 operation:

```text
1,843,200 Hz / 16 = 115,200 baud
```

This is the BIOS console and current Virtual Drip transport.

### SIO0/A user serial port

SIO0/A receives the output of CTC channel 0 (`TO0`) on its receive and transmit
clock inputs. Software selects the CTC time constant and SIO clock multiplier,
allowing the user port to support programmable baud rates.

The user-port baud rate is therefore not fixed by the 14.7456 MHz oscillator
alone; it depends on both the programmed CTC channel and the SIO WR4 setting.

## Synchronous I/O Controller clock

SIO1 uses `CLK_10M` as its Z80 peripheral system clock, but its serial channels
do not use the fixed baud-divider outputs.

For the SIO1/A bulk channel and SIO1/B command channel, the I/O Controller MCU
is the serial-clock master. The MCU supplies `SIO_SCK`; 74AHCT125 buffers gate
that clock to the selected SIO channel. The clock exists only while the MCU is
participating in a transaction.

Consequences for host firmware:

- there is no fixed SIO1 baud rate;
- SIO1 is configured for synchronous x1 operation;
- the Z80 must request a transaction before expecting serial clocks;
- a polled transfer times out if the MCU never begins clocking;
- a block transfer using WAIT would stall indefinitely if the MCU stopped the
  clock before the block completed.

The current Phase 1 IOCALL path uses the SIO1/B command channel with fixed
32-byte frames. Protocol-specific edge sequencing and synchronization are
documented in
[Code/MCU/IOController/docs/external_sync_protocol.md](Code/MCU/IOController/docs/external_sync_protocol.md).

## I/O Controller MCU clock

The currently committed PIC18F57Q84 firmware uses the MCU's internal 64 MHz
high-frequency oscillator (`HFINTOSC`). It is not clocked from either the CPU
board's 10 MHz oscillator or the I/O board's 14.7456 MHz baud oscillator.

This independence allows the MCU to continue managing reset and peripheral
state regardless of the Z80 clock, while also generating the synchronous SIO1
clock under firmware control.

## Expansion-card clocks

Video and sound clocks are local to their Percolator Series expansion cards and
are outside the scope of this document. In particular, no SN76489 or VDP clock
is derived from the I/O board's 74HC4040 in the current architecture.

The Morning Joe, Lunch Crema, and Afternoon Blend clock networks belong in the
[PercolatorLabs repository](https://github.com/dumaiss/PercolatorLabs). The DIN
backplane and shared pBITz signal definitions belong in the
[pBITzPlatform repository](https://github.com/dumaiss/pBITzPlatform).

## Sources of truth

When this document disagrees with an older design note, use the current
schematics and firmware as the authority:

- CPU oscillator and `CLK_10M` distribution:
  `Schem/Zephyr-80-CPU/CPU_AddressDecoding.kicad_sch`
- I/O baud oscillator and divider:
  `Schem/Zephyr-80-IO/BaudClock.kicad_sch`
- CTC and SIO clock routing:
  `Schem/Zephyr-80-IO/IO Controller.kicad_sch`
- SIO1 transaction clocking:
  `Code/MCU/IOController/docs/external_sync_protocol.md`
- MCU oscillator configuration:
  `Code/MCU/IOController/include/config.h`

