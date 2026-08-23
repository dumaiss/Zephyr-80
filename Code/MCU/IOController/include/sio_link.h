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

/* Which channel's External Sync strobe to drive. */
typedef enum {
    SIO_LINK_CH_COMMAND = 0,   /* SIO1/B -- /SYNCB */
    SIO_LINK_CH_BULK    = 1    /* SIO1/A -- /SYNCA */
} SioLinkChannel;

/* Hand-clock one byte, dropping that channel's /SYNC inside bit `drop_bit`.
 *
 * This is the one byte per transfer that cannot go through SPI2: the External
 * Sync strobe has to fall between a specific bit's rising and falling clock
 * edges, and a hardware shift register cannot be interrupted there.  Once
 * /SYNC is low it stays low, so every later byte can go out at full SPI speed.
 * The edge placement IS the electrical protocol -- treat this as timing-exact
 * code, not as a loop to tidy.
 *
 * The waveform is identical for both channels: no trailing gap on bits 0 and 1,
 * one on bits 2-7, and /SYNC asserted between the rising and falling edge of
 * bit `drop_bit`.
 *
 * drop_bit differs per channel and that is a HARDWARE asymmetry, not a
 * workaround for a configuration difference.  Channel B wants 1, channel A
 * wants 0.  Every software cause was eliminated on 2026-08-23 -- identical WR3
 * (tested), identical WR4, identical setup clocks, identical bit-bang shape,
 * and clock gate-open timing ruled out by test.  See bulk_channel.c for the
 * full record and for the measurement that would explain the remaining bit. */
void sio_link_clock_sync_byte(uint8_t value, SioLinkChannel channel,
                              uint8_t drop_bit);

#endif /* SIO_LINK_H */
