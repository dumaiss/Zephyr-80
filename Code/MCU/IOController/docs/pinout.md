# IO Controller Pinout

Target MCU: `PIC18F57Q84`

## Port A — SPI bus and chip selects (RA0–RA7)

All eight RA pins are SPI-related. ANSELA is cleared to 0x00 (all digital) in `platform_init()`.

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RA0 | `BULK_CS` | Output | Low | `BULK_CS_LAT` | CS for SIO1/A Bulk channel (bulk data) |
| RA1 | `CMD_CS` | Output | Low | `CMD_CS_LAT` | CS for SIO1/B Command channel (command/events) |
| RA2 | `USB_INT` | Input | Low | `USB_INT_PORT` | Interrupt / data-ready from USB-to-SPI bridge |
| RA3 | `USB_BRIDGE_CS` | Output | Low | `USB_BRIDGE_CS_LAT` | CS for USB-to-SPI bridge (keyboard HID reports) |
| RA4 | `SD_CS` | Output | Low | `SD_CS_LAT` | CS for SD card |
| RA5 | `SPI_MOSI` | Output | — | `SPI_MOSI_LAT` | Shared SPI data out (all consumers) |
| RA6 | `SPI_MISO` | Input | — | `SPI_MISO_PORT` | Shared SPI data in (all consumers) |
| RA7 | `SPI_CLK` | Output | — | `SPI_CLK_LAT` | Shared SPI clock; also TXC/RXC to SIO1/A and SIO1/B |

### SPI sharing rule

All four SPI consumers (SIO Command, SIO Bulk, USB bridge, SD card) share the same MOSI/MISO/CLK pins. Exactly one CS is asserted at a time. SPI clock rate and mode are reconfigured before each consumer's CS is asserted.

| Consumer | CS pin | Typical SPI rate |
|---|---|---|
| SIO1/B Command (SDLC) | RA1 | 250 kHz bring-up → 1–1.5 MHz production |
| SIO1/A Bulk (SDLC) | RA0 | 250 kHz bring-up → 1–1.5 MHz production |
| USB-SPI bridge | RA3 | TBD — depends on bridge chip |
| SD card | RA4 | 400 kHz init → up to 25 MHz |

## Port B — Host reset pair (RB2, RB5)

ANSELB is cleared to 0x00 in `platform_init()`.

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RB2 | `HOST_RESET` | Output | Low | `HOST_RESET_LAT` | System reset to Z80 and bus. Driven low for 100 ms at MCU startup, then released high. |
| RB5 | `RESET_HIGH` | Output | High | `HOST_RESET_HIGH_LAT` | Complementary reset signal. Driven high for the same 100 ms pulse, then low. |

## Port F — Z80 SIO RTS inputs (RF1, RF2)

ANSELF bits for RF1/RF2 cleared to digital in `platform_init()`. Configured as inputs with interrupt-on-change (falling edge) to detect Z80 service requests.

| Pin | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|
| RF1 | `SIO_CMD_RTS` | Input | Low | `SIO_CMD_RTS_PORT` | Z80 SIO1/B RTS. Goes low when Z80 asserts RTS, requesting Command channel service. Triggers MCU ISR. |
| RF2 | `SIO_BULK_RTS` | Input | Low | `SIO_BULK_RTS_PORT` | Z80 SIO1/A RTS. Goes low when Z80 asserts RTS, requesting Bulk channel service. Triggers MCU ISR. |

## Unassigned / TBD

- USB bridge model and RA2 `USB_INT` active polarity to be confirmed from hardware schematic.
- Actual SIO1/A and SIO1/B pin connections on SIO chip side (TXD/RXD/TXC/RXC) to be documented when PCB is available.
- All other PIC18F57Q84 ports (RC, RD, RE) unassigned in this revision.
