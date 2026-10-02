#include <zephyr/fs.h>
#include "shell.h"

const char *zsh_status_text(uint8_t status)
{
    switch (status) {
    case ZEP_FS_OK: return "ok";
    case ZEP_FS_END: return "end of directory";
    case ZEP_FS_NOT_FOUND: return "not found";
    case ZEP_FS_EXISTS: return "already exists";
    case ZEP_FS_BAD_NAME: return "bad 8.3 name";
    case ZEP_FS_READ_ONLY: return "read only";
    case ZEP_FS_NO_SPACE: return "no space";
    case ZEP_FS_NOT_DIR: return "not a directory";
    case ZEP_FS_IS_DIR: return "is a directory";
    case ZEP_FS_NO_HANDLE: return "no file handle";
    case ZEP_FS_STALE: return "stale handle";
    case ZEP_FS_RANGE: return "out of range";
    case ZEP_FS_NO_MEDIA: return "no media";
    case ZEP_FS_TRANSPORT: return "transport error";
    case ZEP_FS_UNKNOWN_WRITE: return "write completion unknown";
    case ZEP_FS_IO: return "I/O error";
    case ZEP_FS_UNSUPPORTED: return "unsupported";
    default: return "unknown status";
    }
}

void zsh_error_status(const char *command, const char *path, uint8_t status)
{
    zsh_puts(command);
    if (path && *path) { zsh_puts(": "); zsh_puts(path); }
    zsh_puts(": "); zsh_puts(zsh_status_text(status));
    zsh_puts(" (FS2 "); zsh_print_hex8(status); zsh_puts(")\n");
    if (status == ZEP_FS_UNKNOWN_WRITE) {
        zsh_puts(command);
        zsh_puts(": write completion unknown; destination may have changed\n");
    }
}
