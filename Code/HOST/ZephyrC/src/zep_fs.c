/* zep_fs.c -- C wrapper for the native Zephyr filesystem (BDOS 218). */
#include <string.h>
#include <zephyr/fs.h>
#include "zep_internal.h"

#define FS_DESC_BYTES       32
#define FS_VERSION           1
#define FS_CHUNK           512
#define FS_MAX_DEPTH        16

#define D_VERSION            0
#define D_OP                 1
#define D_STATUS             2
#define D_FLAGS              3
#define D_HANDLE             4
#define D_POSITION           6
#define D_LENGTH            10
#define D_BUFFER            12
#define D_RESULT            16
#define D_NAME              18
#define D_NAME2              6
#define D_SPACE_TOTAL       18

#define OP_OPEN              1
#define OP_CLOSE             2
#define OP_READ              3
#define OP_SEEK              4
#define OP_TELL              5
#define OP_STAT              6
#define OP_OPENDIR           7
#define OP_READDIR           8
#define OP_CHDIR             9
#define OP_WRITE            10
#define OP_SYNC             11
#define OP_TRUNCATE         12
#define OP_DELETE           13
#define OP_RENAME           14
#define OP_MKDIR            15
#define OP_RMDIR            16
#define OP_CWD              17
#define OP_SPACE            18
#define OP_CDUP             19
#define OP_CLOSEDIR         20
#define OP_SPACE_KIB        21

static void put16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static void put32(uint8_t *p, uint32_t value)
{
    put16(p, (uint16_t)value);
    put16(p + 2, (uint16_t)(value >> 16));
}

static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)get16(p) | ((uint32_t)get16(p + 2) << 16);
}

static void begin(uint8_t d[FS_DESC_BYTES], uint8_t op)
{
    memset(d, 0, FS_DESC_BYTES);
    d[D_VERSION] = FS_VERSION;
    d[D_OP] = op;
    /* An older BDOS leaves the descriptor untouched. */
    d[D_STATUS] = ZEP_FS_UNSUPPORTED;
}

static zep_fs_status_t call(uint8_t d[FS_DESC_BYTES])
{
    return zep__fs_native(d);
}

static uint8_t legal_char(uint8_t c)
{
    if (c < 0x21 || c > 0x7e)
        return 0;
    switch (c) {
    case '"': case '*': case '+': case ',': case '/': case ':':
    case ';': case '<': case '=': case '>': case '?': case '[':
    case '\\': case ']': case '|': case '.': case '~':
        return 0;
    default:
        return 1;
    }
}

uint8_t zep__fs_pack_name(uint8_t packed[11], const char *name)
{
    uint8_t base = 0;
    uint8_t ext = 8;
    uint8_t in_ext = 0;
    uint8_t c;

    if (!packed || !name)
        return ZEP_FS_BAD_NAME;
    memset(packed, ' ', 11);
    while ((c = (uint8_t)*name++) != 0) {
        if (c == '.') {
            if (in_ext || base == 0)
                return ZEP_FS_BAD_NAME;
            in_ext = 1;
            continue;
        }
        if (!legal_char(c))
            return ZEP_FS_BAD_NAME;
        if (c >= 'a' && c <= 'z')
            c = (uint8_t)(c - ('a' - 'A'));
        if (!in_ext) {
            if (base >= 8)
                return ZEP_FS_BAD_NAME;
            packed[base++] = c;
        } else {
            if (ext >= 11)
                return ZEP_FS_BAD_NAME;
            packed[ext++] = c;
        }
    }
    if (base == 0 || (in_ext && ext == 8))
        return ZEP_FS_BAD_NAME;
    return ZEP_FS_OK;
}

static void unpack_name(char dst[13], const uint8_t packed[11])
{
    uint8_t i;
    uint8_t n = 0;

    for (i = 0; i < 8 && packed[i] != ' '; ++i)
        dst[n++] = (char)(packed[i] & 0x7f);
    if (packed[8] != ' ') {
        dst[n++] = '.';
        for (i = 8; i < 11 && packed[i] != ' '; ++i)
            dst[n++] = (char)(packed[i] & 0x7f);
    }
    dst[n] = 0;
}

static zep_fs_status_t name_call(uint8_t op, const char *name)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;

    begin(d, op);
    status = zep__fs_pack_name(d + D_NAME, name);
    if (status != ZEP_FS_OK)
        return status;
    return call(d);
}

zep_fs_status_t zep_fs_open(const char *name, zep_fs_open_mode_t mode,
                            zep_fs_handle_t *out)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;

    if (!out || (uint8_t)mode > (uint8_t)ZEP_FS_OPEN_CREATE_ALWAYS)
        return ZEP_FS_RANGE;
    begin(d, OP_OPEN);
    status = zep__fs_pack_name(d + D_NAME, name);
    if (status != ZEP_FS_OK)
        return status;
    d[D_FLAGS] = (uint8_t)mode;
    status = call(d);
    if (status == ZEP_FS_OK)
        *out = d[D_HANDLE];
    return status;
}

zep_fs_status_t zep_fs_close(zep_fs_handle_t handle)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_CLOSE);
    d[D_HANDLE] = handle;
    return call(d);
}

