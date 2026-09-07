#ifndef FS_SHARE_H
#define FS_SHARE_H

#include <stdint.h>
#include <stdbool.h>

#include "ioc_frame.h"

/* /SHARED/ -- one directory on the SD card that CP/M user space can list, read
 * and write.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS IS NOT
 * ---------------------------------------------------------------------------
 *
 * Not a BIOS feature, not a drive letter, not on any hot path.  A transient
 * drives it through the published IOCALL / IOCBULK / IOCBULKW entries, exactly
 * as IOC_SDREC.COM and HIDSTAT.COM already do, so this costs no BIOS code, no
 * jump-table entry and no memory-map change.
 *
 * ---------------------------------------------------------------------------
 * TWO RULES THAT ARE LOAD-BEARING
 * ---------------------------------------------------------------------------
 *
 * 1. THE CONTROLLER BUILDS THE PATH, NEVER THE CALLER.
 *
 *    The firmware prepends /SHARED/ and rejects any name carrying a separator
 *    or a traversal.  That is not hypothetical hardening: the same card holds
 *    the boot images, and a caller-supplied path is the one way a user program
 *    could reach them -- which would also break the extent-map invariant in
 *    volume.h, silently.
 *
 * 2. EVERY DATA COMMAND IS CAPPED AT 512 BYTES.
 *
 *    hid_host_task() runs only on the idle branch of the main loop, after any
 *    command in flight has fully completed.  A "copy this whole file" command
 *    would therefore hold USB off for the length of the copy, and the keyboard
 *    would drop keystrokes exactly while somebody is watching a transfer.
 *    Chunking returns to the loop between pieces and keeps HID alive.
 *
 * ---------------------------------------------------------------------------
 * HOUSEKEEPING
 * ---------------------------------------------------------------------------
 *
 * One directory session and one file handle.  The controller serves one command
 * at a time and there is one Z80, so more would be state without a user.
 * CMD_FS_OPEN implicitly closes whatever was open, so a transient that dies
 * mid-copy cannot leak the handle, and CMD_FS_CLOSE flushes the cache so FAT
 * and directory updates do not sit dirty behind a write-back timer.
 */

void fs_share_init(void);

void handler_fs_opendir(const IocFrame *request, IocFrame *reply);
void handler_fs_readdir(const IocFrame *request, IocFrame *reply);
void handler_fs_open(const IocFrame *request, IocFrame *reply);
void handler_fs_read(const IocFrame *request, IocFrame *reply);
void handler_fs_write(const IocFrame *request, IocFrame *reply);
void handler_fs_close(const IocFrame *request, IocFrame *reply);
void handler_fs_stat(const IocFrame *request, IocFrame *reply);
void handler_fs_delete(const IocFrame *request, IocFrame *reply);

/* Mount, walk /SHARED/, and checksum one file.  Proves FatFs works on this
 * build before anything is trusted to it -- the cheap insurance against XC8's
 * overlay allocator, which has six silent corruptions to its name in the
 * TinyUSB path already. */
void handler_fs_selftest(const IocFrame *request, IocFrame *reply);

#endif /* FS_SHARE_H */
