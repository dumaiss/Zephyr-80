# Zephyr-80 Peripheral Controller Architecture

This document describes the current Zephyr-80 I/O board and its software-visible interfaces. It replaces the earlier proposal in which a microcontroller exposed separate asynchronous UART streams for SD storage and USB HID.

The current design has three distinct parts:

- **SIO0** provides the conventional asynchronous serial interfaces.
- **CTC** supplies programmable timing and application timers.
- **SIO1** provides a synchronous host-to-MCU transport.

The committed I/O-board design uses a **PIC18F57Q84** as the I/O controller. The implemented MCU command set is intentionally small; storage, HID, and unsolicited event delivery remain future services rather than current APIs.

## Hardware overview

| Device | Designator | Role |
| --- | --- | --- |
| Z80 CTC | IC1 | Programmable timing, baud-clock generation, and application timers |
| Z80 SIO/0 | IC2 (SIO0) | Asynchronous console and user serial channels |
| Z80 SIO/0 | IC3 (SIO1) | Synchronous MCU command and bulk-data channels |
| PIC18F57Q84 | U15 | I/O controller and synchronous-clock master |
| 74AHCT125 | U1 | Gating/buffering between SIO1 and the MCU |
| FT230XS | U7 | USB serial interface for the console |
| MAX202 | U14 | RS-232 level conversion for the user serial port |
| 74HC4040 | U8 | Divides the 14.7456 MHz local oscillator for peripheral timing |

The Z80 bus and the SIO/CTC register interface run from the platform's **10 MHz system clock**. The local 14.7456 MHz oscillator is a peripheral timing source; it is not the Z80 CPU clock. See [Clock Architecture](Clock%20Architecture.md) for the complete clock tree.

## I/O port map

The assembly constants are authoritative for software. The PLD decodes each device in a 16-port block, while the low address bits select the device registers used below.

| Function | Data port | Control port | Current owner |
| --- | ---: | ---: | --- |
| SIO0 channel A — user serial | `20h` | `21h` | Application |
| SIO0 channel B — console | `22h` | `23h` | BIOS |
| SIO1 channel A — bulk transport | `30h` | `31h` | Reserved for future bulk services |
| SIO1 channel B — IOCALL command transport | `32h` | `33h` | BIOS |
| CTC channel 0 | `40h` | — | Application |
| CTC channel 1 | `41h` | — | Application |
| CTC channel 2 | `42h` | — | Application |
| CTC channel 3 | `43h` | — | Application |

The full platform map is documented in [Memory Management](Memory%20Management.md). The constants used by CP/M are in [`platform_zephyr80.inc`](Code/HOST/CPM2.2/src/platform_zephyr80.inc).

## SIO0: asynchronous serial

### Channel B: BIOS console

SIO0/B is the BIOS-owned console and current Virtual Drip serial path.

- Interface: FT230XS USB serial
- Ports: `22h` data, `23h` control
- Format: 115200 baud, 8 data bits, no parity, 1 stop bit
- Serial clock: 1.8432 MHz in SIO x16 mode
- Flow control: RTS/CTS
- Receive path: interrupt-driven under IM 2
- Transmit path: foreground output with CTS polling

The BIOS owns this channel's initialization, interrupt vector, receive sink, and flow-control state. Applications should use the BIOS console entry points rather than reprogramming SIO0/B directly.

### Channel A: user serial

SIO0/A is the application-owned external serial channel.

- Interface: MAX202 RS-232 transceiver
- Ports: `20h` data, `21h` control
- Serial clock: CTC channel 0 output
- Baud rate: selected by the application's CTC and SIO configuration

The BIOS deliberately leaves SIO0/A and the CTC available to applications. Its serial path is present in the hardware design but is not part of the current CP/M console service.

## CTC: timing resources

The CTC register interface runs in the 10 MHz Z80 clock domain. Its external trigger inputs come from the local 14.7456 MHz oscillator divider:

| CTC channel | Trigger input | Typical role |
| --- | ---: | --- |
| 0 | 1.8432 MHz | Programmable baud clock for SIO0/A |
| 1 | 3.6864 MHz | Application timer/counter; output `TO1` is routed outward |
| 2 | 7.3728 MHz | Application timer/counter; output `TO2` is routed outward |
| 3 | 7.3728 MHz | General application timer/counter |

The current BIOS disables CTC interrupts during initialization and otherwise leaves the device application-owned. Software that enables CTC interrupts must install the corresponding IM 2 vectors and respect the board's interrupt daisy chain.

## SIO1: synchronous MCU link

SIO1 is not configured as a pair of asynchronous UARTs. It is the transport between the Z80 and the I/O-controller MCU.

