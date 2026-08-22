#include "dispatch.h"
#include "handlers.h"
#include "ioc_frame.h"

bool dispatch_command(const IocFrame *request, IocFrame *reply)
{
    uint8_t cls = request->bytes[IOC_OFF_CLASS];

    switch (cls) {
    case CMD_PING:
        handler_ping(request, reply);
        return true;

    case CMD_SD_READ:
        handler_sd_read(request, reply);
        return true;

    case CMD_BULK_TEST:
        handler_bulk_test(request, reply);
        return true;

    case CMD_SD_READ_BULK:
        handler_sd_read_bulk(request, reply);
        return true;

    case CMD_XFER_STATUS:
        handler_xfer_status(request, reply);
        return true;

    case CMD_RESET:
        handler_reset();   /* does not return */
        return false;

    default:
        handler_unknown(request, reply);
        return true;
    }
}
