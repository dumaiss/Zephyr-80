#ifndef ZSH_HOST_TEST
#include <cpm.h>
#endif
#include <string.h>
#include <zephyr/fs.h>
#include "exec.h"
#include "path.h"
#include "shell.h"

#define ZSH_NATIVE_EXEC_BDOS 219
#define ZSH_COM_LIMIT 0xeb00UL

#ifndef ZSH_HOST_TEST
static uint8_t loader_descriptor[32];
#endif

static uint8_t upper(uint8_t c)
{
    return (c >= 'a' && c <= 'z') ? (uint8_t)(c - ('a' - 'A')) : c;
}

static uint8_t make_exec_name(const char *command, char name[13])
{
    uint8_t n = 0;
    uint8_t has_dot = 0;
    while (*command) {
        if (*command == '/' || *command == '\\' || *command == ':')
            return 0;
        if (n == 12)
            return 0;
        if (*command == '.')
            has_dot = 1;
        name[n++] = (char)upper((uint8_t)*command++);
    }
    if (!n)
        return 0;
    if (!has_dot) {
        if (n > 8)
            return 0;
        name[n++] = '.';
        name[n++] = 'C';
        name[n++] = 'O';
        name[n++] = 'M';
    }
    name[n] = 0;
    return 1;
}

zep_fs_status_t zsh_exec_open_path(const char *command, char name[13],
                                   zep_fs_stat_t *info,
                                   zep_fs_handle_t *handle)
{
    zsh_path_scope_t scope;
    zep_fs_status_t status;
    zep_fs_status_t restore;

    if (!command || !name || !info || !handle)
        return ZEP_FS_RANGE;
    status = zsh_path_enter_parent(command, &scope);
    if (status != ZEP_FS_OK)
        return status;
    if (!make_exec_name(scope.leaf, name))
        status = ZEP_FS_BAD_NAME;
    else {
        status = zep_fs_stat(name, info);
        if (status == ZEP_FS_OK &&
            (info->flags & ZEP_FS_FLAG_DIRECTORY))
            status = ZEP_FS_IS_DIR;
        if (status == ZEP_FS_OK)
            status = zep_fs_open(name, ZEP_FS_OPEN_READ, handle);
    }
    restore = zsh_path_leave(&scope);
    if (restore != ZEP_FS_OK && status == ZEP_FS_OK) {
        (void)zep_fs_close(*handle);
        return restore;
    }
    return status;
}

#ifndef ZSH_HOST_TEST

static void pack_default_fcb(uint8_t *fcb, const char *arg)
{
    uint8_t base = 0;
    uint8_t ext = 0;
    uint8_t in_ext = 0;
    uint8_t c;

    memset(fcb, 0, 36);
    memset(fcb + 1, ' ', 11);
    if (!arg)
        return;
    while ((c = (uint8_t)*arg++) != 0) {
        if (c == '/' || c == '\\' || c == ':') {
            memset(fcb + 1, ' ', 11);
            return;
        }
        if (c == '.' && !in_ext) {
            in_ext = 1;
            continue;
        }
        c = upper(c);
        if (!in_ext) {
            if (base < 8)
                fcb[1 + base++] = c;
        } else if (ext < 3) {
            fcb[9 + ext++] = c;
        }
    }
}

static void prepare_page_zero(uint8_t argc, char **argv)
{
    uint8_t *tail = (uint8_t *)0x0080;
    uint8_t *first_fcb = (uint8_t *)0x005c;
    uint8_t *second_fcb = (uint8_t *)0x006c;
    uint8_t length = 0;
    uint8_t i;
    const char *p;

    pack_default_fcb(first_fcb, argc > 1 ? argv[1] : 0);
    pack_default_fcb(second_fcb, argc > 2 ? argv[2] : 0);
    for (i = 1; i < argc; ++i) {
        if (length < 126)
            tail[1 + length++] = ' ';
        p = argv[i];
        while (*p && length < 126)
            tail[1 + length++] = (uint8_t)*p++;
    }
    tail[0] = length;
    tail[1 + length] = '\r';
}

void zsh_exec_com(uint8_t argc, char **argv)
{
    char name[13];
    zep_fs_stat_t info;
    zep_fs_handle_t handle;
    zep_fs_status_t status;

    status = zsh_exec_open_path(argv[0], name, &info, &handle);
    if (status != ZEP_FS_OK) {
        if (status == ZEP_FS_NOT_FOUND || status == ZEP_FS_BAD_NAME) {
            zsh_puts(argv[0]); zsh_puts(": command not found\n");
        } else
            zsh_error_status("exec", argv[0], status);
        return;
    }
    if (info.size > ZSH_COM_LIMIT) {
        (void)zep_fs_close(handle);
        zsh_puts(argv[0]); zsh_puts(": program is too large (");
        zsh_print_u32(info.size); zsh_puts(" bytes; maximum ");
        zsh_print_u32(ZSH_COM_LIMIT); zsh_puts(")\n");
        return;
    }

    prepare_page_zero(argc, argv);
    memset(loader_descriptor, 0, sizeof(loader_descriptor));
    loader_descriptor[0] = 1;
    loader_descriptor[1] = 3;
    loader_descriptor[4] = handle;
    loader_descriptor[10] = (uint8_t)ZSH_IO_SIZE;
    loader_descriptor[11] = (uint8_t)(ZSH_IO_SIZE >> 8);

    (void)bdos(ZSH_NATIVE_EXEC_BDOS, (int)loader_descriptor);
    (void)zep_fs_close(handle);
    zsh_puts("exec: protected loader unavailable\n");
}
#endif
