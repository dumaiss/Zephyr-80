#include "dispatch.h"
#include "handlers.h"
#include "ioc_frame.h"
#if IOC_FS_COMMANDS
#include "fs_share.h"
#endif

bool dispatch_command(const IocFrame *request, IocFrame *reply)
{
    uint8_t cls = request->bytes[IOC_OFF_CLASS];

#if IOC_FS_COMMANDS
    /* Shared folder, user space only.  Confined to /SHARED/ by fs_share.c. */
    switch (cls) {
    case CMD_FS_OPENDIR:  handler_fs_opendir(request, reply);  return true;
    case CMD_FS_READDIR:  handler_fs_readdir(request, reply);  return true;
    case CMD_FS_OPEN:     handler_fs_open(request, reply);     return true;
    case CMD_FS_READ:     handler_fs_read(request, reply);     return true;
#if !FF_FS_READONLY
    case CMD_FS_WRITE:    handler_fs_write(request, reply);    return true;
#endif
    case CMD_FS_CLOSE:    handler_fs_close(request, reply);    return true;
    case CMD_FS_STAT:     handler_fs_stat(request, reply);     return true;
    case CMD_FS_DELETE:   handler_fs_delete(request, reply);   return true;
    case CMD_FS_SELFTEST: handler_fs_selftest(request, reply); return true;
    default: break;
    }
#endif

    switch (cls) {
    case CMD_VOL_MOUNT:
        handler_vol_mount(request, reply);
        return true;

    case CMD_VOL_INFO:
        handler_vol_info(request, reply);
        return true;

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

/* Bisect switch.  With IOC_FS_COMMANDS=0 nothing in this firmware references
 * FatFs, so the linker strips ff.c entirely -- which is the point: it separates
 * "the filesystem code is wrong" from "linking FatFs at all is what breaks
 * this build".  Those need completely different fixes, and on a controller
 * whose failure mode is a reset loop there is no other way to tell them apart.
 *
 * The record path, the volume layer in raw mode, and every pre-existing
 * command are unaffected either way. */
    case CMD_RESET:
        handler_reset();   /* does not return */
        return false;

    default:
        handler_unknown(request, reply);
        return true;
    }
}
