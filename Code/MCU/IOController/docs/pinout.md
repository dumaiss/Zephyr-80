# IO Controller Pinout

Target MCU: `PIC18F57Q84` (U15, `-I/PT`, 48-pin TQFP)

Net names are the schematic net names.  Polarity follows the schematic
overbars: barred nets are active-low, everything else is active-high.  Only
`NMI_RQ`, `RESET_HIGH`, `PWR_OFF` and `SHUTDOWN_RQ` are active-high; the five
`*_CS` selects and `/USB_INT` are active-low like the rest.

Macro names keep a `HOST_` prefix on the reset and NMI outputs because `<xc.h>`
already claims `RESET()` and `NMI`.

`ANSELA`, `ANSELB`, `ANSELD`, `ANSELE` and `ANSELF` are all cleared to `0x00` in
`platform_init()`, so every pin below is digital.

## Port A — peripheral selects and External Sync

| Pin | Port | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|---|
| 21 | RA0 | `/USB_INT` | Input | Low | `USB_INT_PORT` | USB bridge data-ready. Unused by the current firmware. |
| 22 | RA1 | `/CTRL_LAT_CS` | Output | Low | `CTRL_LAT_CS_LAT` | Select for the cascaded controller 74HC595s on the **port C** bus; doubles as their RCLK. The 595 latches on RCLK's rising edge, so releasing the select is what commits the outputs. |
| 23 | RA2 | `/IO_SD_CS` | Output | Low | `IO_SD_CS_LAT` | SD card select. Held idle by the current firmware. |
| 24 | RA3 | `/IO_USB_CS` | Output | Low | `IO_USB_CS_LAT` | USB bridge select. Held idle by the current firmware. |
| 25 | RA4 | `/SIOB_CS` | Output | Low | `SIOB_CS_LAT` | Puts SIO1/B on the shared bus and enables the TXDB buffer. Held asserted for a whole command transaction. |
| 26 | RA5 | `/SIOA_CS` | Output | Low | `SIOA_CS_LAT` | Puts SIO1/A on the bus for a bulk transfer. Asserted for the whole bulk phase. |
| 33 | RA6 | `/SYNCA` | Output | Low | `SYNCA_LAT` | Persistent SIO1/A External Sync: starts high, drops inside byte 0 of the establishing MCU-to-host transfer, then remains low. |
| 32 | RA7 | `/SYNCB` | Output | Low | `SYNCB_LAT` | SIO1/B External Sync strobe. |

## Port B — SIO serial bus, SIO1/A modem control, ICSP

| Pin | Port | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|---|
| 8 | RB0 | `/CTSA` | Output | Low | `CTSA_LAT` | SIO1/A software TX-admission and bulk-active level; held asserted throughout a transfer and through write commit. |
| 9 | RB1 | `SIO_MOSI` | Output | - | `SIO_MOSI_LAT` | SIO bus data, PIC -> device. Drives SIO1/B `RXDB`. Idle high (marking). SPI2 SDO when the SPI transport is enabled. |
| 10 | RB2 | `SIO_MISO` | Input | - | `SIO_MISO_PORT` | SIO bus data, device -> PIC. Samples SIO1/B `TXDB` when `/SIOB_CS` is asserted. SPI2 SDI (reset default). |
| 11 | RB3 | `SIO_SCK` | Output | - | `SIO_SCK_LAT` | SIO bus clock. Drives SIO1/B `RXTXCB` through a 74AHCT125 gate. Idle high to match the gated clock's pull-up. The board only activates it toward an SIO while that SIO's select is asserted. SPI2 SCK (reset default input mapping). |
| 16 | RB4 | `/DCDA` | Output | Low | `DCDA_LAT` | SIO1/A software RX-admission level. Auto Enables is off, so it never gates or disables the receiver. |
| 17 | RB5 | `/CTSB` | Output | Low | `CTSB_LAT` | SIO1/B clear-to-send. Parked idle. |
| 18 | RB6 | `ICSPCLK` | - | - | - | Programming. |
| 19 | RB7 | `ICSPDAT` | - | - | - | Programming. |

## Port C — external peripheral bus

The second SPI bus (SPI1), shared by the SD card, the USB HID bridge and the
controller latch.

