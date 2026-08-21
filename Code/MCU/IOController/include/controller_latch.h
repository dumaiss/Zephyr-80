#ifndef CONTROLLER_LATCH_H
#define CONTROLLER_LATCH_H

#include <stdint.h>

/* Shift two bytes into the cascaded controller 74HC595s and latch them.
 * byte0 is shifted first; each byte is shifted most-significant bit first.
 *
 * Currently a no-op.  The 595s live on the port C peripheral bus, which is not
 * brought up yet; see src/controller_latch.c for why this is stubbed rather
 * than left pointed at the SIO bus. */
void controller_latch_write(uint8_t byte0, uint8_t byte1);

#endif /* CONTROLLER_LATCH_H */
