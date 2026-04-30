# IO Controller Pinout Notes

Target MCU: `PIC18F57Q84`.

| Signal | PIC18 Pin | Direction | Active State | Notes |
| --- | --- | --- | --- | --- |
| PWR_STATE | RB0 | Input | High | From PMU. High means hold reset or initiate shutdown work. Low means the system is in normal active mode |
| PWR_OFF_RQ | RB1 | Output | Low | To PMU. Assert low when IO Controller is ready for power removal. High means the system is in normal operation |
| HOST_RESET | RB2 | Output | Low | System reset to host CPU and bus. Assert while PMU asks IO Controller to hold reset and for 500 ms during IO Controller startup. |
| SD_PRESENT | TBD | Input | TBD | SD card detect. |
| SD_BUSY | TBD | Output | TBD | Optional activity/status signal. |
| USB_INT | TBD | Input | Low | MAX3421E interrupt line. |
| SPI_CLK | TBD | Output | Clock | Shared SPI clock. |
| MOSI | TBD | Output | Data | Shared SPI MOSI. |
| MISO | TBD | Input | Data | Shared SPI MISO. |

See `Z80 Peripherals Controller.md` for the architectural notes.
