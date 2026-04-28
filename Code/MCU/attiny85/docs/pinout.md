# ATTiny85 Pinout Notes

Power-control firmware pin assignments.

| Signal | ATTiny85 Pin | AVR Port | Direction | Active State | Type | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| RESET | Physical pin 1 | PB5 | Input | High | Level | Held high for normal operation |
| PWR_OFF_RQ | Physical pin 3 | PB4 | Input | Low | Level | IO Controller requests soft power off |
| PWR_STATE | Physical pin 2 | PB3 | Output | High holds reset, low allows run | Level | Controls whether the IO Controller may run |
| PWR_SW | Physical pin 7 | PB2 | Input | Low | Edge | Physical power switch on the enclosure |
| PWR_OK | Physical pin 6 | PB1 | Input | High | Level | ATX connector `PWR_OK` |
| PS_ON | Physical pin 5 | PB0 | Output | High at PB0, low at ATX `PS_ON#` | Level | Drives ATX connector `PS_ON#` through a MOSFET |

## Firmware Behavior

- `PWR_OFF_RQ` and `PWR_SW` use the ATTiny85 internal pull-ups.
- `PWR_OK` is treated as an externally driven ATX status signal.
- PB0 controls the `PS_ON#` MOSFET gate. PB0 high turns the MOSFET on and pulls
  ATX `PS_ON#` low. PB0 low turns the MOSFET off and lets the PSU turn off.
- `PWR_STATE` is a level signal. Low means the IO Controller is allowed to run.
  High means the IO Controller must hold the system in reset.
- During startup, `PWR_STATE` stays high until `PWR_OK` is asserted. When
  `PWR_OK` is asserted, the ATTiny85 sets `PWR_STATE` low.
- A falling edge on `PWR_SW` while off turns PB0 on immediately, pulling ATX
  `PS_ON#` low to start the PSU. `PWR_STATE` stays high until `PWR_OK` is
  asserted.
- When the system is already powered and the user presses `PWR_SW`, the
  ATTiny85 sets `PWR_STATE` high so the IO Controller can finish its shutdown
  work.
- The ATTiny85 waits for the IO Controller to assert `PWR_OFF_RQ` low before
  shutting off the PSU in the normal shutdown path.
- If the system is already powered and `PWR_SW` is held for 5 seconds, the
  ATTiny85 turns PB0 off directly, disabling the PSU without waiting for the IO
  Controller.
- Holding `PWR_OFF_RQ` low turns PB0 off, disabling the MOSFET and allowing the
  ATX supply to turn off.