| Channel | Ports | Purpose | Status |
| --- | --- | --- | --- |
| SIO1/A | `30h` / `31h` | Bulk data | Reserved; no active bulk-service ABI |
| SIO1/B | `32h` / `33h` | Commands and replies | Active IOCALL transport |

The current SIO1/B link uses **External Sync mode**:

- The MCU is the synchronous serial clock master.
- The MCU drives `/SYNCB` for the transaction.
- SIO1 operates at x1 clocking.
- `RTSB` is the Z80-to-MCU service-request signal.
- The link transfers transparent bytes; the SIO does not add an SDLC FCS.
- A `7Eh` software preamble provides byte alignment before each fixed frame.
- Phase 1 transfers are foreground-polled and have timeouts.
- SIO1/B interrupts, DMA-style block instructions, and WAIT/READY handshaking are not used.

Although SDLC influenced the hardware design, it is not the active protocol. On this board `/SYNCB` is MCU-owned and also participates in buffer gating, so a SIO mode that drives `/SYNCB` would cause contention. External Sync keeps that signal an input at the SIO.

The detailed wire protocol and bring-up behavior are documented in [`external_sync_protocol.md`](Code/MCU/IOController/docs/external_sync_protocol.md).

## IOCALL programming interface

The CP/M BIOS exposes the command transport through IOCALL:

- `HL` points to the 32-byte request frame.
- `DE` points to the 32-byte reply frame.
- `A` returns the transport result.

IOCALL initializes SIO1/B for the transaction, asserts the request, exchanges one fixed request/reply pair, releases the link, and returns. The BIOS transport does not interpret the command payload.

### Fixed frame

Every command-channel request and reply is exactly 32 bytes.

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | Command or response class |
| 1 | 1 | Sequence number |
| 2 | 1 | Command status or flags |
| 3 | 1 | Payload length |
| 4 | 16 | Payload |
| 20 | 12 | Reserved or command-specific |

Transport errors and MCU command status are separate:

- IOCALL returns a transport result such as success, timeout, bad frame, or hardware error in `A`.
- The MCU reports command-level status in byte 2 of a valid reply frame.

The shared host constants are in [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc), and the MCU definition is in [`ioc_frame.h`](Code/MCU/IOController/include/ioc_frame.h).

### Implemented commands

| Request | Value | Reply/behavior |
| --- | ---: | --- |
| `PING` | `01h` | Returns `RSP_PING` (`81h`) and echoes the request metadata/payload |
| `RESET` | `02h` | Asserts the host reset pair, then resets the MCU; a normal reply is not guaranteed |
| Unknown command | — | Returns `RSP_UNKNOWN_COMMAND` (`FEh`) with unknown-command status |

The controller also asserts the host reset pair for approximately 100 ms during its own startup.

## Interrupt ownership and priority

The board's hardware daisy chain is:

`bus IEI → CTC → SIO0 → SIO1 → bus IEO`

This establishes hardware priority, not automatic software ownership. In the current CP/M implementation:

- SIO0/B receive is the active BIOS-managed IM 2 interrupt source.
- SIO0/A and CTC interrupts belong to application software if enabled.
- SIO1/B IOCALL is polled during Phase 1 and does not generate service interrupts.
- SIO1/A does not yet expose an active bulk-transfer service.

Any future unsolicited keyboard, mouse, or controller events will need an explicit interrupt and buffering ABI. The obsolete two-byte HID record proposal is not that ABI.

## Current status and future scope

| Capability | Status |
| --- | --- |
| SIO0/B USB-serial console | Implemented and BIOS-owned |
| SIO0/A programmable user serial | Hardware path present; application-owned |
| CTC application timing | Available |
| SIO1/B fixed-frame `PING` | Implemented for bring-up |
| MCU-controlled reset | Implemented |
| SIO1/A bulk transport | Reserved, not yet exposed |
| SD-card block service | Planned; no current host ABI |
| USB HID service | Planned; no current event ABI |
| Unsolicited GameOS-style events | Planned; not part of Phase 1 IOCALL |

Consequently, the former 512-byte SD-sector command stream, two-byte HID records, and separate 460.8 kbaud MCU UART are historical proposals and must not be used as implementation references.

## Sources of truth

When the documentation, schematic annotations, and software disagree, use these sources in this order:

1. Host port and register constants in [`platform_zephyr80.inc`](Code/HOST/CPM2.2/src/platform_zephyr80.inc).
2. IOCALL definitions and transport code in [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc) and [`cbios_iocall.asm`](Code/HOST/CPM2.2/src/cbios_iocall.asm).
3. MCU protocol definitions and firmware under [`Code/MCU/IOController`](Code/MCU/IOController).
4. The current KiCad I/O-controller schematic and its validation notes.
