# Zephyr-80 IOC two-lane transport

## Status

This document describes the implemented transport paired by:

- controller firmware level `15h` (`IOC_FW_LEVEL = 21`); and
- BIOS transport level `07h` (`ZBIOS_XPORT_LEVEL = 7`).

SIO1/B is the Command lane and SIO1/A is the Bulk lane. Both use the same
packet envelope, CRC, sequence semantics, packet-marker scan, and persistent
External Sync discipline. Their intended traffic and maximum DATA lengths
differ.

| Property | Command lane | Bulk lane |
|---|---:|---:|
| SIO channel | SIO1/B | SIO1/A |
| BIOS data/control ports | `32h` / `33h` | `30h` / `31h` |
| Packet format | common | common |
| Maximum DATA | 26 bytes | 512 bytes |
| External Sync | persistent | persistent |
| Auto Enables | off | off |
| Normal caller API | `IOCALL` mailbox | `IOCBULK` / `IOCBULKW` DATA buffer |

The two lanes share the MCU SPI2 clock/data pins and cannot operate
concurrently. One logical operation owns the controller transport through its
command, optional bulk phase, and completion status.

## Common wire packet

Both directions on both lanes use:

```text
A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
```

`LEN` is little-endian and counts `TYPE + SEQ + STATUS + DATA`. Its minimum is
3. The CRC is CRC-16-CCITT with polynomial `1021h`, initial value `0000h`,
MSB-first processing, and no final XOR. It covers `LEN_LO` through the final
DATA byte; it does not cover `A5 5A`.

The CRC bytes are transmitted high byte first. Packet acceptance requires all
of the following:

1. `A5 5A` found within the lane's bounded scan window;
2. declared length within the lane limit;
3. expected TYPE and SEQ;
4. valid STATUS for that direction; and
5. matching CRC.

A coincidental `A5 5A` inside DATA is therefore harmless. It cannot be accepted
unless the length, metadata, and CRC also form a valid candidate.

### BIOS compatibility mailbox

Command callers retain the existing 32-byte API:

```text
0       TYPE
1       SEQ
2       STATUS
3       DATA length
4..29   DATA (maximum 26 bytes)
30..31  reserved
```

`IOCALL` stamps SEQ, builds the wire header and CRC, receives and validates the
reply packet, then maps it back to the mailbox. The mailbox is not sent as a
raw 32-byte wire object, and bytes 30/31 do not contain the wire CRC.

Bulk callers pass DATA only. `IOCBULK` and `IOCBULKW` own the marker, header,
metadata binding, CRC, SIO programming, RTS, and admission signals.

## Persistent External Sync

The SIO manual states that Monosync, Bisync, and External Sync character
assembly continues until one of three events:

1. SIO reset;
2. receiver disable, either by command or by `/DCD` under Auto Enables; or
3. Enter Hunt Phase.

The implementation therefore enforces four invariants on each lane:

1. `/SYNC` starts high, falls once inside a disposable hand-clocked byte, and
   remains low;
2. the two setup clocks and hand-clocked establishing byte run only once;
3. the BIOS issues Enter Hunt only before the first verified receive; and
4. the receiver remains enabled after establishment.

Clocking may stop between packets. Once established, every selected window must
contain a whole-number multiple of eight clocks so the SIO's character counter
does not walk.

Auto Enables (`WR3.D5`) is off on both lanes. `/DCD` and `/CTS` are status
inputs only; they never enable or disable the receiver or transmitter in
hardware.

The measured establishing timing differs by one bit between the physical SIO
channels: `/SYNCB` drops after establishing-byte bit 1 and `/SYNCA` after bit 0.
The byte is not part of a packet. Both lanes then transmit the complete aligned
`A5 5A` marker through SPI, so this physical parameter cannot alter framing.

## Clock idle level

The gated SIO clocks have pull-ups. SPI2 therefore uses idle-high clocking
(`CKP = 1`), and the LAT/PPS handover parks SCK high before either select is
changed.

This is required for persistent alignment. With SPI idling low, releasing each
74AHCT125 clock gate changed the SIO clock from driven low to pulled high. The
SIO counted one extra rising edge at each of the two gate releases in a command
transaction, causing the historical two-bit drift and one successful PING in
four. See [ping-two-bit-drift-root-cause.md](ping-two-bit-drift-root-cause.md).

