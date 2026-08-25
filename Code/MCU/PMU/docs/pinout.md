# PMU Pinout Notes

Power-control firmware pin assignments.

| Signal | PMU Pin | AVR Port | Direction | Active State | Type | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| RESET | Physical pin 1 | PB5 | Input | High | Level | Held high for normal operation |
| /PWR_OFF_RQ | Physical pin 3 | PB4 | Input | Low | Level | IO Controller says it is done and power may go |
| /SHUTDOWN_RQ | Physical pin 2 | PB3 | Output | Low | Level | Asks the IO Controller to clean up; arrives there on RF7 |
| PWR_SW | Physical pin 7 | PB2 | Input | Low | Edge | Physical power switch on the enclosure |
| PWR_OK | Physical pin 6 | PB1 | Input | High | Level | ATX connector `PWR_OK` |
| PS_ON | Physical pin 5 | PB0 | Output | High at PB0, low at ATX `PS_ON#` | Level | Drives ATX connector `PS_ON#` through a MOSFET |

## Firmware Behavior

- If `PMU_IGNORE_IO_CONTROLLER_SIGNALS` is set to `1`, the PMU does not sample
  `PWR_OFF_RQ` and does not drive `SHUTDOWN_RQ`; `SHUTDOWN_RQ` stays an input with
  its internal pull-up enabled, so the net idles high instead of floating.
- `PWR_OFF_RQ`, `PWR_SW` and (when it is an input) `SHUTDOWN_RQ` use the PMU
  internal pull-ups.  `PWR_OFF_RQ` keeps its pull-up in both build modes: the
  IO Controller currently leaves its end of that net high-Z, so without the
  pull-up both ends would float.
- `PWR_OK` is treated as an externally driven ATX status signal.
- PB0 controls the `PS_ON#` MOSFET gate. PB0 high turns the MOSFET on and pulls
  ATX `PS_ON#` low. PB0 low turns the MOSFET off and lets the PSU turn off.
- `SHUTDOWN_RQ` is a level signal. Low means the IO Controller is allowed to run.
  High means the IO Controller must hold the system in reset.
- During startup, `SHUTDOWN_RQ` stays high until `PWR_OK` is asserted. When
  `PWR_OK` is asserted, the PMU sets `SHUTDOWN_RQ` low.
- A falling edge on `PWR_SW` while off turns PB0 on immediately, pulling ATX
  `PS_ON#` low to start the PSU. `SHUTDOWN_RQ` stays high until `PWR_OK` is
  asserted.
- When the system is already powered and the user presses `PWR_SW`, the PMU
  sets `SHUTDOWN_RQ` high so the IO Controller can finish its shutdown
  work.
- The PMU waits for the IO Controller to assert `PWR_OFF_RQ` low before
  shutting off the PSU in the normal shutdown path.
- If the system is already powered and `PWR_SW` is held for 5 seconds, the
  PMU turns PB0 off directly, disabling the PSU without waiting for the IO
  Controller.
- Holding `PWR_OFF_RQ` low turns PB0 off, disabling the MOSFET and allowing the
  ATX supply to turn off.

## Handshake Polarity

Both handshake signals are **active low**, and that is a deliberate choice
rather than a convention. Each end holds its own input at the deasserted level
with a programmed pull-up, so a net whose partner is unpowered, held in reset,
or simply not driving reads as *nothing requested* instead of floating.

Neither MCU has programmable pull-downs — the AVR has pull-ups only, and so
does the PIC (`WPUA`..`WPUF` and nothing else) — so active low is the only
polarity that can be made fail-safe in firmware alone, with no external parts.

`/SHUTDOWN_RQ` is a shutdown request and nothing more. It does not gate whether
the system may run: the PSU comes up when `PWR_OK` is good, and that is the
whole of the start-up story.

## Shutdown Sequence

The IO Controller decides when power actually goes away; the PMU only asks. The
thing that takes time is the SD write-back cache, and only the IO Controller
knows whether it is dirty.

| # | Who | Action |
| --- | --- | --- |
| 1 | User | Presses `PWR_SW` while powered |
| 2 | PMU | Drives `/SHUTDOWN_RQ` low |
| 3 | IOC | Stops accepting commands, so the Z80 cannot dirty another cache slot |
| 4 | IOC | Flushes the SD cache — up to four blocks, each possibly ~200 ms |
| 5 | IOC | Drives `/PWR_OFF_RQ` low |
| 6 | PMU | Turns PB0 off; the ATX supply drops |

Holding `PWR_SW` for 5 seconds bypasses all of it and cuts the PSU directly.
That does not wait for the flush and is not meant to: force exists for a machine
that is already wedged, so making it depend on the component most likely to be
wedged would defeat it. Uncommitted data is lost, by design.
