#include <string.h>
#include <limits.h>

#include "fs2.h"
#include "sdfs.h"
#include "bulk_channel.h"
#include "fs_share.h"
#include "ff.h"

#define FS2_PATH_MAX 239u

typedef struct {
    FIL fil;
    uint32_t generation;
    uint32_t position;
    uint8_t cookie;
    bool open;
} Fs2File;

typedef struct {
    DIR dir;
    uint32_t generation;
    uint8_t cookie;
    bool open;
} Fs2Dir;

static Fs2File files[IOC_FS2_FILE_SLOTS];
static Fs2Dir directory;
#define chunk fs_bulk_chunk
static char resolver[FS2_PATH_MAX + 1u];
static uint8_t resolver_components;
static uint32_t generation;

static void reply_init(const IocFrame *request, IocFrame *reply,
                       uint8_t cls, uint8_t status, uint8_t len)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS] = cls;
    reply->bytes[IOC_OFF_SEQ] = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = status;
    reply->bytes[IOC_OFF_LEN] = len;
}

static void put16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void close_contexts(void)
{
    uint8_t i;

    for (i = 0u; i < IOC_FS2_FILE_SLOTS; ++i) {
        if (files[i].open)
            (void)f_close(&files[i].fil);
        files[i].open = false;
        files[i].position = 0uL;
    }
    if (directory.open)
        (void)f_closedir(&directory.dir);
    directory.open = false;
}

static void next_generation(void)
{
    ++generation;
    if (generation == 0uL)
        generation = 1uL;
}

void fs2_init(void)
{
    uint8_t i;

    memset(files, 0, sizeof(files));
    memset(&directory, 0, sizeof(directory));
    for (i = 0u; i < IOC_FS2_FILE_SLOTS; ++i)
        files[i].cookie = (uint8_t)(i + 1u);
    directory.cookie = 1u;
    resolver[0] = '/';
    resolver[1] = '\0';
    resolver_components = 0u;
    generation = 1uL;
}

void fs2_media_invalidated(void)
{
    close_contexts();
    next_generation();
    resolver[0] = '/';
    resolver[1] = '\0';
    resolver_components = 0u;
}

static uint8_t map_result(FRESULT fr)
{
    switch (fr) {
    case FR_OK:            return IOC_STATUS_OK;
    case FR_NO_FILE:
    case FR_NO_PATH:       return IOC_STATUS_FS2_NOT_FOUND;
    case FR_EXIST:         return IOC_STATUS_FS2_EXISTS;
    case FR_INVALID_NAME:  return IOC_STATUS_FS2_BAD_NAME;
    case FR_DENIED:
    case FR_WRITE_PROTECTED:return IOC_STATUS_FS2_READ_ONLY;
    case FR_NOT_ENOUGH_CORE:
    case FR_TOO_MANY_OPEN_FILES: return IOC_STATUS_FS2_NO_HANDLE;
    case FR_INVALID_OBJECT:return IOC_STATUS_FS2_STALE;
    case FR_INVALID_PARAMETER:return IOC_STATUS_FS2_RANGE;
    case FR_NOT_READY:
    case FR_NOT_ENABLED:
    case FR_NO_FILESYSTEM: return IOC_STATUS_FS2_NO_MEDIA;
    default:               return IOC_STATUS_FS2_IO;
    }
}

static uint8_t need_fs(FATFS **fs)
{
    SdStatus st = sdfs_mount(fs);
    if (st != SD_OK)
        return IOC_STATUS_FS2_NO_MEDIA;
    if (*fs == NULL)
        return IOC_STATUS_FS2_NO_MEDIA;
    return IOC_STATUS_OK;
}

static bool legal_char(uint8_t c)
{
    if ((c < 0x21u) || (c > 0x7eu))
        return false;
    switch (c) {
    case '"': case '*': case '+': case ',': case '/': case ':':
    case ';': case '<': case '=': case '>': case '?': case '[':
    case '\\': case ']': case '|': case '.': case '~':
        return false;
    default:
        return true;
    }
}