## Command transaction

The host waits for `/DCDB` (COMMAND_READY), prepares its packet, and asserts
`/RTSB`. The MCU captures a bounded 36-byte request window. Requests are found
at arbitrary bit phase and are dispatched only after full CRC validation.

The host releases `/RTSB` after the request has left the shift register, keeps
its receiver enabled, drains at most the SIO FIFO depth of stale full-duplex
bytes, and scans for the reply marker. The MCU delays briefly for turnaround,
then sends the reply packet plus one `FFh` pipeline byte.

`/RTSB` means “an unacknowledged request exists.” It is a held level, not an
edge that the MCU must happen to sample.

## Bulk lifecycle and admission

Large operations retain the compatibility lifecycle:

```text
command request
    -> READY(id, direction, DATA length)
    -> one common packet on SIO1/A
    -> DONE(id, status), when required
```

The command request and the READY/DONE replies all travel on SIO1/B, the
Command lane.  SIO1/A carries only the framed bulk packet for the admitted
phase.  The host does not send an SD command over SIO1/A and wait for its reply
on that same lane.

READY provides the TYPE/SEQ context that the BIOS binds to the bulk packet.
The Bulk lane is not an unframed pipe.

For MCU-to-Z80 traffic:

1. `IOCBULK` keeps RX enabled, drains at most the three-byte FIFO, and asserts
   `/RTSA`;
2. the MCU observes `/RTSA`, asserts `/DCDA`, waits 100 us, then opens the clock
   gate;
3. the BIOS polls `/DCDA`, scans `A5 5A`, checks metadata, receives DATA and
   CRC, and releases RTS.

For Z80-to-MCU traffic:

1. `IOCBULKW` preloads a disposable lead-in byte before asserting RTS;
2. the MCU observes RTS, asserts `/CTSA`, waits 100 us, then opens the clock
   gate;
3. the BIOS polls `/CTSA` and streams the common packet;
4. the MCU bit-scans for `A5 5A`, validates the complete packet, commits DATA,
   then releases `/CTSA`.

The MCU holds admission for the whole phase. Software polls once before the
stream and the signal does not drop mid-packet. Because the MCU owns the clock
and keeps the clock gate closed until after admission, the host cannot start on
the wire before the MCU is listening.

Bulk byte loops mask interrupts for the bounded stream because the MCU clock
does not pause. That prevents RX overrun and TX underrun from depending on ISR
duration. Card I/O happens outside the MCU-to-Z80 byte stream. Z80-to-MCU writes
always query DONE because receiving DATA does not prove the SD commit succeeded.

## Future optimization: SIO `/WAIT` block transfer

The board connects the `W/~RDYA` and `W/~RDYB` outputs of both SIO chips to the
CPU `/WAIT` net.  The current BIOS deliberately leaves the SIO Wait/Ready
function disabled and polls RR0 before each payload byte.  On the successful
receive path that loop costs about 56 T-states per byte at 10 MHz.

The SIO supports a CPU block-transfer mode that can replace the RR0 loop:

- configure WR1 for **Wait**, never Ready;
- select receive-Wait for `IOCBULK` and transmit-Wait for `IOCBULKW`;
- execute `INIR` or `OTIR`; and
- let the SIO stretch each data-port I/O cycle until its receive or transmit
  buffer is ready.

A repeating Z80 `INIR`/`OTIR` iteration costs about 21 T-states before inserted
wait states, versus the current 56-T-state poll-and-transfer loop.  WR1 does not
disable the receiver or issue Enter Hunt, so using Wait need not disturb
persistent External Sync.

There are two non-negotiable constraints:

1. All four SIO W/RDY outputs share one net.  Wait mode is open-drain and is
   compatible with that wired connection; Ready mode actively drives both
   levels and must never be enabled.  Wait/Ready must remain disabled on every
   SIO channel except the one performing the current block operation.
2. Once the SIO holds `/WAIT` low, software cannot run a timeout.  If the MCU
   stops producing or consuming clocks halfway through a block, the CPU can
   remain trapped in that I/O cycle until hardware reset.  The existing polled
   loop is slower but recoverable.

