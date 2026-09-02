# Zephyr-80 Peripheral Controller Architecture

This document describes the current Zephyr-80 I/O board and its software-visible interfaces as implemented by the CP/M BIOS and the IO Controller firmware.  It replaces the earlier proposal in which a microcontroller exposed separate asynchronous UART streams for SD storage and USB HID.

The authoritative implementation has four distinct software-visible parts:

- **SIO0** provides the conventional asynchronous serial interfaces.
- **CTC** supplies programmable timing and application timers.
- **SIO1/B** is the command lane used by the Zephyr extended BIOS `IOCALL` entry.
- **SIO1/A** is the bulk lane used by `IOCBULK` and `IOCBULKW` after command-lane admission.

The committed I/O-board design uses a **PIC18F57Q84** as the I/O controller.  The current firmware is no longer only a PING/reset bring-up target: it also contains SD-card, bulk-transfer, cache, profile, link-sync, and HID status/input handlers.  Unsolicited GameOS-style event delivery remains future work; HID input is currently command-polled.

## Hardware overview

| Device | Designator | Role |
| --- | --- | --- |
| Z80 CTC | IC1 | Programmable timing, baud-clock generation, and application timers |
| Z80 SIO/0 | IC2 (SIO0) | Asynchronous console and user serial channels |
| Z80 SIO/0 | IC3 (SIO1) | Synchronous MCU command and bulk-data lanes |
| PIC18F57Q84 | U15 | I/O controller and synchronous-clock master |
| 74AHCT125 | U1 | Gating/buffering between SIO1 and the MCU |
| FT230XS | U7 | USB serial interface for the console |
| MAX202 | U14 | RS-232 level conversion for the user serial port |
| 74HC4040 | U8 | Divides the 14.7456 MHz local oscillator for peripheral timing |

The Z80 bus and the SIO/CTC register interface run from the platform's **10 MHz system clock**.  The local 14.7456 MHz oscillator is a peripheral timing source; it is not the Z80 CPU clock.  See [Clock Architecture](Clock%20Architecture.md) for the complete clock tree.

## I/O port map

The assembly constants are authoritative for software.  The PLD decodes each device in a 16-port block, while the low address bits select the device registers used below.

| Function | Data port | Control port | Current owner |
| --- | ---: | ---: | --- |
| SIO0 channel A — user serial | `20h` | `21h` | Application |
| SIO0 channel B — console | `22h` | `23h` | BIOS |
| SIO1 channel A — bulk lane | `30h` | `31h` | BIOS transport via `IOCBULK` / `IOCBULKW` |
| SIO1 channel B — command lane | `32h` | `33h` | BIOS transport via `IOCALL` |
| CTC channel 0 | `40h` | — | Application |
| CTC channel 1 | `41h` | — | Application |
| CTC channel 2 | `42h` | — | Application |
| CTC channel 3 | `43h` | — | Application |

The full platform map is documented in [Memory Management](Memory%20Management.md).  The constants used by CP/M are in [`platform_zephyr80.inc`](Code/HOST/CPM2.2/src/platform_zephyr80.inc) and [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc).

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

The BIOS owns this channel's initialization, interrupt vector, receive sink, and flow-control state.  Applications should use the BIOS console entry points rather than reprogramming SIO0/B directly.

### Channel A: user serial

SIO0/A is the application-owned external serial channel.

- Interface: MAX202 RS-232 transceiver
- Ports: `20h` data, `21h` control
- Serial clock: CTC channel 0 output
- Baud rate: selected by the application's CTC and SIO configuration

The BIOS deliberately leaves SIO0/A and the CTC available to applications.  Its serial path is present in the hardware design but is not part of the current CP/M console service.

## CTC: timing resources

The CTC register interface runs in the 10 MHz Z80 clock domain.  Its external trigger inputs come from the local 14.7456 MHz oscillator divider:

| CTC channel | Trigger input | Typical role |
| --- | ---: | --- |
| 0 | 1.8432 MHz | Programmable baud clock for SIO0/A |
| 1 | 3.6864 MHz | Application timer/counter; output `TO1` is routed outward |
| 2 | 7.3728 MHz | Application timer/counter; output `TO2` is routed outward |
| 3 | 7.3728 MHz | General application timer/counter |