static bool unpack_name(char *out, const uint8_t *name)
{
    uint8_t i;
    uint8_t n = 0u;
    bool saw_space = false;

    for (i = 0u; i < 8u; ++i) {
        uint8_t c = name[i] & 0x7fu;
        if (c == ' ') {
            saw_space = true;
            continue;
        }
        if (saw_space || !legal_char(c))
            return false;
        out[n++] = (char)c;
    }
    if (n == 0u)
        return false;

    saw_space = false;
    if (name[8] != ' ') {
        out[n++] = '.';
        for (i = 8u; i < IOC_NAME_LEN; ++i) {
            uint8_t c = name[i] & 0x7fu;
            if (c == ' ') {
                saw_space = true;
                continue;
            }
            if (saw_space || !legal_char(c))
                return false;
            out[n++] = (char)c;
        }
    } else if ((name[9] != ' ') || (name[10] != ' ')) {
        return false;
    }
    out[n] = '\0';
    return true;
}

static bool pack_name(uint8_t *out, const char *name)
{
    uint8_t b = 0u;
    uint8_t e = 8u;
    bool extension = false;
    uint8_t c;

    memset(out, ' ', IOC_NAME_LEN);
    while ((c = (uint8_t)*name++) != 0u) {
        if (c == '.') {
            if (extension || (b == 0u))
                return false;
            extension = true;
            continue;
        }
        if (!legal_char(c))
            return false;
        if ((c >= 'a') && (c <= 'z'))
            c = (uint8_t)(c - ('a' - 'A'));
        if (!extension) {
            if (b >= 8u)
                return false;
            out[b++] = c;
        } else {
            if (e >= IOC_NAME_LEN)
                return false;
            out[e++] = c;
        }
    }
    return (b != 0u) && (!extension || (e != 8u));
}

static bool make_path(char *out, const uint8_t *name, bool append)
{
    char component[13];
    size_t base;
    size_t add;

    if (!unpack_name(component, name))
        return false;
    base = strlen(resolver);
    add = strlen(component);
    if (base + add + ((base == 1u) ? 0u : 1u) > FS2_PATH_MAX)
        return false;
    memcpy(out, resolver, base);
    if (base != 1u)
        out[base++] = '/';
    memcpy(out + base, component, add + 1u);
    if (append) {
        memcpy(resolver, out, base + add + 1u);
        ++resolver_components;
    }
    return true;
}

static uint16_t token_for(uint8_t slot, uint8_t cookie)
{
    return (uint16_t)(slot + 1u) | ((uint16_t)cookie << 8);
}

static Fs2File *file_for(uint16_t token, uint8_t *status)
{
    uint8_t raw = (uint8_t)token;
    uint8_t slot;
    Fs2File *f;

    if ((raw == 0u) || (raw > IOC_FS2_FILE_SLOTS)) {
        *status = IOC_STATUS_FS2_NO_HANDLE;
        return NULL;
    }
    slot = (uint8_t)(raw - 1u);
    f = &files[slot];
    if (f->cookie != (uint8_t)(token >> 8)) {
        *status = IOC_STATUS_FS2_NO_HANDLE;
        return NULL;
    }
    if (f->generation != generation) {
        *status = IOC_STATUS_FS2_STALE;
        return NULL;
    }
    if (!f->open) {
        *status = IOC_STATUS_FS2_NO_HANDLE;
        return NULL;
    }
    *status = IOC_STATUS_OK;
    return f;
}

void handler_fs2_caps(const IocFrame *request, IocFrame *reply)
{
    uint16_t flags = IOC_FS2_CAP_READ_ONLY | IOC_FS2_CAP_EXPLICIT_OFFSET
                   | IOC_FS2_CAP_COMPONENT_RESOLVER
                   | IOC_FS2_CAP_MEDIA_GENERATION | IOC_FS2_CAP_STAT
                   | IOC_FS2_CAP_SPACE;
    reply_init(request, reply, RSP_FS2_CAPS, IOC_STATUS_OK,
               IOC_FS2_CAP_REPLY_LEN);
    reply->bytes[IOC_OFF_FS2_CAP_VERSION] = IOC_FS2_VERSION;
    reply->bytes[IOC_OFF_FS2_CAP_STATUS_VERSION] = IOC_FS2_STATUS_VERSION;
    put16(&reply->bytes[IOC_OFF_FS2_CAP_FLAGS], flags);
    put32(&reply->bytes[IOC_OFF_FS2_CAP_GENERATION], generation);
    put16(&reply->bytes[IOC_OFF_FS2_CAP_CHUNK_MAX], IOC_FS2_CHUNK_MAX);
    reply->bytes[IOC_OFF_FS2_CAP_FILE_SLOTS] = IOC_FS2_FILE_SLOTS;
    reply->bytes[IOC_OFF_FS2_CAP_DIR_SLOTS] = IOC_FS2_DIR_SLOTS;
    reply->bytes[IOC_OFF_FS2_CAP_RESOLVER_MAX] = IOC_FS2_RESOLVER_COMPONENTS;
    reply->bytes[IOC_OFF_FS2_CAP_TOKEN_BYTES] = IOC_FS2_TOKEN_BYTES;
}