Treat this as a transport optimization, not an SD optimization.  Prove it first
in a standalone Bulk diagnostic at the existing clock and pacing, then test
removing the payload gap and raising the clock in separate steps.  Do not change
the BIOS path until receive-Wait and transmit-Wait have each passed packet CRC,
persistent-sync, interrupt-load and failure-recovery testing.

## The SIO receive pipeline

The SIO exposes its final received character only after later clocks. The MCU
sends a trailing `FFh` after MCU-to-Z80 packets to make the CRC low byte
readable. That `FFh` can remain in the SIO's internal receive pipeline and
become FIFO-visible only when the next transfer begins.

Consequences:

- a receiver must never assume FIFO byte zero is DATA;
- error reset does not empty the receive FIFO;
- draining must be bounded, because an unbounded drain can consume a new
  packet; and
- every receive path scans the complete `A5 5A` marker before parsing.

This explains the historical SDREC buffer `FF 00 01 02 ...`: the bytes were
character-aligned, but an old raw-bulk reader accepted the promoted pipeline
byte as payload byte zero and lost the final DATA byte. See
[bulk-persistent-sync-pipeline-root-cause.md](bulk-persistent-sync-pipeline-root-cause.md).

## Recovery

Normal packet errors do not reset either SIO receiver. `CMD_LINK_SYNC` is the
explicit recovery operation. It releases both `/SYNC` inputs, clears the host
and MCU “established” flags, and causes the next transfer on each lane to use
Enter Hunt plus the one-time establishing clocks.

Both lanes are resynchronized together so command metadata and an optional
bulk phase cannot disagree about link generation.

## Deliberate differences from the original proposal

The implementation follows the proposal's single-protocol and persistent-sync
design, with these compatibility choices:

- STATUS is an explicit fixed header byte;
- command DATA is limited to 26 bytes by the existing mailbox API;
- bulk DATA remains 512 bytes so one SD sector needs one packet;
- CRC is currently software-computed rather than using the SIO/PIC CRC engines;
- READY/BULK/DONE is retained for the existing BIOS and storage lifecycle; and
- host-to-MCU receive still performs bounded bit-phase search because the MCU
  supplies clocks but cannot assume the Z80 transmitter's starting phase.

There is no 32-byte scheduling quantum on the wire.

Protocol level 7 also separates sync establishment from packet marking. Earlier
level 6 used hand-clocked `A5h` as both the `/SYNC` carrier and marker byte zero.
That worked on channel B but channel A's earlier measured `/SYNC` drop did not
deliver a reliable `A5h`, so the host saw no `A5 5A` pair and returned transport
error `02`. The disposable-byte design removes that channel-specific coupling.

## Diagnostic contract

Normal diagnostics must use BIOS transport entry points and must not program
SIO1/A or SIO1/B directly.

| Tool | Path exercised | Persistent-sync safe |
|---|---|---|
| `PING.COM` | Command packet, version/edge diagnostics | yes |
| `BULK.COM` | READY plus `IOCBULK`, ramp and CRC | yes |
| `SDREAD.COM` | Command-only SD read | yes |
| `SDBLK.COM` | 512-byte bulk read | yes |
| `SDWRT.COM` | 512-byte bulk write plus DONE | yes, destructive to block 0 |
| `SDREC.COM` | 128-byte cached record read/write/flush | yes, destructive test records |
| `SDSOAK.COM` | repeated bulk write/read/verify | yes, destructive test LBAs |
| `SDBENCH.COM` | timed raw CMD17/CMD24 read/write flood at LBA `00100000h` | yes, destructive to that LBA |
| `SDFMT.COM` | record writes plus flush | yes, destructive directory format |
| `RESET.COM` | command request followed by reset | terminal by design |
| `RTSPROBE.COM` | direct WR5 electrical probe | **no; cold boot afterward** |

`PING`, `SDREC`, `SDSOAK`, `SDBENCH`, and `SDFMT` reject mismatched
BIOS/controller protocol levels. `RTSPROBE` is intentionally outside the
protocol and may invalidate the SIO state.

## Source map

- MCU packet constants: `include/ioc_frame.h`
- MCU Command transport: `src/external_sync.c`
- MCU Bulk transport: `src/bulk_channel.c`
- BIOS constants and SIO values: `src/cbios_defs.inc`
- BIOS common packet and Bulk routines: `src/cbios_ioc_command.asm`
- BIOS command mailbox entry: `src/cbios_iocall.asm`
