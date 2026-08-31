#ifndef BULK_CHANNEL_H
#define BULK_CHANNEL_H

#include <stdint.h>
#include <stdbool.h>
#include "ioc_frame.h"

/* Bulk lane: SIO1/A, ports 30h/31h on the Z80 side.
 *
 * The two SIO channels are one transport with two lanes.  SIO1/B carries the
 * command/READY lifecycle, while SIO1/A carries larger DATA.  Both use the
 * same A5/5A common packet, metadata checks, CRC, and persistent External Sync.
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

/* Every bulk payload is carried by the same packet envelope as the command
 * lane, including TYPE, SEQ, STATUS and a CRC-16 trailer.
 *
 * The command lane validates four header fields; the bulk lane had NOTHING --
 * a corrupted block was indistinguishable from a good one at both ends, and
 * silently written to the card.  Lengths quoted in READY and passed to the arm
 * functions are DATA bytes; the wire also carries marker, header and CRC. */
#define BULK_CRC_BYTES       2u

/* Longest transfer either direction will carry.  One SD block. */
#define BULK_MAX_LENGTH      512u

/* Both directions use the transport-wide packet marker.  The MCU still searches
 * it at arbitrary bit phase when receiving because it supplies the clock but
 * cannot know which edge the Z80 transmitter began on. */
#define BULK_RX_PREAMBLE_0   IOC_PACKET_SYNC0
#define BULK_RX_PREAMBLE_1   IOC_PACKET_SYNC1

/* Called after a Z80 -> MCU payload has been received and de-shifted, to
 * commit it -- write it to the card, and so on.  Returns the IOC_STATUS_* the
 * DONE query should report.  Keeping this a callback keeps SD knowledge out of
 * the transport. */
typedef uint8_t (*BulkCommitFn)(void);

/* Stage an MCU -> Z80 transfer to run after the current reply is sent.
 * buf must stay valid until the transfer completes -- it runs in the same
 * foreground pass, so a static buffer is fine and a stack one is not. */
void bulk_channel_arm(const uint8_t *buf, uint16_t length, uint8_t xfer_id,
                      uint8_t type, uint8_t sequence, uint8_t status);

/* Stage a Z80 -> MCU transfer.  `buf` receives `length` de-shifted bytes, then
 * `commit` runs and its return becomes the DONE status.  commit may be NULL,
 * in which case a clean receive reports IOC_STATUS_OK.
 *
 * Unlike the send direction this cannot report success early: bytes arriving
 * says nothing about whether they were stored, so DONE is only meaningful
 * after commit has run.  A host writing MUST take the DONE round trip. */
void bulk_channel_arm_receive(uint8_t *buf, uint16_t length, uint8_t xfer_id,
                              uint8_t type, uint8_t sequence,
                              BulkCommitFn commit);

/* Drop the bulk lane's persistent External Sync so the next transfer
 * re-establishes the character boundary.  Called alongside the command lane's
 * equivalent: the two lanes are kept behaviourally identical apart from block
 * size, so they are also resynchronised together. */
void bulk_channel_request_resync(void);

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
/* Raw receive capture window, for bring-up diagnostics only.  Valid after a
 * Z80 -> MCU transfer; contents are the bytes exactly as clocked off the wire,
 * before any preamble search or bit de-shifting. */
const uint8_t *bulk_channel_rx_window(void);

/* Size of that window, so callers can bound a caller-selected slice. */
uint16_t bulk_channel_rx_window_size(void);

/* The buffer the last receive was armed into, so a diagnostic can peek at what
 * actually landed.  NULL if nothing has been armed for receive.
 *
 * XFER_STATUS used to peek a fixed buffer, which was correct while every bulk
 * receive used the same one.  Record transfers land somewhere else, so the
 * diagnostic reported eight zeroes from an untouched block buffer on exactly
 * the failures it existed to explain. */
const uint8_t *bulk_channel_rx_target(void);

uint8_t bulk_channel_last_xfer_id(void);
uint8_t bulk_channel_last_status(void);

/* External-Sync diagnostic snapshots returned by XFER_STATUS.  These are
 * observational only and do not release /SYNCA or alter persistent-sync state.
 * Bit definitions are documented beside IOC_OFF_DONE_BULK_SYNC_* in
 * ioc_frame.h. */
uint8_t bulk_channel_sync_decision(void);
uint8_t bulk_channel_sync_live(void);

#endif /* BULK_CHANNEL_H */
