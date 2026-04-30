# IO Controller Pinout Notes

Target MCU: `PIC18F57Q84`.

| Signal | PIC18 Pin | Direction | Active State | Notes |
| --- | --- | --- | --- | --- |
| PWR_STATE | RB0 | Input | High | From PMU. High means hold reset or initiate shutdown work. Low means the system is in normal active mode |
| PWR_OFF_RQ | RB1 | Output | Low | To PMU. Assert low when IO Controller is ready for power removal. High means the system is in normal operation |
| HOST_RESET | RB2 | Output | Low | System reset to host CPU and bus. Assert while PMU asks IO Controller to hold reset and for 500 ms during IO Controller startup. |
| NMI_RQ | RB3 | Input | Low | Momentary NMI request switch. Internal pull-up enabled. |
| BUS_NMI | RB4 | Output | Low | Host CPU NMI. Pulsed low for 100 ms when NMI_RQ is pressed. |
| RESET_HIGH | RB5 | Output | High | Always driven as the inverse of HOST_RESET/RB2. |
| SD_PRESENT | TBD | Input | TBD | SD card detect. |
| SD_BUSY | TBD | Output | TBD | Optional activity/status signal. |
| SIO1B_INT | RF1 | Input | Low | USB SIO RTSB service request. IOC interrupt latches mailbox work. |
| SIO1A_INT | RF2 | Input | Low | SD SIO RTSA service request. IOC interrupt latches mailbox work. |
| CS_SIO_SD | RA0 | Input | Low | Tied to SIO port A SYNCA for SD synchronization. Stubbed/ignored in current code. |
| CS_SIO_USB | RA1 | Input | Low | Tied to SIO port B SYNCB for USB synchronization. Stubbed/ignored in current code. |
| USB_INT | RA2 | Input | Low | Interrupt from USB subsystem. |
| USB_CS | RA3 | Output | Low | SPI chip select for USB. |
| SD_CS | RA4 | Output | Low | SPI chip select for SD card. |
| MOSI | RA5 | Output | Data | SPI MOSI from IO Controller master. |
| MISO | RA6 | Input | Data | SPI MISO to IO Controller master. |
| SPI_CLK | RA7 | Output | Clock | SPI clock from IO Controller master. |

See `Z80 Peripherals Controller.md` for the architectural notes.