zep_fs_status_t zep_fs_read(zep_fs_handle_t handle, void *dst,
                            uint16_t length, uint16_t *actual)
{
    uint8_t d[FS_DESC_BYTES];
    uint8_t *p = (uint8_t *)dst;
    uint16_t remaining = length;
    uint16_t total = 0;
    uint16_t chunk;
    uint16_t moved;
    zep_fs_status_t status;

    if (actual)
        *actual = 0;
    if (length == 0)
        return ZEP_FS_OK;
    if (!dst)
        return ZEP_FS_RANGE;
    while (remaining != 0) {
        chunk = remaining > FS_CHUNK ? FS_CHUNK : remaining;
        begin(d, OP_READ);
        d[D_HANDLE] = handle;
        put16(d + D_LENGTH, chunk);
        put16(d + D_BUFFER, (uint16_t)p);
        status = call(d);
        if (status != ZEP_FS_OK)
            return status;
        moved = get16(d + D_RESULT);
        if (moved > chunk)
            return ZEP_FS_IO;
        total = (uint16_t)(total + moved);
        if (actual)
            *actual = total;
        if (moved != chunk)
            return ZEP_FS_OK;
        p += moved;
        remaining = (uint16_t)(remaining - moved);
    }
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_write(zep_fs_handle_t handle, const void *src,
                             uint16_t length, uint16_t *actual)
{
    uint8_t d[FS_DESC_BYTES];
    const uint8_t *p = (const uint8_t *)src;
    uint16_t remaining = length;
    uint16_t total = 0;
    uint16_t chunk;
    uint16_t moved;
    zep_fs_status_t status;

    if (actual)
        *actual = 0;
    if (length == 0)
        return ZEP_FS_OK;
    if (!src)
        return ZEP_FS_RANGE;
    while (remaining != 0) {
        chunk = remaining > FS_CHUNK ? FS_CHUNK : remaining;
        begin(d, OP_WRITE);
        d[D_HANDLE] = handle;
        put16(d + D_LENGTH, chunk);
        put16(d + D_BUFFER, (uint16_t)p);
        status = call(d);
        if (status != ZEP_FS_OK)
            return status;       /* UNKNOWN_WRITE is never replayed */
        moved = get16(d + D_RESULT);
        if (moved > chunk)
            return ZEP_FS_IO;
        total = (uint16_t)(total + moved);
        if (actual)
            *actual = total;
        if (moved != chunk)
            return ZEP_FS_OK;
        p += moved;
        remaining = (uint16_t)(remaining - moved);
    }
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_seek(zep_fs_handle_t handle, uint32_t offset)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_SEEK);
    d[D_HANDLE] = handle;
    put32(d + D_POSITION, offset);
    return call(d);
}

zep_fs_status_t zep_fs_tell(zep_fs_handle_t handle, uint32_t *offset)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!offset)
        return ZEP_FS_RANGE;
    begin(d, OP_TELL);
    d[D_HANDLE] = handle;
    status = call(d);
    if (status == ZEP_FS_OK)
        *offset = get32(d + D_POSITION);
    return status;
}

zep_fs_status_t zep_fs_sync(zep_fs_handle_t handle)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_SYNC);
    d[D_HANDLE] = handle;
    return call(d);
}

zep_fs_status_t zep_fs_truncate(zep_fs_handle_t handle, uint32_t size)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_TRUNCATE);
    d[D_HANDLE] = handle;
    put32(d + D_POSITION, size);
    return call(d);
}

zep_fs_status_t zep_fs_stat(const char *name, zep_fs_stat_t *out)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!out)
        return ZEP_FS_RANGE;
    begin(d, OP_STAT);
    status = zep__fs_pack_name(d + D_NAME, name);
    if (status != ZEP_FS_OK)
        return status;
    status = call(d);
    if (status == ZEP_FS_OK) {
        out->size = get32(d + D_POSITION);
        out->flags = d[D_FLAGS];
    }
    return status;
}

zep_fs_status_t zep_fs_delete(const char *name)
{
    return name_call(OP_DELETE, name);
}

zep_fs_status_t zep_fs_rename(const char *old_name, const char *new_name)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    begin(d, OP_RENAME);
    status = zep__fs_pack_name(d + D_NAME, old_name);
    if (status != ZEP_FS_OK)
        return status;
    status = zep__fs_pack_name(d + D_NAME2, new_name);
    if (status != ZEP_FS_OK)
        return status;
    return call(d);
}

zep_fs_status_t zep_fs_mkdir(const char *name)
{
    return name_call(OP_MKDIR, name);
}

zep_fs_status_t zep_fs_rmdir(const char *name)
{
    return name_call(OP_RMDIR, name);
}

zep_fs_status_t zep_fs_root(void)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_CHDIR);
    return call(d);             /* empty packed component selects USER root */
}

zep_fs_status_t zep_fs_cdup(void)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_CDUP);
    return call(d);
}

