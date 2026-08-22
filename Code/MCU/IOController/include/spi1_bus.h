#ifndef SPI1_BUS_H
#define SPI1_BUS_H

#include <stdint.h>
#include <stdbool.h>

/* Port C external peripheral bus (SPI1).
 *
 * Shared by the controller latch, the SD card and (later) the USB HID bridge,
 * with per-device selects on port A.  The devices do not agree on clock rate,
 * so each one calls spi1_bus_configure() before asserting its select.  That is
 * safe because the firmware is a single foreground loop: transactions never
 * interleave.
 *
 * SPI1SCKPPS and SPI1SDIPPS are left at their reset values -- they already
 * select RC3 and RC4, which is how this board is wired.  Only the two output
 * routes are claimed.
 */

/* Baud divider values for SPI1CLK = 0 (Fosc): SCK = 64 MHz / (2 * (BAUD + 1)). */
#define SPI1_BAUD_400KHZ   79u    /* 64 MHz / 160 = 400 kHz */
#define SPI1_BAUD_200KHZ   159u   /* 64 MHz / 320 = 200 kHz */
#define SPI1_BAUD_1MHZ     31u    /* 64 MHz /  64 = 1.000 MHz */

#define SPI1_MSB_FIRST     0u
#define SPI1_LSB_FIRST     1u

/* Claim RC3/RC4/RC5, route the SPI1 outputs and enable the module.
 * Call once at start-up, before any device driver. */
void spi1_bus_init(void);

/* Set the clock rate and bit order for the next transaction.
 *
 * The module is briefly disabled across the change, which also empties both
 * FIFOs -- so this doubles as the flush every transaction should start with. */
void spi1_bus_configure(uint8_t baud, uint8_t lsb_first);

/* Exchange one byte.  Returns false if the module did not complete in time.
 *
 * Completion is SPI1RXIF, never SPI1STATUS.RXBF: RXBF means the 2-byte receive
 * FIFO is *full*, so it never sets for a single-byte exchange. */
bool spi1_bus_transfer(uint8_t out, uint8_t *in);

/* Shorthand for a write where the returned byte is not interesting. */
bool spi1_bus_write(uint8_t out);

#endif /* SPI1_BUS_H */
