#ifndef DISPATCH_H
#define DISPATCH_H

#include <stdbool.h>
#include "ioc_frame.h"

/* Dispatch a received Command-channel request frame.
 *
 * Inspects frame->bytes[IOC_OFF_CLASS] and calls the appropriate handler.
 * Fills *reply with a complete 32-byte response frame.
 *
 * Returns true  if a reply should be sent.
 * Returns false if no reply is expected (e.g. CMD_RESET, which is terminal).
 *
 * For CMD_RESET the function may not return.
 */
bool dispatch_command(const IocFrame *request, IocFrame *reply);

#endif /* DISPATCH_H */
