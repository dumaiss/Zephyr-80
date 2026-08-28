# SDREC bulk failure after persistent External Sync

## Root cause

The failing SDREC read was not a bit-alignment failure. The Z80 SIO receive
pipeline retained the MCU's trailing `FFh` flush byte from the preceding
MCU-to-Z80 packet. Later Bulk clocks promoted that stale character into the
receive FIFO before the new payload. The old Bulk reader assumed FIFO byte zero
was payload byte zero, so it returned:

```text
FF 00 01 02 03 04 05 06 ...
```

instead of:

```text
00 01 02 03 04 05 06 07 ...
```

The stale byte was prepended and the last real DATA byte was dropped. CRC then
failed even though the new ramp itself was byte-aligned and intact.

## Evidence

The reported buffer is decisive:

- every ramp byte after the leading `FFh` has the expected whole-byte value;
- there is no rotating-bit pattern such as `80 00 81 01 ...`;
- one old byte appears at the head and exactly one new byte is absent at the
  tail; and
- the result persists deterministically because each transfer leaves the next
  pipeline byte in the same state.

A wrong External Sync bit boundary would rotate or combine adjacent bytes. It
would not preserve an exact `00 01 02 ...` sequence after one inserted byte.

## Why the trailer exists

On the SIO receive side, the last shifted character is not necessarily visible
in the CPU-readable FIFO as soon as its eighth clock arrives. Further clocks
advance the internal receive pipeline. The MCU therefore clocks one `FFh` after
CRC low so the host can read the complete packet.

That solves the current packet but leaves the trailer as the newest internal
character. When the next selected window supplies clocks, it can become the
first FIFO-visible byte.

The trailer cannot simply be removed: doing so can hide the CRC low byte.
Resetting or disabling the receiver to clear it is also invalid because the SIO
manual identifies receiver disable as one of the events that destroys External
Sync character assembly.

## Why persistence exposed it

The previous Bulk implementation disabled/reinitialized the receiver and
re-established sync per transfer. That happened to discard or hide pipeline
state. It was incompatible with persistent External Sync, but it made a
payload-at-FIFO-zero assumption appear valid.

Once the receiver correctly remained enabled, its internal state also remained
live across transactions. The old assumption became visible immediately.

The Command lane already searched a marker before accepting a frame, so a stale
whole byte was skipped. The old Bulk lane was a raw payload reader, so it had no
way to distinguish stale pipeline data from byte zero of a block. This was the
last structural difference between the receive paths.

## Fix

Both lanes now use the same packet:

```text
A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
```

The host receive paths:

1. keep RX enabled and Auto Enables off;
2. clear the error latch;
3. drain only the bounded three-byte FIFO depth;
4. wait for software admission;
5. scan for the complete `A5 5A` marker;
6. validate LEN, TYPE, SEQ, STATUS, and CRC; and
7. expose DATA only to the caller.

The MCU's host-to-MCU Bulk path performs the same marker/header/CRC validation
at arbitrary bit phase before committing anything to the SD card.

The trailing `FFh` can still surface, but it is now unambiguously outside the
packet and is skipped by marker search.

## Related persistent-sync requirements

The same change keeps the four SIO invariants explicit:

- `/SYNCA` falls only on the establishing transfer and stays low;
- setup clocks and the disposable hand-clocked byte run only while establishing;
- Enter Hunt is issued only before the first verified receive; and
- the receiver is never disabled after establishment.

Auto Enables remains off, so `/DCDA` cannot silently disable RX. `/DCDA` and
`/CTSA` are stable software admission levels, held for the complete packet; the
PIC does not open the clock gate until after asserting the relevant level and
waiting its guard time.

## Diagnostic consequence

Normal tools must call BIOS `IOCALL`, `IOCBULK`, or `IOCBULKW`. A standalone
tool that reads SIO1/A DATA directly will reintroduce the payload-at-byte-zero
bug, and one that writes WR3 directly can destroy persistent sync.

`PING`, `BULK`, `SDBLK`, `SDWRT`, `SDREC`, `SDSOAK`, and `SDFMT` use the BIOS
packet path. `RTSPROBE` is intentionally a destructive low-level electrical
probe and requires a cold boot afterward.

## Follow-up: first common-packet Bulk failure

Protocol level 6 initially reused the hand-clocked sync-establishing byte as
packet marker byte `A5h`. That coupled two different layers. Channel B happened
to expose the byte as expected, while channel A requires `/SYNCA` to fall one
bit earlier; on its first transfer the CPU could not reliably observe that byte
as `A5h`. The remaining SPI stream began at `5Ah`, so `IOCBULK` found no
`A5 5A`, returned transport error `02`, and left the caller buffer untouched at
`FFh`.

Protocol level 7 fixes this structurally on both lanes: a disposable `FFh` is
hand-clocked solely to establish the SIO boundary, then the complete
`A5 5A ... CRC` packet is sent as aligned SPI bytes. Packet parsing no longer
depends on the channel-specific `/SYNC` drop point.

## Follow-up: protocol 7 still returned transport error 02

Separating the sync byte removed a real layering defect, but it did not remove
the next Bulk-only timing defect. Firmware level `13h` and BIOS transport level
`07h` proved that the matching pair was running: PING worked, while both
`BULK.COM` and the SDREC read phase returned `02` before exposing DATA.

The MCU streams the complete Bulk packet continuously at roughly 6 us per byte.
The BIOS payload loop was designed for that rate and consumes a ready byte in
56 Z80 T-states, or 5.6 us at 10 MHz. The envelope path did not:

- marker and header bytes used a general subroutine costing about 82 T-states
  per immediately available byte; and
- after receiving the five-byte header, the BIOS stopped to compare LEN, TYPE,
  SEQ, and STATUS while the MCU continued sending payload.

The SIO has only a three-byte receive FIFO, about 18 us at the Bulk rate. The
mid-frame validation pause consumed that entire budget. Depending on exactly
how many pipeline or stale bytes preceded the marker, the FIFO overran while
the header or first payload bytes were arriving. A damaged header was reported
as the merged `IOC_XPORT_BAD_FRAME` value `02`; damage after the header appeared
later as a CRC failure.

This was a host parser scheduling bug, not an SD-card failure and not another
loss of the persistent External Sync boundary.

### Fix

`IOCBULK` now treats the wire stream as one uninterrupted critical section:

1. locate `A5 5A`;
2. receive the five-byte header with a tight `INI` loop whose ready path is the
   same 56 T-states as the payload loop;
3. immediately receive the caller-authorized DATA length and CRC trailer;
4. release the Bulk handshake; and only then
5. validate LEN, TYPE, SEQ, STATUS, and CRC.

The untrusted wire length never controls a write to RAM. The length already
authorized by the CRC-verified READY reply remains the receive count, so moving
metadata validation after reception does not weaken bounds checking.

BIOS fixed diagnostic RAM also records the precise rejection stage, decoded
header, expected metadata, RR0/RR1, and Bulk sync state. `BULK.COM`, `SDREC.COM`,
and `SDSOAK.COM` print that trace on an `IOCBULK` failure. This instrumentation
runs outside the timed byte stream and therefore cannot create the overrun it
is intended to diagnose.

The wire format did not change, so the advertised controller firmware level
remains `13h` and the BIOS transport level remains `07h`.