void handler_fs2_generation(const IocFrame *request, IocFrame *reply)
{
    reply_init(request, reply, RSP_FS2_GENERATION, IOC_STATUS_OK,
               IOC_FS2_GENERATION_REPLY_LEN);
    put32(&reply->bytes[IOC_OFF_FS2_GENERATION], generation);
}

void handler_fs2_reset(const IocFrame *request, IocFrame *reply)
{
    fs2_media_invalidated();
    reply_init(request, reply, RSP_FS2_RESET, IOC_STATUS_OK,
               IOC_FS2_GENERATION_REPLY_LEN);
    put32(&reply->bytes[IOC_OFF_FS2_GENERATION], generation);
}

void handler_fs2_root(const IocFrame *request, IocFrame *reply)
{
    resolver[0] = '/';
    resolver[1] = '\0';
    resolver_components = 0u;
    reply_init(request, reply, RSP_FS2_ROOT, IOC_STATUS_OK, 0u);
}

void handler_fs2_push(const IocFrame *request, IocFrame *reply)
{
    char path[FS2_PATH_MAX + 1u];
    FILINFO info;
    FATFS *fs;
    uint8_t status = need_fs(&fs);
    FRESULT fr;
    (void)fs;

    if (status == IOC_STATUS_OK) {
        if (resolver_components >= IOC_FS2_RESOLVER_COMPONENTS)
            status = IOC_STATUS_FS2_RANGE;
        else if (!make_path(path, &request->bytes[IOC_OFF_FS2_NAME], false))
            status = IOC_STATUS_FS2_BAD_NAME;
        else {
            fr = f_stat(path, &info);
            status = map_result(fr);
            if ((status == IOC_STATUS_OK) && ((info.fattrib & AM_DIR) == 0u))
                status = IOC_STATUS_FS2_NOT_DIR;
            if (status == IOC_STATUS_OK)
                (void)make_path(path, &request->bytes[IOC_OFF_FS2_NAME], true);
        }
    }
    reply_init(request, reply, RSP_FS2_PUSH, status, 0u);
}

void handler_fs2_open_ro(const IocFrame *request, IocFrame *reply)
{
    char path[FS2_PATH_MAX + 1u];
    FATFS *fs;
    FILINFO info;
    uint8_t status = need_fs(&fs);
    uint8_t i;
    FRESULT fr;
    Fs2File *file = NULL;
    (void)fs;

    if ((status == IOC_STATUS_OK) &&
        !make_path(path, &request->bytes[IOC_OFF_FS2_NAME], false))
        status = IOC_STATUS_FS2_BAD_NAME;
    if (status == IOC_STATUS_OK) {
        fr = f_stat(path, &info);
        status = map_result(fr);
        if ((status == IOC_STATUS_OK) && ((info.fattrib & AM_DIR) != 0u))
            status = IOC_STATUS_FS2_IS_DIR;
    }
    if (status == IOC_STATUS_OK) {
        for (i = 0u; i < IOC_FS2_FILE_SLOTS; ++i) {
            if (!files[i].open) {
                file = &files[i];
                break;
            }
        }
        if (file == NULL)
            status = IOC_STATUS_FS2_NO_HANDLE;
    }
    if (status == IOC_STATUS_OK) {
        fr = f_open(&file->fil, path, FA_READ);
        status = map_result(fr);
    }
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_OPEN_RO, status, 0u);
        return;
    }
    ++file->cookie;
    if (file->cookie == 0u)
        file->cookie = 1u;
    file->open = true;
    file->generation = generation;
    file->position = 0uL;
    reply_init(request, reply, RSP_FS2_OPEN_RO, IOC_STATUS_OK,
               IOC_FS2_OPEN_REPLY_LEN);
    put16(&reply->bytes[IOC_OFF_FS2_OPEN_TOKEN],
          token_for(i, file->cookie));
    put32(&reply->bytes[IOC_OFF_FS2_OPEN_SIZE], (uint32_t)f_size(&file->fil));
    /* FS2 exposes a read-only namespace.  FAT attributes have no portable
     * meaning to its CP/M or native clients and previously corrupted CP/M
     * 8.3 names when translated into filename high bits. */
    reply->bytes[IOC_OFF_FS2_OPEN_ATTR] = 0u;
}

