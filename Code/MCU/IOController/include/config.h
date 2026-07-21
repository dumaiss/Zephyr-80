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
 * IO Controller External Sync serial pins
 *
 * RA5  IOC_TXD   output   PIC -> Z80 SIO1/B RXDB
 * RA6  IOC_RXD   input    PIC <- Z80 SIO1/B TXDB
 * RA7  IOC_CLK   output   PIC -> Z80 SIO1/B RXTXCB
 * --------------------------------------------------------------------------- */
#define IOC_TXD_TRIS         TRISAbits.TRISA5
#define IOC_TXD_ANSEL        ANSELAbits.ANSELA5
#define IOC_TXD_LAT          LATAbits.LATA5
#define IOC_TXD_PORT         PORTAbits.RA5

#define IOC_RXD_TRIS         TRISAbits.TRISA6
#define IOC_RXD_ANSEL        ANSELAbits.ANSELA6
#define IOC_RXD_PORT         PORTAbits.RA6

#define IOC_CLK_TRIS         TRISAbits.TRISA7
#define IOC_CLK_ANSEL        ANSELAbits.ANSELA7
#define IOC_CLK_LAT          LATAbits.LATA7
#define IOC_CLK_PORT         PORTAbits.RA7

/* ---------------------------------------------------------------------------
 * Shared control pins on Port A
 *
 * RA1 is the active command-link control pin.  It drives both the SIO1/B
 * /SYNCB External Sync input and the 74HC125 /OE for SIO TXDB -> PIC RXD.
 *
 * The other Port A selects are held idle so inactive hardware never sees an
 * accidental select while RA7 is clocking SIO1/B.
 * --------------------------------------------------------------------------- */
#define UNUSED_RA0_TRIS       TRISAbits.TRISA0
#define UNUSED_RA0_ANSEL      ANSELAbits.ANSELA0
#define UNUSED_RA0_LAT        LATAbits.LATA0
#define UNUSED_RA0_IDLE       1

#define IOC_SYNC_TRIS         TRISAbits.TRISA1
#define IOC_SYNC_ANSEL        ANSELAbits.ANSELA1
#define IOC_SYNC_LAT          LATAbits.LATA1
#define IOC_SYNC_ASSERTED     0
#define IOC_SYNC_IDLE         1

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
 * Z80 SIO1/B RTS input (RF1) — active-low
 *
 * The Z80 BIOS asserts RTSB when it wants one command transaction.
 * --------------------------------------------------------------------------- */
#define SIO_CMD_RTS_TRIS   TRISFbits.TRISF1
#define SIO_CMD_RTS_ANSEL  ANSELFbits.ANSELF1
#define SIO_CMD_RTS_PORT   PORTFbits.RF1
#define SIO_CMD_RTS_ACTIVE 0   /* low = Z80 is requesting Command channel service */

#endif /* CONFIG_H */

#pragma config FEXTOSC = OFF
#pragma config RSTOSC = HFINTOSC_64MHZ
#pragma config CLKOUTEN = OFF
#pragma config JTAGEN = OFF
#pragma config PPS1WAY = OFF
#pragma config WDTE = OFF
#pragma config LVP = ON