**`SPI_CLK` is NOT gated by the device selects.**  Unlike the port B SIO bus,
there is no hardware here that blocks the clock; every device on this bus sees
every clock the PIC emits, whatever the selects are doing.  Devices are
distinguished by their select alone, so anything on this bus must ignore clocks
that are not addressed to it.

That matters for the SD card, whose spec asks for 74+ power-up clocks with CS
**high**.  Those clocks do reach the card, so the driver sends them properly:
deselected, with DI held high.  This is what puts the card into SPI mode, and
it must not be moved inside the select.

An earlier revision of this document claimed the clock *was* gated, "confirmed
on a scope".  The scope only showed clock and select coinciding, because the
firmware clocked exclusively while a select was asserted; that correlation was
written up as a hardware fact and then used to justify removing the CS-high
power-up burst.  See `include/sd_card.h` for the consequences.

The controller latch and the SD card are both brought up; the USB bridge select
is held idle.

| Pin | Port | Signal | Notes |
|---|---|---|---|
| 34 | RC0 | `SD_PRESENT` | SD card presence detect, **active low** (low = card seated). **Not wired on the current board.** The driver infers presence from the card protocol instead (an empty socket leaves DO undriven, so every response byte reads FFh). Set `SD_HAS_PRESENT_PIN` to 1 in `include/sd_card.h` once it is connected. |
| 35 | RC1 | `SD_BUSY` | **Output**, active high, drives an activity LED directly. Raised for the whole duration of a card access, including the lazy init the first read triggers (which can run for most of a second). Parked low at boot. Note a steady-state read is only ~1-2 ms, too brief to see; only the first-access init flash is visible to the eye. |
| 40 | RC2 | - | No connect. |
| 41 | RC3 | `SPI_CLK` | Peripheral bus clock. SPI1 SCK — reset-default input mapping, output routed via `RC3PPS = 0x31`. |
| 46 | RC4 | `MISO` | Peripheral bus data in. SPI1 SDI — reset default, no PPS needed. |
| 47 | RC5 | `MOSI` | Peripheral bus data out. SPI1 SDO via `RC5PPS = 0x32`. Drives the 74HC595 `SER`. |
| 48 | RC6 | - | No connect. |
| 1 | RC7 | - | No connect. |

Selects for this bus live on port A: `/IO_SD_CS` (RA2), `/IO_USB_CS` (RA3) and
`/CTRL_LAT_CS` (RA1).

### Which SPI module goes where

The silicon's reset-default PPS input mappings match this board exactly, so
each bus should use the module that already points at it:

| Module | Default SCK | Default SDI | Bus |
|---|---|---|---|
| SPI1 | RC3 | RC4 | Port C peripherals (SD, USB HID, controller latch) |
| SPI2 | RB3 | RB2 | Port B SIO1/A + SIO1/B |

Assigning them this way means neither bus needs `SPIxSCKPPS` or `SPIxSDIPPS`
touched at all; only the output routes have to be claimed.

## Port D — GPIO header

The header numbering runs opposite to the port bit numbering: `GPIO0` is RD7 and
`GPIO7` is RD0.  `platform_init()` leaves the whole port as inputs
(`IOC_GPIO_TRIS = 0xFF`) until something claims it.

| Pin | Port | Signal | Macro |
|---|---|---|---|
| 42 | RD0 | `GPIO7` | `GPIO7_LAT` / `GPIO7_PORT` |
| 43 | RD1 | `GPIO6` | `GPIO6_LAT` / `GPIO6_PORT` |
| 44 | RD2 | `GPIO5` | `GPIO5_LAT` / `GPIO5_PORT` |
| 45 | RD3 | `GPIO4` | `GPIO4_LAT` / `GPIO4_PORT` |
| 2 | RD4 | `GPIO3` | `GPIO3_LAT` / `GPIO3_PORT` |
| 3 | RD5 | `GPIO2` | `GPIO2_LAT` / `GPIO2_PORT` |
| 4 | RD6 | `GPIO1` | `GPIO1_LAT` / `GPIO1_PORT` |
| 5 | RD7 | `GPIO0` | `GPIO0_LAT` / `GPIO0_PORT` |

## Port E

| Pin | Port | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|---|
| 27 | RE0 | `/DCDB` | Output | Low | `DCDB_LAT` | SIO1/B data-carrier-detect. Parked idle. |
| 28 | RE1 | - | - | - | - | Unassigned. |
| 29 | RE2 | - | - | - | - | No connect. |
| 20 | RE3 | `VPP` / `/MCLR` | - | - | - | Programming. |