void handler_fs2_read(const IocFrame *request, IocFrame *reply)
{
    uint16_t token = get16(&request->bytes[IOC_OFF_FS2_TOKEN]);
    uint32_t offset = get32(&request->bytes[IOC_OFF_FS2_OFFSET]);
    uint16_t length = get16(&request->bytes[IOC_OFF_FS2_LENGTH]);
    uint8_t status;
    Fs2File *file = file_for(token, &status);
    FRESULT fr;
    UINT got = 0u;

    if ((status == IOC_STATUS_OK) &&
        ((length == 0u) || (length > IOC_FS2_CHUNK_MAX)))
        status = IOC_STATUS_FS2_RANGE;
    if ((status == IOC_STATUS_OK) && (file->position != offset)) {
        fr = f_lseek(&file->fil, (FSIZE_t)offset);
        status = map_result(fr);
        if (status == IOC_STATUS_OK)
            file->position = offset;
    }
    if (status == IOC_STATUS_OK) {
        fr = f_read(&file->fil, chunk, (UINT)length, &got);
        status = map_result(fr);
        if (status == IOC_STATUS_OK)
            file->position = offset + got;
        else
            file->position = 0xffffffffuL;
    }
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_READ, status, 0u);
        return;
    }
    reply_init(request, reply, RSP_FS2_READ, IOC_STATUS_OK,
               IOC_READY_PAYLOAD_LEN);
    if (got != 0u) {
        reply->bytes[IOC_OFF_READY_XFER_ID] = bulk_channel_next_xfer_id();
        reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_MCU_TO_Z80;
        put16(&reply->bytes[IOC_OFF_READY_LEN_LO], (uint16_t)got);
        put32(&reply->bytes[IOC_OFF_READY_LBA], offset);
        bulk_channel_arm(chunk, (uint16_t)got,
                         reply->bytes[IOC_OFF_READY_XFER_ID], RSP_FS2_READ,
                         request->bytes[IOC_OFF_SEQ], IOC_STATUS_OK);
    }
}

void handler_fs2_close(const IocFrame *request, IocFrame *reply)
{
    uint16_t token = get16(&request->bytes[IOC_OFF_FS2_TOKEN]);
    uint8_t status;
    Fs2File *file = file_for(token, &status);
    if (status == IOC_STATUS_OK) {
        status = map_result(f_close(&file->fil));
        file->open = false;
        file->position = 0uL;
    }
    reply_init(request, reply, RSP_FS2_CLOSE, status, 0u);
}

void handler_fs2_opendir(const IocFrame *request, IocFrame *reply)
{
    FATFS *fs;
    uint8_t status = need_fs(&fs);
    FRESULT fr;
    (void)fs;
    if ((status == IOC_STATUS_OK) && directory.open)
        status = IOC_STATUS_FS2_NO_HANDLE;
    if (status == IOC_STATUS_OK) {
        fr = f_opendir(&directory.dir, resolver);
        status = map_result(fr);
    }
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_OPENDIR, status, 0u);
        return;
    }
    ++directory.cookie;
    if (directory.cookie == 0u)
        directory.cookie = 1u;
    directory.open = true;
    directory.generation = generation;
    reply_init(request, reply, RSP_FS2_OPENDIR, IOC_STATUS_OK,
               IOC_FS2_DIR_REPLY_LEN);
    put16(&reply->bytes[IOC_OFF_FS2_DIR_TOKEN],
          token_for(0u, directory.cookie));
}

static uint8_t dir_status(uint16_t token)
{
    if (((uint8_t)token != 1u) ||
        ((uint8_t)(token >> 8) != directory.cookie))
        return IOC_STATUS_FS2_NO_HANDLE;
    if (directory.generation != generation)
        return IOC_STATUS_FS2_STALE;
    if (!directory.open)
        return IOC_STATUS_FS2_NO_HANDLE;
    return IOC_STATUS_OK;
}

