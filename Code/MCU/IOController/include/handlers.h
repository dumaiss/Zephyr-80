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

/* Unknown command fallback: fills *reply with RSP_UNKNOWN_COMMAND. */
void handler_unknown(const IocFrame *request, IocFrame *reply);

#endif /* HANDLERS_H */
