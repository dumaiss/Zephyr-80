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

#if IOC_DIAGNOSTIC_BUILD
    /* Bring-up and benchmark paths.  Absent from a normal build, where they
     * fall through to handler_unknown() and are rejected explicitly -- which is
     * the designed answer for a class this firmware does not implement, and is
     * distinguishable from a transport fault.
     *
     * Their CP/M callers (BULK, SDBLK, SDWRITE, SDBENCH) already ship only on
     * the diagnostic ROM profile, so a normal rescue disk cannot reach them. */
    case CMD_BULK_TEST:
        handler_bulk_test(request, reply);
        return true;

    case CMD_SD_READ_BULK:
        handler_sd_read_bulk(request, reply);
        return true;

    case CMD_SD_WRITE_BULK:
        handler_sd_write_bulk(request, reply);
        return true;
#endif

    case CMD_SD_READ_REC:
        handler_sd_read_rec(request, reply);
        return true;

    case CMD_SD_WRITE_REC:
        handler_sd_write_rec(request, reply);
        return true;

    case CMD_LINK_SYNC:
        handler_link_sync(request, reply);
        return true;

#if IOC_DIAGNOSTIC_BUILD
    case CMD_PROFILE:
        handler_profile(request, reply);
        return true;
#endif

    case CMD_HID_STATUS:
        handler_hid_status(request, reply);
        return true;

    case CMD_HID_INPUT:
        handler_hid_input(request, reply);
        return true;

    case CMD_SD_FLUSH:
        handler_sd_flush(request, reply);
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
