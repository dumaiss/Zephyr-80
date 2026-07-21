# IO Controller Pinout

Target MCU: `PIC18F57Q84`

## Port A

ANSELA is cleared to `0x00` in `platform_init()`, so all Port A pins used here
are digital.

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RA0 | unused select | Output | High idle | `UNUSED_RA0_LAT` | Held high so the inactive SIO1/A-side hardware is not selected. |
| RA1 | `/SYNCB` / gate | Output | Low | `IOC_SYNC_LAT` | Drives SIO1/B External Sync and the 74HC125 `/OE` for SIO TXDB -> PIC RXD. |
| RA2 | `USB_INT` | Input | Low | `USB_INT_PORT` | USB bridge data-ready input; unused by the current firmware. |
| RA3 | USB bridge select | Output | Low | `USB_BRIDGE_CS_LAT` | Held idle-high by the current firmware. |
| RA4 | SD select | Output | Low | `SD_CS_LAT` | Held idle-high by the current firmware. |
| RA5 | PIC -> SIO data | Output | - | `IOC_TXD_LAT` | Drives Z80 SIO1/B `RXDB`. Idle high. |
| RA6 | SIO -> PIC data | Input | - | `IOC_RXD_PORT` | Samples Z80 SIO1/B `TXDB`. |
| RA7 | link clock | Output | - | `IOC_CLK_LAT` | Drives Z80 SIO1/B `RXTXCB`. Idle low. |

## Port B

ANSELB is cleared to `0x00` in `platform_init()`.

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RB2 | `HOST_RESET` | Output | Low | `HOST_RESET_LAT` | System reset to Z80 and bus. |
| RB5 | `RESET_HIGH` | Output | High | `HOST_RESET_HIGH_LAT` | Complementary reset signal. |

## Port F

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RF1 | `SIO_CMD_RTS` | Input | Low | `SIO_CMD_RTS_PORT` | Z80 SIO1/B RTSB. A falling edge starts one command transaction. |

## External Sync Transaction

```text
Z80 BIOS asserts RTSB low
PIC sees the falling edge
PIC drives /SYNCB low and clocks the request from TXDB
PIC releases /SYNCB, dispatches the 32-byte request frame
PIC sends a 32-byte reply on RXDB
PIC clocks one trailing idle byte so the SIO exposes the last reply byte
Z80 BIOS deasserts RTSB
```