void handler_fs2_readdir(const IocFrame *request, IocFrame *reply)
{
    uint16_t token = get16(&request->bytes[IOC_OFF_FS2_TOKEN]);
    uint8_t status = dir_status(token);
    FILINFO info;
    FRESULT fr;
    uint8_t packed[IOC_NAME_LEN];

    while (status == IOC_STATUS_OK) {
        fr = f_readdir(&directory.dir, &info);
        status = map_result(fr);
        if (status != IOC_STATUS_OK)
            break;
        if (info.fname[0] == '\0') {
            status = IOC_STATUS_FS2_END;
            break;
        }
        if (pack_name(packed, info.fname))
            break;
    }
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_READDIR, status, 0u);
        return;
    }
    reply_init(request, reply, RSP_FS2_READDIR, IOC_STATUS_OK,
               IOC_FS2_DIRENT_REPLY_LEN);
    memcpy(&reply->bytes[IOC_OFF_FS2_DIRENT_NAME], packed, IOC_NAME_LEN);
    /* Preserve only the structural directory marker.  Clients need it to
     * distinguish traversable components from files; ordinary FAT attributes
     * remain deliberately hidden. */
    reply->bytes[IOC_OFF_FS2_DIRENT_ATTR] = info.fattrib & AM_DIR;
    put32(&reply->bytes[IOC_OFF_FS2_DIRENT_SIZE], (uint32_t)info.fsize);
}

void handler_fs2_closedir(const IocFrame *request, IocFrame *reply)
{
    uint16_t token = get16(&request->bytes[IOC_OFF_FS2_TOKEN]);
    uint8_t status = dir_status(token);
    if (status == IOC_STATUS_OK) {
        status = map_result(f_closedir(&directory.dir));
        directory.open = false;
    }
    reply_init(request, reply, RSP_FS2_CLOSEDIR, status, 0u);
}

void handler_fs2_stat(const IocFrame *request, IocFrame *reply)
{
    char path[FS2_PATH_MAX + 1u];
    FATFS *fs;
    FILINFO info;
    uint8_t status = need_fs(&fs);
    (void)fs;
    if ((status == IOC_STATUS_OK) &&
        !make_path(path, &request->bytes[IOC_OFF_FS2_NAME], false))
        status = IOC_STATUS_FS2_BAD_NAME;
    if (status == IOC_STATUS_OK)
        status = map_result(f_stat(path, &info));
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_STAT, status, 0u);
        return;
    }
    reply_init(request, reply, RSP_FS2_STAT, IOC_STATUS_OK,
               IOC_FS2_STAT_REPLY_LEN);
    put32(&reply->bytes[IOC_OFF_FS2_STAT_SIZE], (uint32_t)info.fsize);
    reply->bytes[IOC_OFF_FS2_STAT_ATTR] = info.fattrib & AM_DIR;
}

static uint32_t byte_count(DWORD clusters, DWORD cluster_bytes)
{
    if ((cluster_bytes != 0uL) &&
        (clusters > (DWORD)(0xffffffffuL / cluster_bytes)))
        return 0xffffffffuL;
    return (uint32_t)(clusters * cluster_bytes);
}

void handler_fs2_space(const IocFrame *request, IocFrame *reply)
{
    FATFS *fs;
    DWORD free_clusters = 0uL;
    DWORD cluster_bytes;
    uint8_t status = need_fs(&fs);
    FRESULT fr;
    if (status == IOC_STATUS_OK) {
        fr = f_getfree("/", &free_clusters, &fs);
        status = map_result(fr);
    }
    if (status != IOC_STATUS_OK) {
        reply_init(request, reply, RSP_FS2_SPACE, status, 0u);
        return;
    }
    cluster_bytes = (DWORD)fs->csize * 512uL;
    reply_init(request, reply, RSP_FS2_SPACE, IOC_STATUS_OK,
               IOC_FS2_SPACE_REPLY_LEN);
    put32(&reply->bytes[IOC_OFF_FS2_SPACE_FREE],
          byte_count(free_clusters, cluster_bytes));
    put32(&reply->bytes[IOC_OFF_FS2_SPACE_TOTAL],
          byte_count(fs->n_fatent - 2uL, cluster_bytes));
}
