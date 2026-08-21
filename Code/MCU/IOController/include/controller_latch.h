#ifndef CONTROLLER_LATCH_H
#define CONTROLLER_LATCH_H

#include <stdint.h>

/* Shift two bytes into the cascaded controller 74HC595s and latch them.
 * byte0 is shifted first; each byte is shifted most-significant bit first.
 * This routine borrows SIO_MOSI/SIO_SCK from the shared bus and is not
 * ISR-safe. */
void controller_latch_write(uint8_t byte0, uint8_t byte1);

#endif /* CONTROLLER_LATCH_H */
