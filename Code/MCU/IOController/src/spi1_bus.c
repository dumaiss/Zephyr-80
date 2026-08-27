#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "config.h"
#include "spi1_bus.h"

/* Bounded wait for one SPI byte.  A module that never completes must not wedge
 * the PIC in a spin loop until reset.  One byte at the slowest rate used here
 * (200 kHz) is 40 us, about 640 instruction cycles at 64 MHz. */
#define SPI1_TIMEOUT_LOOPS 20000u

void spi1_bus_select(Spi1BusDevice device)
{
    /* Break-before-make, always.  Even if a caller arrives with stale state,
     * no two devices can remain selected while ownership changes. */
    CTRL_LAT_CS_LAT = CTRL_LAT_CS_IDLE;
    IO_SD_CS_LAT    = IO_SD_CS_IDLE;
    IO_USB_CS_LAT   = IO_USB_CS_IDLE;

    switch (device) {
    case SPI1_DEVICE_CONTROLLER_LATCH:
        CTRL_LAT_CS_LAT = CTRL_LAT_CS_ASSERTED;
        break;
    case SPI1_DEVICE_SD_CARD:
        IO_SD_CS_LAT = IO_SD_CS_ASSERTED;
        break;
    case SPI1_DEVICE_USB:
        IO_USB_CS_LAT = IO_USB_CS_ASSERTED;
        break;
    case SPI1_DEVICE_NONE:
    default:
        break;
    }
}

void spi1_bus_init(void)
{
    /* Own all three selects centrally.  Park their latches before enabling the
     * output drivers so startup cannot briefly select two devices. */
    CTRL_LAT_CS_ANSEL = 0;
    IO_SD_CS_ANSEL    = 0;
    IO_USB_CS_ANSEL   = 0;
    spi1_bus_select(SPI1_DEVICE_NONE);
    CTRL_LAT_CS_TRIS = 0;
    IO_SD_CS_TRIS    = 0;
    IO_USB_CS_TRIS   = 0;

    /* Port C bus pins are digital; RC3/RC5 drive, RC4 listens. */
    PERIPH_SCK_ANSEL  = 0;
    PERIPH_MISO_ANSEL = 0;
    PERIPH_MOSI_ANSEL = 0;

    PERIPH_SCK_LAT   = 0;
    PERIPH_SCK_TRIS  = 0;
    PERIPH_MOSI_LAT  = 0;
    PERIPH_MOSI_TRIS = 0;
    PERIPH_MISO_TRIS = 1;

    PERIPH_SCK_PPS  = PERIPH_PPS_SRC_SPI1_SCK;
    PERIPH_MOSI_PPS = PERIPH_PPS_SRC_SPI1_SDO;

    SPI1CON0 = 0x00;
    SPI1CON0bits.MST   = 1;   /* master: the PIC supplies every clock edge */
    SPI1CON0bits.BMODE = 1;   /* SPI1TWIDTH = 0 (reset) => full-byte transfers */

    SPI1CON1 = 0x00;
    SPI1CON1bits.CKP = 0;     /* clock idles low                              */
    SPI1CON1bits.CKE = 1;     /* data changes on the falling edge -> Mode 0.  */
    SPI1CON1bits.SMP = 0;     /* Both the 74HC595 and SD cards in SPI mode    */
                              /* sample on the rising edge, so Mode 0 suits   */
                              /* every device on this bus.                    */

    SPI1CON2 = 0x00;
    SPI1CON2bits.TXR = 1;     /* a write to SPI1TXB starts a transfer         */
    SPI1CON2bits.RXR = 1;     /* and the byte lands in SPI1RXB, which is what */
                              /* makes SPI1RXIF a completion signal           */

    SPI1CLK = 0x00;           /* Fosc; CLKSEL 00000 per Table 36-5 */

    spi1_bus_configure(SPI1_BAUD_1MHZ, SPI1_MSB_FIRST);
}

void spi1_bus_configure(uint8_t baud, uint8_t lsb_first)
{
    /* Clearing EN resets both FIFOs, so reconfiguring is also the flush. */
    SPI1CON0bits.EN = 0;

    SPI1CON0bits.LSBF = (lsb_first != 0u) ? 1 : 0;
    SPI1BAUD = baud;

    SPI1CON0bits.EN = 1;
    PIR3bits.SPI1RXIF = 0;
}

bool spi1_bus_transfer(uint8_t out, uint8_t *in)
{
    uint16_t guard = SPI1_TIMEOUT_LOOPS;

    SPI1TXB = out;

    while (!PIR3bits.SPI1RXIF) {
        if (--guard == 0u)
            return false;
    }

    *in = SPI1RXB;
    return true;
}

bool spi1_bus_write(uint8_t out)
{
    uint8_t discard;

    return spi1_bus_transfer(out, &discard);
}