## Port F — host control

| Pin | Port | Signal | Direction | Active | Macro | Notes |
|---|---|---|---|---|---|---|
| 36 | RF0 | `/SIO1B_INT` | Input | Low | `SIO1B_INT_PORT` | SIO1/B service request. A falling edge starts one command transaction. |
| 37 | RF1 | `/SIO1A_INT` | Input | Low | `SIO1A_INT_PORT` | Host SIO1/A RTS/service request. The PIC waits for it before advertising admission or clocking Bulk. |
| 38 | RF2 | `RESET` | Output | Low | `HOST_RESET_LAT` | System reset to Z80 and bus. |
| 39 | RF3 | `RESET_HIGH` | Output | High | `HOST_RESET_HIGH_LAT` | Complementary reset signal. |
| 12 | RF4 | `NMI_RQ` | Input | High | `NMI_RQ_PORT` | Incoming NMI request. Unused by the current firmware. |
| 13 | RF5 | `/NMI` | Output | Low | `HOST_NMI_LAT` | NMI to the Z80. Parked idle. |
| 14 | RF6 | `PWR_OFF` | **Floating** | High | `PWR_OFF_LAT` | Left high-Z: the PMU side is not finished and driving this pin at all stops the machine from starting. When claimed, it is a **LEVEL** signal to the PMU, not a pulse — once asserted the PMU cuts the rails and keeps them cut. |
| 15 | RF7 | `SHUTDOWN_RQ` | Input | High | `SHUTDOWN_RQ_PORT` | Incoming shutdown request. Unused by the current firmware; left as an input. |

## Power

| Pin | Signal |
|---|---|
| 6, 31 | `VSS` |
| 7, 30 | `VDD` |

### Power management is deliberately not driven

`platform_init()` sets `PWR_OFF_TRIS = PWR_OFF_FLOAT` and never writes `LATF6`.
The PMU is incomplete, and driving RF6 — even to the deasserted level — stopped
the machine from starting.  When the PMU side is ready, take ownership by
writing `PWR_OFF_LAT = PWR_OFF_IDLE` *before* clearing `PWR_OFF_TRIS`, so the
pin never glitches through the asserted level on the way to being an output.

## External Sync Transaction

```text
Z80 BIOS asserts /SIO1B_INT low
PIC sees the falling edge
PIC asserts /SIOB_CS low to take the shared bus
PIC drives /SYNCB low and clocks the request from TXDB
PIC releases /SYNCB and /SIOB_CS, dispatches the 32-byte request frame
PIC re-asserts /SIOB_CS and sends a 32-byte reply on SIO_MOSI
PIC clocks one trailing idle byte so the SIO exposes the last reply byte
PIC releases /SIOB_CS
Z80 BIOS deasserts /SIO1B_INT
```

## Controller Latch Bring-Up

The cascaded 74HC595 pair (2 x 8 bits) is driven over SPI1 on the port C bus.
At boot it is written once with `(0,0)`.  The periodic diagnostic is disabled by
default (`CONTROLLER_LATCH_COUNTER_TEST=0`), so it produces no idle SCK/MOSI
traffic while the SD card is being brought up.

If the diagnostic is explicitly enabled, `controller_latch_tick()` writes an
incrementing pair `(n, n+1)` every 500 ms.  Each write goes through the central
SPI1 selector, which releases the SD and USB selects before pulsing latch RCLK.

```text
Timer2: FOSC/4 16 MHz, 1:128 prescale, T2PR=249, 1:5 postscale -> 10 ms tick
        50 ticks -> 500 ms
SPI1:   Fosc, BAUD=31 -> 1 MHz; 16 bits per update = 16 us
        LSBF = 0 -- the 595 shifts MSB first, unlike the Z80 SIO
Latch:  /CTRL_LAT_CS asserted for the 16-bit shift, released to commit
```

`byte0` is shifted first and lands in the **far** device of the chain; `byte1`
lands in the near one.  Swap the arguments if the monitor shows them the other
way round.

The tick is derived from a polled `TMR2IF`, which is a sticky flag rather than a
count, so blocking work in the main loop stretches the period instead of
catching up: the 100 ms boot reset delays the first update, and heavy IOCALL
traffic can add a few ms.  That is fine for a counter being watched by eye.
