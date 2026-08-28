# External Sync implementation notes

The authoritative transport contract is
[two-lane-transport.md](two-lane-transport.md). This file records the
wire-level rules that are easy to break while changing timing code.

## SIO rules

In Z80 SIO External Sync mode, the external `/SYNC` input establishes character
alignment. The SIO manual says character assembly then continues until SIO
reset, receiver disable (by command or by `/DCD` under Auto Enables), or Enter
Hunt Phase.

Therefore, after a lane has accepted its first CRC-valid receive:

- do not reset that SIO channel;
- do not clear WR3 receiver enable;
- keep WR3 Auto Enables off;
- do not issue Enter Hunt; and
- keep `/SYNC` low.

Clock gaps are allowed. Every selected steady-state window must contain a
multiple of eight rising edges.

## One-time establishment

At reset, `/SYNCA` and `/SYNCB` idle high and each host receiver is in Hunt. On
the first MCU-to-Z80 transfer for a lane, the MCU:

1. selects the lane with SCK already parked high;
2. emits the proven setup-clock shape;
3. hand-clocks a disposable `FFh` byte and drops that lane's `/SYNC` inside it;
4. sends the complete packet, beginning `A5 5A`, through SPI2; and
5. leaves `/SYNC` low.

The setup clocks and hand-clocked byte are not repeated. It is never parsed as
part of a packet. Later packets send all bytes through SPI2.

The measured drop positions are channel-specific: bit 1 for SIO1/B and bit 0
for SIO1/A. Protocol level 7 deliberately makes the establishing byte
disposable, then sends a complete aligned marker. This parameter therefore
cannot remove or corrupt marker byte zero.

## Idle-high clocking

Each SIO clock passes through a selected 74AHCT125 output and has a pull-up.
SPI2 and the LAT bit-bang path must both idle SCK high before a select or PPS
handover. Otherwise gate release creates a false low-to-high transition at the
SIO clock input.

The historical command failure produced two such transitions per transaction,
so persistent alignment advanced two bits and PING succeeded once per four
attempts. SPI2 now uses `CKP = 1`; `sio_link_pins_to_lat()` and each select path
park the same high level.

## Packet and CRC

```text
A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
```

CRC parameters are polynomial `1021h`, init `0000h`, MSB-first, no final XOR.
Coverage starts at `LEN_LO` and ends at the last DATA byte. The implementation
uses software CRC on the PIC and Z80.

Hardware SIO CRC is deliberately deferred. Its receive result is tied to FIFO
and trailing-clock timing, while transmit completion needs the underrun/EOM
sequence. Software CRC proves the common wire contract without adding those
state-machine dependencies; a future hardware-CRC optimization must preserve
the exact bytes and acceptance rules.

## Command receive, Z80 to MCU

The MCU captures 36 bytes and scans `A5 5A` at arbitrary bit positions. It
tries the last CRC-valid position first, then scans the bounded window. A
candidate is accepted only if length, request TYPE, request STATUS, bounds, and
CRC all validate.

The capture length is a clock window, not a fixed packet size. The longest
Command packet is 35 bytes, leaving one byte of start margin.

## MCU to Z80 receive pipeline

After every MCU-to-Z80 packet, the MCU clocks one trailing `FFh`. The SIO needs
later clocks to expose the preceding final packet byte. The trailer can itself
remain internal and surface at the start of the next transfer.

Both host receive paths therefore:

- reset error latches without disabling RX;
- drain no more than the hardware FIFO depth;
- wait for software admission;
- scan for both marker bytes; and
- parse declared length before DATA and CRC.

Removing the trailer loses the packet's CRC low byte. Treating FIFO byte zero
as packet byte zero prepends stale `FFh` and drops the last DATA byte. Marker
scan is what makes both facts harmless.

## Bulk admission

Auto Enables is off. The PIC owns the clock gate, so `/DCDA` and `/CTSA` are
software admission levels rather than hardware receiver/transmitter gates.

- MCU-to-Z80: `/DCDA` is asserted, held for 100 us, and remains asserted for
  the packet.
- Z80-to-MCU: `/CTSA` is asserted, held for 100 us, and remains asserted
  through validation and commit.

The host polls before entering its byte loop. Since the clock gate is closed
until after admission, the MCU's 1 ms RTS polling cannot allow an early host
byte onto the wire.

## Explicit recovery

`CMD_LINK_SYNC` resets the protocol's established state for both lanes. It is
the only normal operation permitted to release `/SYNC`, re-enter Hunt, and
repeat the setup clocks. Ordinary timeout, CRC failure, FIFO overrun, or idle
clock stop does not automatically destroy the established boundary.