The current BIOS disables CTC interrupts during initialization and otherwise leaves the device application-owned.  Software that enables CTC interrupts must install the corresponding IM 2 vectors and respect the board's interrupt daisy chain.

## SIO1: synchronous MCU transport

SIO1 is not configured as asynchronous serial.  It is a two-lane MCU-clocked transport:

| Lane | SIO channel | Ports | Normal caller API | Purpose |
| --- | --- | --- | --- | --- |
| Command | SIO1/B | `32h` / `33h` | `IOCALL` | 32-byte BIOS-facing command mailbox mapped to one command packet |
| Bulk | SIO1/A | `30h` / `31h` | `IOCBULK` / `IOCBULKW` | DATA-only transfer admitted by a command reply |

Both lanes use **persistent External Sync**:

- The MCU is the synchronous serial clock master.
- The MCU drives `/SYNCA` and `/SYNCB`; External Sync keeps the SIO pins as inputs and avoids contention.
- The MCU clocks only during selected transfer windows.
- The gated SIO clocks idle high.
- SIO clock windows must contain whole-byte clock counts once sync is established.
- Auto Enables are off on the SIO1 transport lanes.
- SIO Wait/Ready block-transfer mode is not used by the current BIOS path.
- SIO1 command and bulk byte loops are foreground-polled; SIO1 interrupts are not part of the current CP/M transport.

Although SDLC influenced the hardware design, SDLC, Monosync, and Bisync are not the active modes.  On this board `/SYNCA` and `/SYNCB` are MCU-owned nets and also participate in buffer gating, so a SIO mode that drives `/SYNC` would cause contention.

### Common wire packet

Both SIO1 lanes and both directions use the same wire envelope:

```text
A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
```

`LEN` is little-endian and counts `TYPE + SEQ + STATUS + DATA`.  The CRC is CRC-16-CCITT with polynomial `1021h`, initial value `0000h`, MSB-first processing, and no final XOR.  It covers `LEN_LO` through the final DATA byte; it does not cover the `A5 5A` marker.  The CRC bytes are transmitted high byte first.

The Command lane carries up to 26 DATA bytes because it maps to the existing 32-byte BIOS-facing command mailbox.  The Bulk lane carries up to 512 DATA bytes so one SD sector can be represented as one bulk packet.

There is no 32-byte scheduling quantum on the wire.  The 32-byte object is the BIOS-facing command mailbox only.

### Command-lane handshake

The Command lane uses these sideband signals:

| Signal | Direction | Meaning in the current implementation |
| --- | --- | --- |
| `/RTSB` / `/SIO1B_INT` | Z80 SIO → MCU | Held-low acknowledged request: the host has one outstanding command request |
| `/DCDB` | MCU → Z80 SIO | `COMMAND_READY`: MCU is idle and will accept one command |
| `/SYNCB` | MCU → Z80 SIO | External Sync/framing input for SIO1/B |
| `/SIOB_CS` | MCU output | Selects SIO1/B onto the shared SIO bus |

Current request admission is level-based, not edge-based.  The PIC firmware globally disables interrupts and polls `/SIO1B_INT` in the foreground loop.  `COMMAND_READY` on `/DCDB` is asserted only while the controller is in command-idle.  The host waits for `COMMAND_READY`, prepares the packet, and asserts `/RTSB` only when the controller says it is ready.

`/RTSB` means **an unacknowledged request exists**, not **the full transaction is active**.  The BIOS releases `/RTSB` after the request frame has left the SIO shift path and before waiting for the reply.  The MCU services the request, positively observes that release, dispatches the command, and then sends the reply.  If the request fails to decode, the MCU sends no reply; the host times out with `/RTSB` already released instead of causing repeated junk windows.

### Bulk lifecycle

Large operations use the READY/BULK/DONE lifecycle:

```text
command request
    -> READY(id, direction, DATA length)
    -> one common packet on SIO1/A
    -> DONE(id, status), when required
```

The command request, READY reply, and DONE reply all travel on SIO1/B.  SIO1/A carries only the admitted bulk DATA packet.  The Bulk lane is not an unframed pipe, and the host does not send SD commands over SIO1/A.

