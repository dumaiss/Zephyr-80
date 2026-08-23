#ifndef SIO_LINK_H
#define SIO_LINK_H

#include <stdint.h>
#include <stdbool.h>

/* Low-level SPI2 primitives for the Z80 SIO bus, implemented in
 * external_sync.c and shared with the bulk channel.
 *
 * Both SIO1 channels hang off the same SPI2 module and the same RB1/RB3 pins;
 * only the select and the External Sync strobe differ.  These are exposed so
 * the bulk lane can drive channel A without duplicating the module setup or
 * the PPS hand-over, and without any change to the proven command path.
 *
 * Not a general-purpose API: callers must own the bus (assert a select) and
 * must return the pins to LAT before releasing it.
 */

/* Hand RB1/RB3 between LATB and the SPI2 module.  Glitch-free in both
 * directions: CKP = 0 idles SCK low, which is the level LATB3 holds. */
void sio_link_pins_to_lat(void);
void sio_link_pins_to_spi(void);

/* Set the SPI2 clock for the lane about to transact.
 *
 * The two lanes run at different rates -- the command lane is paced by the
 * BIOS receive loop, the bulk lane by the host's inlined one -- so each sets
 * the baud it needs before its transfer.  Safe because the foreground loop
 * never interleaves them.  Toggling EN also empties both FIFOs. */
void sio_link_set_baud(uint8_t baud);

/* Empty both FIFOs and clear the receive flag.  Every transaction should start
 * with this; a stale byte left by an aborted transfer shifts everything after
 * it by one position. */
void sio_link_clear_fifos(void);

/* Exchange one byte.  False if the module did not complete in time.
 * Completion is SPI2RXIF, never SPI2STATUS.RXBF -- RXBF means the 2-byte FIFO
 * is *full*, so it never sets for a single-byte exchange. */
bool sio_link_exchange(uint8_t out, uint8_t *in);

/* Hold the byte rate the Z80's polled receive loop can sustain.
 * See EXTSYNC_TARGET_BYTE_US in external_sync.h for the T-state budget. */
void sio_link_byte_gap(void);

/* Put one bit on SIO_MOSI via LATB (bit-banged phase only). */
void sio_link_write_data_bit(uint8_t bit);

#endif /* SIO_LINK_H */
