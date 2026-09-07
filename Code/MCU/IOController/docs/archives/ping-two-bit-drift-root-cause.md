# PING Two-Bit Drift: Root-Cause Report

Date: 2026-08-27  
Status: corrected and verified by repeated PING on hardware

## Summary

With the former fixed-mailbox wire format, PING succeeded once every four
attempts because the Z80 SIO1/B receiver gained
exactly two unintended rising clock edges per command transaction. The PIC
generated the intended 560 rising edges, but the SIO received 562.

The extra edges were produced downstream of the PIC by the board's
74AHCT125-gated clock. An unselected SIO clock is pulled high by 100 kΩ, while
the firmware previously parked the shared `SIO_SCK` source low. Releasing a
channel select therefore changed the selected SIO clock from driven low to
pulled high. The SIO counted that transition as another receive-clock edge.

A command transaction releases the SIO1/B clock gate twice:

1. After the 36-byte request capture.
2. After the 34-byte reply transmission.

Each release contributed one rising edge, producing the observed two-bit drift.

## Observed Failure Pattern

Three consecutive failed reply bytes were:

```text
FB = 1111 1011
EF = 1110 1111   FB rotated by two bits
BF = 1011 1111   EF rotated by two bits
```

The Z80 SIO External Sync receiver establishes a character boundary and then
counts eight clocks per character. A two-bit displacement per transaction
returns to the same byte boundary after four transactions:

```text
transaction 0: offset 0 bits
transaction 1: offset 2 bits
transaction 2: offset 4 bits
transaction 3: offset 6 bits
transaction 4: offset 8 bits = offset 0 modulo one byte
```

This explains both the repeatable rotations and PING succeeding once every
four attempts.

## Intended and Actual Clock Counts

The failing firmware's steady-state command transaction was byte-aligned by
construction:

| Phase | Bytes | Intended rising edges |
|---|---:|---:|
| Request capture | 36 | 288 |
| Reply: marker + 32-byte frame + trailing byte | 34 | 272 |
| Total | 70 | 560 |

With the old low-idle configuration, the electrical result at SIO1/B was:

| Event | Added SIO rising edges |
|---|---:|
| Request clock gate released | 1 |
| Reply clock gate released | 1 |
| Intended transfer clocks | 560 |
| Actual SIO total | 562 |

The bug was therefore not in the byte-count arithmetic. It was in the clock
gate's idle-level transition outside the SPI byte transfers.

## Electrical Mechanism

The relevant board wiring is documented in
[`Zephyr80_IOController_Validation.md`](../../../../Schem/Zephyr-80-IO/Zephyr80_IOController_Validation.md):

- PIC `RB3/SIO_SCK` drives both SIO clocks through a 74AHCT125.
- `/SIOA_CS` and `/SIOB_CS` enable the corresponding clock buffers.
- R37 and R38 are 100 kΩ pull-ups on the gated clock outputs.
- An unselected SIO clock therefore rests high.

The previous firmware used SPI `CKP = 0` and parked `LATB3` low. At the end of a
selected phase, the sequence was:

```text
selected:    SIO clock is actively driven low
/SIOx_CS↑:   74AHCT125 output becomes high impedance
unselected:  R37/R38 pulls the SIO clock high
result:      one unintended low-to-high clock transition
```

The PPS handover itself could still be glitch-free at the PIC pin. The fault
occurred after that pin, where disabling the external buffer exposed the
opposite pull-up level.

## Why PIC-Side Instrumentation Did Not See It

Timer1 diagnostic instrumentation counts rising edges on the PIC's physical
RB3 pin. It can detect SPI clocks and PPS ownership transitions at RB3, but it
cannot detect a transition created downstream by the 74AHCT125 and its pull-up.

Consequently, it is possible—and expected in the failing firmware—to measure
560 source-clock edges at RB3 while SIO1/B receives 562.

This is also why counting calls to the SPI exchange routine or inspecting the
PIC's SCK pin alone could not reconcile the failure.

## Why the Previous Design Appeared to Work

The older transport re-established External Sync on every reply using a
bit-banged sync byte. That reset the SIO's character boundary every transaction,
so the two unwanted gate-release edges never accumulated visibly.

Persistent External Sync removed that repeated realignment and exposed the
underlying electrical clock-count error. The protocol change did not create the
extra edges; it stopped masking them.

## Correction

The shared SIO clock now idles high everywhere, matching the level imposed by
the gated clock pull-ups:

- SPI2 uses `CKP = 1` and `CKE = 0`.
- Data still changes on falling edges and is sampled on rising edges.
- `LATB3` is set high before either SIO channel is selected.
- GPIO-to-SPI and SPI-to-GPIO PPS handovers occur at the same high level.
- The clock remains high before `/SIOA_CS` or `/SIOB_CS` is released.
- Manually clocked sync and setup bits use high-idle, low-then-high pulses.
- The same gate discipline is applied to the bulk channel.

The implementation is in:

- [`src/external_sync.c`](../src/external_sync.c)
- [`src/bulk_channel.c`](../src/bulk_channel.c)
- [`include/sio_link.h`](../include/sio_link.h)
- [`include/config.h`](../include/config.h)

An explicit link resynchronization also releases `/SYNCB` high before clearing
the persistent-sync state, ensuring that the next establishing reply can
deliver a real falling `/SYNCB` edge.

The clock-idle correction itself did not require a framing change. The transport
was subsequently migrated to the common variable-length A5/5A packet, so the
historical 34-byte reply count below is no longer the current PING reply size.

## Verification Without a Long Scope Capture

The correction does not require capturing an entire 560-edge transaction.

1. Flash [`build/io_controller.hex`](../build/io_controller.hex).
2. Confirm PING reports firmware level `13` and BIOS transport level `07`.
3. Run PING repeatedly; consecutive attempts should succeed rather than only
   every fourth attempt.
4. With the current common packet, the diagnostic PING should report:

   ```text
   current request clocks : 0120
   previous reply clocks  : 0120
   ```

   The first PING after reset may report `0000` for the previous reply because
   no prior reply has completed. The first establishing full PING reply itself
   has two setup clocks plus one disposable sync byte and measures `012A`;
   later full PING replies are 36 bytes including the pipeline trailer, or
   `0120`. A shorter preceding reply legitimately reports a smaller count.

If an electrical check is desired, only a short capture around a
`/SIOB_CS` rising edge is needed. The gated `SIOB_SCK` signal should already be
high and must remain high as the buffer is disabled. It is not necessary to
capture the complete transaction.

## Verification result

Repeated PING now works on the physical system. The one-in-four rotation has
not recurred with the selected clock parked high. Current build sizes and hashes
belong in build output rather than this historical report because the packet and
diagnostic payload changed after the electrical correction.
