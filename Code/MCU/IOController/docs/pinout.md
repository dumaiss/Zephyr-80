# IO Controller Pinout Notes

Target MCU: `PIC18F57Q84`.

| Signal | PIC18 Pin | Direction | Active State | Notes |
| --- | --- | --- | --- | --- |
| HOST_RESET | RB2 | Output | Low | System reset to host CPU and bus. Asserted for 100 ms during MCU startup, then released. |
| RESET_HIGH | RB5 | Output | High | Driven as the inverse of HOST_RESET/RB2. High for the 100 ms startup reset pulse, then low. |

See `Z80 Peripherals Controller.md` for the architectural notes.
