#ifndef BULK_CHANNEL_H
#define BULK_CHANNEL_H

#include <stdint.h>
#include <stdbool.h>

/* Bulk lane: SIO1/A, ports 30h/31h on the Z80 side.
 *
 * The two SIO channels are one transport with two lanes.  SIO1/B carries
 * commands and is authoritative about when this lane is valid and what the
 * bytes mean; this lane is a dumb byte pipe -- no headers, no escaping, no
 * terminator.  The command channel already supplied the framing.
 *
 * Lifecycle, driven from the command channel:
 *
 *      IDLE --command--> PREPARE --READY--> BULK_ACTIVE --len bytes--> IDLE
 *
 * A handler calls bulk_channel_arm() while building its READY reply.  The bulk
 * bytes must not be clocked until that reply has actually reached the host, so
 * the transfer is deferred: main runs bulk_channel_run_if_armed() immediately
 * after external_sync_send() returns.
 */

/* Direction codes reported in a READY reply. */
#define BULK_DIR_MCU_TO_Z80  0x00u
#define BULK_DIR_Z80_TO_MCU  0x01u

/* Stage a transfer to run after the current reply is sent.
 * buf must stay valid until the transfer completes -- it runs in the same
 * foreground pass, so a static buffer is fine and a stack one is not. */
void bulk_channel_arm(const uint8_t *buf, uint16_t length, uint8_t xfer_id);

/* Run a staged transfer, if any.  Returns false if the SPI module stalled.
 * Safe and cheap to call unconditionally. */
bool bulk_channel_run_if_armed(void);

/* Next transfer id.  Wraps at 255; zero is never issued so that a reply
 * carrying id 0 is recognisable as "no transfer". */
uint8_t bulk_channel_next_xfer_id(void);

/* Result of the most recent bulk phase, for the DONE query on the command lane.
 * id 0 means no transfer has run since reset.  A DONE carrying an id other than
 * the one the READY reported means something went sideways -- that is the whole
 * reason the id exists. */
uint8_t bulk_channel_last_xfer_id(void);
uint8_t bulk_channel_last_status(void);

#endif /* BULK_CHANNEL_H */
