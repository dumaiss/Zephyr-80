#include "dispatch.h"
#include "handlers.h"
#include "ioc_frame.h"
#include "trace.h"

bool dispatch_command(const IocFrame *request, IocFrame *reply)
{
    uint8_t cls = request->bytes[IOC_OFF_CLASS];
    uint8_t seq = request->bytes[IOC_OFF_SEQ];

    dbg_last_cmd = cls;
    dbg_last_seq = seq;
    TRACE(TRACE_DISPATCH_CMD, cls, seq, 0);

    switch (cls) {
    case CMD_PING:
        handler_ping(request, reply);
        return true;

    case CMD_RESET:
        handler_reset();   /* does not return */
        return false;

    default:
        TRACE(TRACE_UNKNOWN_CMD, cls, 0, 0);
        handler_unknown(request, reply);
        return true;
    }
}