For MCU-to-Z80 bulk traffic, the host calls `IOCBULK`, keeps RX enabled, drains only a bounded amount of stale receive pipeline, asserts `/RTSA`, then receives a common packet from SIO1/A.  For Z80-to-MCU bulk traffic, the host calls `IOCBULKW`, streams a common packet to SIO1/A after admission, and then uses the command lane to query completion status when required.

The MCU holds admission for the whole bulk phase.  Bulk byte loops mask Z80 interrupts for the bounded stream because the MCU clock does not pause.

### Link recovery

Normal packet errors do not reset the SIO receiver.  `CMD_LINK_SYNC` is the explicit recovery operation.  It releases both `/SYNC` inputs, clears host and MCU established flags, and causes the next transfer on each lane to re-establish External Sync.  Both lanes are resynchronized together so command metadata and an optional bulk phase cannot disagree about link generation.

The detailed transport notes are in [`two-lane-transport.md`](Code/MCU/IOController/docs/two-lane-transport.md), with lower-level bring-up detail in [`external_sync_protocol.md`](Code/MCU/IOController/docs/external_sync_protocol.md).

## Zephyr extended BIOS transport entries

The CP/M BIOS exposes the IO Controller transport through Zephyr-specific extended BIOS entries.  These are not standard CP/M BIOS calls.

| Entry | Purpose |
| --- | --- |
| `IOCALL` | Send one 32-byte command mailbox and receive one 32-byte reply mailbox on SIO1/B |
| `IOCBULK` | Receive DATA on SIO1/A after a command-lane READY admission |
| `IOCBULKW` | Transmit DATA on SIO1/A after a command-lane READY admission |

### `IOCALL`

Current `IOCALL` calling convention:

```text
In:
  HL = pointer to caller-owned 32-byte TX frame in visible application RAM
  DE = pointer to caller-owned 32-byte RX frame buffer in visible application RAM

Out:
  A  = BIOS transport result
```

The caller owns both command mailboxes.  The BIOS does not reserve a persistent application-visible IOCALL request block, payload buffer, or command-specific state for callers.  The BIOS does maintain internal transport scratch state, sequence state, and packet assembly state.

`IOCALL` stamps the outgoing sequence byte, maps the 32-byte TX mailbox to the common wire packet, supplies the wire CRC, receives a validated reply packet, checks the reply sequence, and maps the reply back into the caller's RX mailbox.  It does not interpret whether a command means PING, RESET, SD, HID, or anything else.

Command mailbox layout:

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 1 | Class / command / response type |
| 1 | 1 | Sequence number, stamped by transport |
| 2 | 1 | Status / flags |
| 3 | 1 | DATA length |
| 4 | 26 | DATA |
| 30 | 2 | Reserved |

Transport errors and MCU command status are separate:

- `IOCALL` returns a transport result such as success, timeout, bad frame, bad CRC, bad sequence, not-ready, or hardware error in `A`.
- The MCU reports command-level status in mailbox byte 2 of a valid reply frame.

The shared host constants are in [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc), and the MCU definition is in [`ioc_frame.h`](Code/MCU/IOController/include/ioc_frame.h).

## Implemented command dispatch

The current MCU command dispatcher recognizes these command classes:

| Command | Value | Notes |
| --- | ---: | --- |
| `CMD_PING` | `01h` | Returns `RSP_PING` (`81h`) and echoes sequence/status/length/payload metadata |
| `CMD_RESET` | `02h` | Asserts the host reset pair and resets the MCU; does not normally return |
| `CMD_SD_READ` | `03h` | Command-lane SD read diagnostic; returns a small payload |
| `CMD_BULK_TEST` | `04h` | Bulk-lane ramp/test path |
| `CMD_SD_READ_BULK` | `05h` | SD block read using READY -> `IOCBULK` |
| `CMD_XFER_STATUS` | `06h` | Query transfer completion/diagnostic state |
| `CMD_SD_WRITE_BULK` | `07h` | SD block write using READY -> `IOCBULKW` -> DONE |
| `CMD_SD_READ_REC` | `08h` | 128-byte record read through the SD cache |
| `CMD_SD_WRITE_REC` | `09h` | 128-byte record write through the SD cache |
| `CMD_SD_FLUSH` | `0Ah` | Flush dirty SD-cache state |
| `CMD_PROFILE` | `0Bh` | Profiling/diagnostic page query |
| `CMD_LINK_SYNC` | `0Ch` | Explicit persistent-sync recovery |
| `CMD_HID_STATUS` | `0Dh` | HID/USB status and diagnostic pages |
| `CMD_HID_INPUT` | `0Eh` | Nonblocking dequeue of translated keyboard/input bytes |
| Unknown command | — | Returns the unknown-command handler reply |

