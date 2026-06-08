#ifndef CONFIG_H
#define CONFIG_H

/* PIC18F57Q84 HFINTOSC is configured to 64 MHz in platform_init(). */
#define _XTAL_FREQ 64000000UL

/* ---------------------------------------------------------------------------
 * Host reset pair (RB2 / RB5) — unchanged from original skeleton.
 *
 * HOST_RESET    RB2  active-low  — drives Z80 and bus reset low
 * RESET_HIGH    RB5  active-high — complementary reset signal, driven high
 *               during the same 100 ms reset pulse, then low
 * --------------------------------------------------------------------------- */
#define HOST_RESET_TRIS          TRISBbits.TRISB2
#define HOST_RESET_ANSEL         ANSELBbits.ANSELB2
#define HOST_RESET_LAT           LATBbits.LATB2
#define HOST_RESET_ASSERTED      0
#define HOST_RESET_IDLE          1

#define HOST_RESET_HIGH_TRIS     TRISBbits.TRISB5
#define HOST_RESET_HIGH_ANSEL    ANSELBbits.ANSELB5
#define HOST_RESET_HIGH_LAT      LATBbits.LATB5
#define HOST_RESET_HIGH_ASSERTED 1
#define HOST_RESET_HIGH_IDLE     0

/* ---------------------------------------------------------------------------
 * Shared SPI bus (RA5/RA6/RA7)
 *
 * All four SPI consumers (SIO Command, SIO Bulk, USB bridge, SD card) share
 * these three pins.  Each consumer asserts its own CS pin exclusively.
 * SPI clock rate and mode are reconfigured before each consumer's CS is
 * asserted.
 *
 * RA5  SPI_MOSI   output   SPI data out to all devices
 * RA6  SPI_MISO   input    SPI data in from all devices
 * RA7  SPI_CLK    output   SPI clock to all devices (also TXC/RXC to SIO1)
 * --------------------------------------------------------------------------- */
#define SPI_MOSI_TRIS        TRISAbits.TRISA5
#define SPI_MOSI_ANSEL       ANSELAbits.ANSELA5
#define SPI_MOSI_LAT         LATAbits.LATA5

#define SPI_MISO_TRIS        TRISAbits.TRISA6
#define SPI_MISO_ANSEL       ANSELAbits.ANSELA6
#define SPI_MISO_PORT        PORTAbits.RA6

#define SPI_CLK_TRIS         TRISAbits.TRISA7
#define SPI_CLK_ANSEL        ANSELAbits.ANSELA7
#define SPI_CLK_LAT          LATAbits.LATA7
#define SPI_CLK_PORT         PORTAbits.RA7

/* ---------------------------------------------------------------------------
 * SPI chip selects (RA0–RA4) — one per consumer, all active-low.
 *
 * Rule: assert exactly one CS at a time.  Always deassert (idle) before
 * switching to a different consumer or reconfiguring the SPI clock rate.
 *
 * RA0  BULK_CS        SIO1/A — Bulk channel (bulk data transfers)
 * RA1  CMD_CS         SIO1/B — Command channel (command/control/events)
 * RA3  USB_BRIDGE_CS  USB-to-SPI bridge (keyboard HID reports)
 * RA4  SD_CS          SD card (sector read/write)
 * --------------------------------------------------------------------------- */
#define BULK_CS_TRIS    TRISAbits.TRISA0
#define BULK_CS_ANSEL   ANSELAbits.ANSELA0
#define BULK_CS_LAT     LATAbits.LATA0
#define BULK_CS_ASSERTED 0
#define BULK_CS_IDLE     1

#define CMD_CS_TRIS    TRISAbits.TRISA1
#define CMD_CS_ANSEL   ANSELAbits.ANSELA1
#define CMD_CS_LAT     LATAbits.LATA1
#define CMD_CS_ASSERTED 0
#define CMD_CS_IDLE     1

#define USB_BRIDGE_CS_TRIS   TRISAbits.TRISA3
#define USB_BRIDGE_CS_ANSEL  ANSELAbits.ANSELA3
#define USB_BRIDGE_CS_LAT    LATAbits.LATA3
#define USB_BRIDGE_CS_ASSERTED 0
#define USB_BRIDGE_CS_IDLE     1

#define SD_CS_TRIS           TRISAbits.TRISA4
#define SD_CS_ANSEL          ANSELAbits.ANSELA4
#define SD_CS_LAT            LATAbits.LATA4
#define SD_CS_ASSERTED       0
#define SD_CS_IDLE           1

/* ---------------------------------------------------------------------------
 * USB bridge interrupt (RA2) — input
 *
 * RA2  USB_INT   active-low input from USB-to-SPI bridge.
 *                Bridge asserts this line when a new HID report is ready.
 *                Used to avoid polling the bridge when the keyboard is idle.
 * --------------------------------------------------------------------------- */
#define USB_INT_TRIS         TRISAbits.TRISA2
#define USB_INT_ANSEL        ANSELAbits.ANSELA2
#define USB_INT_PORT         PORTAbits.RA2
#define USB_INT_ACTIVE       0   /* low = bridge has data ready */

/* ---------------------------------------------------------------------------
 * Z80 SIO RTS inputs (RF1, RF2) — active-low inputs
 *
 * The Z80 SIO asserts RTS (pin goes low) when it wants the MCU to service
 * a transaction.  The MCU detects the falling edge and sets a service flag.
 *
 * RF1  SIO_CMD_RTS    SIO1/B Command channel RTS — Z80 requests Command transaction
 * RF2  SIO_BULK_RTS   SIO1/A Bulk channel RTS — Z80 requests Bulk transaction
 * --------------------------------------------------------------------------- */
#define SIO_CMD_RTS_TRIS   TRISFbits.TRISF1
#define SIO_CMD_RTS_ANSEL  ANSELFbits.ANSELF1
#define SIO_CMD_RTS_PORT   PORTFbits.RF1
#define SIO_CMD_RTS_ACTIVE 0   /* low = Z80 is requesting Command channel service */

#define SIO_BULK_RTS_TRIS   TRISFbits.TRISF2
#define SIO_BULK_RTS_ANSEL  ANSELFbits.ANSELF2
#define SIO_BULK_RTS_PORT   PORTFbits.RF2
#define SIO_BULK_RTS_ACTIVE 0   /* low = Z80 is requesting Bulk channel service */

#endif /* CONFIG_H */

#pragma config FEXTOSC = OFF
#pragma config RSTOSC = HFINTOSC_64MHZ
#pragma config CLKOUTEN = OFF
#pragma config PPS1WAY = OFF
#pragma config WDTE = OFF
#pragma config LVP = ON
