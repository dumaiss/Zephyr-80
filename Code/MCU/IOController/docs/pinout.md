# IO Controller Pinout Notes

Target MCU: `PIC18F57Q84`.

The exact firmware pin mapping is still a placeholder. Fill this in from the
KiCad schematic before enabling real hardware outputs.

| Signal | Direction | Active State | Notes |
| --- | --- | --- | --- |
| PWR_STATE | Input | High | From PMU. High means hold/reset and prepare for shutdown. |
| PWR_OFF_RQ | Output | TBD | To PMU. Assert when IO Controller is ready for power removal. |
| SD_PRESENT | Input | TBD | SD card detect. |
| SD_BUSY | Output | TBD | Optional activity/status signal. |
| USB_INT | Input | Low | MAX3421E interrupt line. |
| SPI_CLK | Output | Clock | Shared SPI clock. |
| MOSI | Output | Data | Shared SPI MOSI. |
| MISO | Input | Data | Shared SPI MISO. |

See `Z80 Peripherals Controller.md` for the architectural notes.