Exact payload layouts and response classes are defined in [`ioc_frame.h`](Code/MCU/IOController/include/ioc_frame.h).  SD and HID command handlers live in the MCU firmware; the CP/M BIOS storage layer uses the command and bulk entries as transport rather than programming SIO1 directly.

## Interrupt ownership and priority

The board's hardware daisy chain is:

```text
bus IEI → CTC → SIO0 → SIO1 → bus IEO
```

This establishes hardware priority, not automatic software ownership.  In the current CP/M implementation:

- SIO0/B receive is the active BIOS-managed IM 2 interrupt source.
- SIO0/A and CTC interrupts belong to application software if enabled.
- SIO1 command and bulk transports are polled and do not currently generate Z80 service interrupts.
- The PIC firmware also runs the command path from its foreground loop with global interrupts disabled; `/SIO1B_INT` is sampled as a level.

Any future unsolicited keyboard, mouse, controller, or GameOS executive event delivery will need an explicit interrupt and buffering ABI.  Current HID input is exposed by command polling through `CMD_HID_INPUT`, not by MCU-initiated SIO event packets.

## Current status and future scope

| Capability | Status |
| --- | --- |
| SIO0/B USB-serial console | Implemented and BIOS-owned |
| SIO0/A programmable user serial | Hardware path present; application-owned |
| CTC application timing | Available; BIOS leaves it application-owned |
| SIO1/B `IOCALL` command lane | Implemented |
| SIO1/A `IOCBULK` / `IOCBULKW` bulk lane | Implemented |
| Common packet marker/length/sequence/status/CRC transport | Implemented |
| Persistent External Sync on both SIO1 lanes | Implemented |
| MCU-controlled reset | Implemented |
| SD-card command, bulk, record, and cache paths | Implemented in firmware and used by the CP/M storage path |
| USB HID status and nonblocking input commands | Implemented as command-polled services |
| SIO Wait/Ready block-transfer optimization | Future optimization; current path is polled |
| Unsolicited GameOS-style events | Planned; not part of the current CP/M transport ABI |

Consequently, the former separate 460.8 kbaud MCU UART, unframed SD-sector stream, two-byte HID record stream, and raw SIO1/A readers are historical proposals and must not be used as implementation references.

## Sources of truth

When the documentation, schematic annotations, and software disagree, use these sources in this order:

1. Host port and register constants in [`platform_zephyr80.inc`](Code/HOST/CPM2.2/src/platform_zephyr80.inc) and [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc).
2. Command mailbox and command-lane transport code in [`cbios_iocall.asm`](Code/HOST/CPM2.2/src/cbios_iocall.asm) and [`cbios_ioc_command.asm`](Code/HOST/CPM2.2/src/cbios_ioc_command.asm).
3. Host bulk transport code in [`cbios_ioc_command.asm`](Code/HOST/CPM2.2/src/cbios_ioc_command.asm) and the `IOCBULK` / `IOCBULKW` entry points.
4. MCU protocol definitions and firmware under [`Code/MCU/IOController`](Code/MCU/IOController), especially [`ioc_frame.h`](Code/MCU/IOController/include/ioc_frame.h), [`external_sync.c`](Code/MCU/IOController/src/external_sync.c), [`bulk_channel.c`](Code/MCU/IOController/src/bulk_channel.c), and [`dispatch.c`](Code/MCU/IOController/src/dispatch.c).
5. The current KiCad I/O-controller schematic and its validation notes.
