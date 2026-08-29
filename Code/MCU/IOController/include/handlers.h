#ifndef HANDLERS_H
#define HANDLERS_H

#include "ioc_frame.h"

/* PING: echo sequence, status OK, and test-pattern payload.
 * Fills *reply.  Always returns. */
void handler_ping(const IocFrame *request, IocFrame *reply);

/* RESET: assert host reset pair and self-reset the MCU.
 * This function does not return under normal circumstances. */
void handler_reset(void);

/* SD_READ: read block 0 from the SD card and return its first
 * IOC_SD_READ_BYTES bytes in the reply payload.  Blocking -- the first call
 * also runs card initialisation, which can take about a second.
 * Fills *reply.  Always returns. */
void handler_sd_read(const IocFrame *request, IocFrame *reply);

/* BULK_TEST: channel-A bring-up.  Replies READY with a transfer id, direction
 * and length, then streams a 00 01 02 ... ramp of that length on SIO1/A.
 * Request payload bytes 0-1 give the length (little-endian); 0 means 256.
 * Fills *reply and stages the bulk phase.  Always returns. */
void handler_bulk_test(const IocFrame *request, IocFrame *reply);

/* SD_READ_BULK: read one 512-byte sector and hand it to the bulk lane.
 * Request payload bytes 0-3 are a 32-bit little-endian LBA.
 *
 * The card is read into SRAM BEFORE the READY reply, so SD latency is out of
 * the bulk transaction and the SIO1/A transfer is fast and deterministic.
 * On a card failure no bulk phase is staged and READY reports length 0 with an
 * SD status, so the host knows not to enter its read loop.
 * Fills *reply and stages the bulk phase.  Always returns. */
void handler_sd_read_bulk(const IocFrame *request, IocFrame *reply);

/* XFER_STATUS: the DONE query.  Returns the id and completion status of the
 * most recent bulk phase.  A DONE id that does not match the READY id means a
 * transfer was lost or overlapped. */
void handler_sd_write_bulk(const IocFrame *request, IocFrame *reply);
void handler_link_sync(const IocFrame *request, IocFrame *reply);
void handler_profile(const IocFrame *request, IocFrame *reply);
/* HID_STATUS: read-only MAX3421E bring-up snapshot.  Does not service USB. */
void handler_hid_status(const IocFrame *request, IocFrame *reply);
void handler_xfer_status(const IocFrame *request, IocFrame *reply);

/* Unknown command fallback: fills *reply with RSP_UNKNOWN_COMMAND. */
void handler_sd_read_rec(const IocFrame *request, IocFrame *reply);
void handler_sd_write_rec(const IocFrame *request, IocFrame *reply);
void handler_sd_flush(const IocFrame *request, IocFrame *reply);

void handler_unknown(const IocFrame *request, IocFrame *reply);

#endif /* HANDLERS_H */