zep_fs_status_t zep_fs_chdir(const char *path)
{
    uint8_t d[FS_DESC_BYTES];
    char component[13];
    uint8_t n;
    uint8_t did_any = 0;
    zep_fs_status_t status;

    if (!path || !*path)
        return ZEP_FS_BAD_NAME;
    if (*path == '/') {
        status = zep_fs_root();
        if (status != ZEP_FS_OK)
            return status;
        did_any = 1;
        while (*path == '/')
            ++path;
    }
    while (*path) {
        n = 0;
        while (*path && *path != '/') {
            if (n >= 12)
                return ZEP_FS_BAD_NAME;
            component[n++] = *path++;
        }
        component[n] = 0;
        while (*path == '/')
            ++path;
        if (n == 0)
            continue;
        did_any = 1;
        if (component[0] == '.' && component[1] == 0)
            continue;
        if (component[0] == '.' && component[1] == '.' &&
            component[2] == 0) {
            status = zep_fs_cdup();
        } else {
            begin(d, OP_CHDIR);
            status = zep__fs_pack_name(d + D_NAME, component);
            if (status == ZEP_FS_OK)
                status = call(d);
        }
        if (status != ZEP_FS_OK)
            return status;
    }
    return did_any ? ZEP_FS_OK : ZEP_FS_BAD_NAME;
}

zep_fs_status_t zep_fs_getcwd(char *dst, uint16_t capacity)
{
    uint8_t d[FS_DESC_BYTES];
    uint8_t components[FS_MAX_DEPTH * 11];
    uint8_t depth;
    uint8_t i;
    uint16_t reported;
    uint16_t needed = 2;
    uint16_t at = 0;
    char printable[13];
    uint8_t len;
    zep_fs_status_t status;

    if (!dst || capacity == 0)
        return ZEP_FS_RANGE;
    begin(d, OP_CWD);
    d[D_FLAGS] = 0;
    status = call(d);
    if (status != ZEP_FS_OK)
        return status;
    reported = get16(d + D_RESULT);
    if (reported > FS_MAX_DEPTH)
        return ZEP_FS_IO;
    depth = (uint8_t)reported;
    if (depth != 0)
        memcpy(components, d + D_NAME, 11);
    for (i = 1; i < depth; ++i) {
        begin(d, OP_CWD);
        d[D_FLAGS] = i;
        status = call(d);
        if (status != ZEP_FS_OK)
            return status;
        if (get16(d + D_RESULT) != depth)
            return ZEP_FS_IO;
        memcpy(components + (uint16_t)i * 11, d + D_NAME, 11);
    }
    for (i = 0; i < depth; ++i) {
        unpack_name(printable, components + (uint16_t)i * 11);
        len = (uint8_t)strlen(printable);
        needed = (uint16_t)(needed + len + (i != 0));
    }
    if (capacity < needed) {
        dst[0] = 0;
        return ZEP_FS_RANGE;
    }
    dst[at++] = '/';
    for (i = 0; i < depth; ++i) {
        if (i != 0)
            dst[at++] = '/';
        unpack_name(printable, components + (uint16_t)i * 11);
        len = (uint8_t)strlen(printable);
        memcpy(dst + at, printable, len);
        at = (uint16_t)(at + len);
    }
    dst[at] = 0;
    return ZEP_FS_OK;
}

zep_fs_status_t zep_fs_opendir(zep_fs_dir_t *out)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!out)
        return ZEP_FS_RANGE;
    begin(d, OP_OPENDIR);
    status = call(d);
    if (status == ZEP_FS_OK)
        *out = d[D_HANDLE];
    return status;
}

zep_fs_status_t zep_fs_readdir(zep_fs_dir_t dir, zep_fs_dirent_t *out)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!out)
        return ZEP_FS_RANGE;
    begin(d, OP_READDIR);
    d[D_HANDLE] = dir;
    status = call(d);
    if (status == ZEP_FS_OK) {
        unpack_name(out->name, d + D_NAME);
        out->size = get32(d + D_POSITION);
        out->flags = d[D_FLAGS];
    }
    return status;
}

zep_fs_status_t zep_fs_closedir(zep_fs_dir_t dir)
{
    uint8_t d[FS_DESC_BYTES];
    begin(d, OP_CLOSEDIR);
    d[D_HANDLE] = dir;
    return call(d);
}

zep_fs_status_t zep_fs_space(uint32_t *free_bytes, uint32_t *total_bytes)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!free_bytes || !total_bytes)
        return ZEP_FS_RANGE;
    begin(d, OP_SPACE);
    status = call(d);
    if (status == ZEP_FS_OK) {
        *free_bytes = get32(d + D_POSITION);
        *total_bytes = get32(d + D_SPACE_TOTAL);
    }
    return status;
}

zep_fs_status_t zep_fs_space_kib(uint32_t *free_kib, uint32_t *total_kib)
{
    uint8_t d[FS_DESC_BYTES];
    zep_fs_status_t status;
    if (!free_kib || !total_kib)
        return ZEP_FS_RANGE;
    begin(d, OP_SPACE_KIB);
    status = call(d);
    if (status == ZEP_FS_OK) {
        *free_kib = get32(d + D_POSITION);
        *total_kib = get32(d + D_SPACE_TOTAL);
    }
    return status;
}
