#ifndef HANDLERS_H
#define HANDLERS_H

#include "ioc_frame.h"

/* PING: echo sequence, status OK, and test-pattern payload.
 * Fills *reply.  Always returns. */
void handler_ping(const IocFrame *request, IocFrame *reply);

/* RESET: assert host reset pair and self-reset the MCU.
 * This function does not return under normal circumstances. */
void handler_reset(void);

/* Unknown command fallback: fills *reply with RSP_UNKNOWN_COMMAND. */
void handler_unknown(const IocFrame *request, IocFrame *reply);

#endif /* HANDLERS_H */
