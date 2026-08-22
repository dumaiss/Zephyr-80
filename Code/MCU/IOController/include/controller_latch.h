#ifndef CONTROLLER_LATCH_H
#define CONTROLLER_LATCH_H

#include <stdint.h>

/* Cascaded controller 74HC595 pair on the port C peripheral bus (SPI1).
 *
 * Two 8-bit devices in series, 16 bits total.  /CTRL_LAT_CS on RA1 is both the
 * select and the register clock: the 595 commits its shift register to the
 * output pins on RCLK's rising edge, which is the deselect edge.
 */

/* Bring up SPI1, the port C pins and the 500 ms bring-up timer. */
void controller_latch_init(void);

/* Shift two bytes into the cascaded 595s and latch them.
 *
 * byte0 is shifted first and therefore ends up in the FAR device of the chain;
 * byte1 lands in the near one.  Both are shifted most-significant bit first.
 * Blocking, for 16 SPI clocks.  Not ISR-safe. */
void controller_latch_write(uint8_t byte0, uint8_t byte1);

/* Bring-up counter.
 *
 * Call from the main loop.  Polls Timer2 and, every 500 ms, writes an
 * incrementing pair (n, n+1) to the latches so the count can be watched on the
 * monitor.  The counter is 8-bit and wraps at 255, which is harmless.
 *
 * Returns without doing anything if the 500 ms period has not elapsed, so it is
 * safe to call as often as the main loop runs. */
void controller_latch_tick(void);

#endif /* CONTROLLER_LATCH_H */
