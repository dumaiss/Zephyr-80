#ifndef CONTROLLER_LATCH_H
#define CONTROLLER_LATCH_H

#include <stdint.h>

/* Cascaded controller 74HC595 pair on the port C peripheral bus (SPI1).
 *
 * Two 8-bit devices in series, 16 bits total.  /CTRL_LAT_CS on RA1 is both the
 * select and the register clock: the 595 commits its shift register to the
 * output pins on RCLK's rising edge, which is the deselect edge.
 */

/* Diagnostic only.  Leave disabled during SD-card bring-up: when enabled it
 * deliberately creates periodic MOSI/SCK traffic on the shared SPI1 bus. */
#ifndef CONTROLLER_LATCH_COUNTER_TEST
#define CONTROLLER_LATCH_COUNTER_TEST 0
#endif

/* Initialise the latch outputs to zero.  spi1_bus_init() owns the bus pins. */
void controller_latch_init(void);

/* Shift two bytes into the cascaded 595s and latch them.
 *
 * byte0 is shifted first and therefore ends up in the FAR device of the chain;
 * byte1 lands in the near one.  Both are shifted most-significant bit first.
 * Blocking, for 16 SPI clocks.  Not ISR-safe. */
void controller_latch_write(uint8_t byte0, uint8_t byte1);

/* Optional bring-up counter.
 *
 * When CONTROLLER_LATCH_COUNTER_TEST is 1, call from the main loop to write an
 * incrementing pair (n, n+1) every 500 ms.  The counter is disabled by default
 * so an idle controller produces no shared-bus clocks during SD-card bring-up.
 *
 * With the test disabled this routine is an empty stub. */
void controller_latch_tick(void);

#endif /* CONTROLLER_LATCH_H */
