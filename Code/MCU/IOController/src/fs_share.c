#include <string.h>

#include "fs_share.h"
#include "sdfs.h"
#include "sd_card.h"
#include "sd_cache.h"
#include "bulk_channel.h"
#include "ff.h"

/* The shared directory.  Fixed here and nowhere else; see rule 1 in
 * fs_share.h.  Kept out of /CPM/, which is what makes it structurally
 * impossible for a user program to reach a mounted image. */
#define FS_SHARE_DIR      "/SHARED"
#define FS_SHARE_PREFIX   "/SHARED/"
#define FS_SHARE_PREFIX_LEN 8u

/* One chunk in flight.  Static because the bulk lane streams straight out of
 * (or into) it and the PIC's data stack is 512 bytes in total. */
static uint8_t chunk[IOC_FS_CHUNK_MAX];

/* One directory session and one file handle; see HOUSEKEEPING in fs_share.h. */
static DIR      dir;
static bool     dir_open;
static FIL      fil;
static uint8_t  fil_handle;          /* 0 = nothing open */
static uint8_t  next_handle = 1u;
static bool     fil_writing;

/* Cached file position, so sequential access pays nothing for the explicit
 * offset the protocol carries.  Only meaningful while fil_handle != 0. */
static uint32_t fil_pos;

/* Staged by handler_fs_write() for the bulk commit callback. */
static uint32_t pending_write_offset;
static uint16_t pending_write_len;

void fs_share_init(void)
{
    dir_open     = false;
    fil_handle   = 0u;
    next_handle  = 1u;
    fil_writing  = false;
    fil_pos      = 0uL;
}

/* --------------------------------------------------------------------------
 * Small shared helpers
 * -------------------------------------------------------------------------- */

static void fs_reply(const IocFrame *request, IocFrame *reply,
                     uint8_t cls, uint8_t status, uint8_t len)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = cls;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = status;
    reply->bytes[IOC_OFF_LEN]    = len;
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
    return  (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

/* FatFs errors mapped to wire status.  "Not there" and "the card is broken"
 * stay distinguishable; everything genuinely unexpected collapses into
 * IOC_STATUS_FS_ERROR rather than pretending to more precision than we have. */
static uint8_t fres_to_ioc(FRESULT fr)
{
    switch (fr) {
    case FR_OK:            return IOC_STATUS_OK;
    case FR_NO_FILE:
    case FR_NO_PATH:       return IOC_STATUS_FS_NO_FILE;
    case FR_INVALID_NAME:  return IOC_STATUS_FS_BAD_NAME;
    case FR_NOT_ENABLED:
    case FR_NO_FILESYSTEM: return IOC_STATUS_FS_NOT_MOUNTED;
    case FR_DISK_ERR:
    case FR_NOT_READY:     return IOC_STATUS_SD_READ_FAIL;
    default:               return IOC_STATUS_FS_ERROR;
    }
}

/* Build FS_SHARE_PREFIX + "NAME.EXT" from a packed 8.3 name.
 *
 * Returns false for anything that is not purely a name: a separator, a dot, a
 * control byte, or an empty basename.  A packed name cannot legitimately hold
 * any of those, so rejecting them costs nothing and closes the only route a
 * caller has to a directory it was not given. */
static bool share_path(char *out, const uint8_t *name11)
{
    uint8_t i;
    uint8_t n;

    memcpy(out, FS_SHARE_PREFIX, FS_SHARE_PREFIX_LEN);
    n = FS_SHARE_PREFIX_LEN;

    for (i = 0u; i < IOC_NAME_LEN; i++) {
        uint8_t c = name11[i];

        if (c == ' ')
            continue;
        if ((c < 0x21u) || (c > 0x7Eu))
            return false;
        if ((c == '/') || (c == '\\') || (c == ':') || (c == '.'))
            return false;
    }

    /* Basename: up to eight non-space characters, and at least one. */
    for (i = 0u; i < 8u; i++) {
        if (name11[i] == ' ')
            break;
        out[n++] = (char)name11[i];
    }

    if (n == FS_SHARE_PREFIX_LEN)
        return false;

    if (name11[8] != ' ') {
        out[n++] = '.';
        for (i = 8u; i < IOC_NAME_LEN; i++) {
            if (name11[i] == ' ')
                break;
            out[n++] = (char)name11[i];
        }
    }

    out[n] = '\0';
    return true;
}

/* The reverse: FatFs's "NAME.EXT" into eleven space-padded bytes.
 *
 * Done here in a few lines of C rather than a few dozen of Z80 -- the transient
 * drops the result straight into an FCB. */
static void pack_name(uint8_t *out11, const char *fname)
{
    uint8_t i = 0u;
    uint8_t n = 0u;

    memset(out11, ' ', IOC_NAME_LEN);

    while ((fname[i] != '\0') && (fname[i] != '.') && (n < 8u))
        out11[n++] = (uint8_t)fname[i++];

    while ((fname[i] != '\0') && (fname[i] != '.'))
        i++;

    if (fname[i] == '.') {
        i++;
        n = 8u;
        while ((fname[i] != '\0') && (n < IOC_NAME_LEN))
            out11[n++] = (uint8_t)fname[i++];
    }
}

/* Ensure the card's filesystem is mounted.  Returns an IOC status. */
static uint8_t need_fs(void)
{
    FATFS   *fs;
    SdStatus st = sdfs_mount(&fs);

    if (st != SD_OK)
        return IOC_STATUS_SD_READ_FAIL;
    if (fs == NULL)
        return IOC_STATUS_FS_NOT_MOUNTED;

    return IOC_STATUS_OK;
}

/* Close whatever is open, discarding nothing: f_close syncs first. */
static void close_current(void)
{
    if (fil_handle != 0u) {
        (void)f_close(&fil);
        fil_handle  = 0u;
        fil_writing = false;
        fil_pos     = 0uL;
    }
}

/* --------------------------------------------------------------------------
 * Directory
 * -------------------------------------------------------------------------- */

void handler_fs_opendir(const IocFrame *request, IocFrame *reply)
{
    uint8_t status = need_fs();
    FRESULT fr;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_OPENDIR, status, 0u);
        return;
    }

    if (dir_open) {
        (void)f_closedir(&dir);
        dir_open = false;
    }

    fr = f_opendir(&dir, FS_SHARE_DIR);
    if (fr != FR_OK) {
        fs_reply(request, reply, RSP_FS_OPENDIR, fres_to_ioc(fr), 0u);
        return;
    }

    dir_open = true;
    fs_reply(request, reply, RSP_FS_OPENDIR, IOC_STATUS_OK, 0u);
}

/* One entry per call.
 *
 * MORE is the end-of-directory flag and the only one worth reading: 1 means
 * this reply carries an entry, 0 means the listing is finished and the name
 * field is blank.  Subdirectories are skipped -- /SHARED/ is flat by design,
 * and a CP/M transient has nothing to do with a directory entry. */
void handler_fs_readdir(const IocFrame *request, IocFrame *reply)
{
    FILINFO fno;
    FRESULT fr;

    if (!dir_open) {
        fs_reply(request, reply, RSP_FS_READDIR, IOC_STATUS_FS_NO_HANDLE, 0u);
        return;
    }

    for (;;) {
        fr = f_readdir(&dir, &fno);
        if (fr != FR_OK) {
            fs_reply(request, reply, RSP_FS_READDIR, fres_to_ioc(fr), 0u);
            return;
        }

        if (fno.fname[0] == '\0') {
            /* End of directory.  Close the session here rather than leaving it
             * to the caller: a transient that stops listing early is the
             * normal case, and the next OPENDIR replaces it anyway. */
            (void)f_closedir(&dir);
            dir_open = false;
            fs_reply(request, reply, RSP_FS_READDIR, IOC_STATUS_OK,
                     IOC_FS_READDIR_LEN);
            return;
        }

        if ((fno.fattrib & AM_DIR) == 0u)
            break;
    }

    fs_reply(request, reply, RSP_FS_READDIR, IOC_STATUS_OK,
             IOC_FS_READDIR_LEN);

    pack_name(&reply->bytes[IOC_OFF_FS_DIR_NAME], fno.fname);
    reply->bytes[IOC_OFF_FS_DIR_ATTR] = fno.fattrib;
    put32(&reply->bytes[IOC_OFF_FS_DIR_SIZE], (uint32_t)fno.fsize);
    reply->bytes[IOC_OFF_FS_DIR_MORE] = 1u;
}

/* --------------------------------------------------------------------------
 * Files
 * -------------------------------------------------------------------------- */

void handler_fs_open(const IocFrame *request, IocFrame *reply)
{
    char    path[FS_SHARE_PREFIX_LEN + 12u + 1u];
    uint8_t mode = request->bytes[IOC_OFF_FS_OPEN_MODE];
    uint8_t status = need_fs();
    FRESULT fr;
    BYTE    flags;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_OPEN, status, 0u);
        return;
    }

    /* Implicit close, so a transient that died mid-copy cannot leak the one
     * handle there is. */
    close_current();

    if (!share_path(path, &request->bytes[IOC_OFF_FS_OPEN_NAME])) {
        fs_reply(request, reply, RSP_FS_OPEN, IOC_STATUS_FS_BAD_NAME, 0u);
        return;
    }

#if FF_FS_READONLY
    if (mode == IOC_FS_MODE_WRITE) {
        fs_reply(request, reply, RSP_FS_OPEN, IOC_STATUS_FS_ERROR, 0u);
        return;
    }
    flags = FA_READ;
#else
    flags = (mode == IOC_FS_MODE_WRITE)
          ? (FA_WRITE | FA_CREATE_ALWAYS)
          : FA_READ;
#endif

    fr = f_open(&fil, path, flags);
    if (fr != FR_OK) {
        fs_reply(request, reply, RSP_FS_OPEN, fres_to_ioc(fr), 0u);
        return;
    }

    /* Handle zero means "nothing open", so it is never issued. */
    fil_handle = next_handle++;
    if (next_handle == 0u)
        next_handle = 1u;

    fil_writing = (mode == IOC_FS_MODE_WRITE);
    fil_pos     = 0uL;

    fs_reply(request, reply, RSP_FS_OPEN, IOC_STATUS_OK,
             IOC_FS_OPEN_REPLY_LEN);
    reply->bytes[IOC_OFF_FS_OPEN_HANDLE] = fil_handle;
    put32(&reply->bytes[IOC_OFF_FS_OPEN_SIZE], (uint32_t)f_size(&fil));
}

/* Seek only when the position is not already right.  The offset is on the wire
 * to make a retry idempotent, not because sequential access should pay for
 * it. */
static FRESULT seek_to(uint32_t offset)
{
    FRESULT fr;

    if (fil_pos == offset)
        return FR_OK;

    fr = f_lseek(&fil, (FSIZE_t)offset);
    if (fr == FR_OK)
        fil_pos = offset;

    return fr;
}

/* Shared front half of READ and WRITE: validate the handle and the chunk
 * length, and pull the offset out.  Returns an IOC status. */
static uint8_t xfer_params(const IocFrame *request, uint32_t *offset,
                           uint16_t *len)
{
    if ((fil_handle == 0u) ||
        (request->bytes[IOC_OFF_FS_XFER_HANDLE] != fil_handle))
        return IOC_STATUS_FS_NO_HANDLE;

    *offset = get32(&request->bytes[IOC_OFF_FS_XFER_OFFSET]);
    *len    = (uint16_t)request->bytes[IOC_OFF_FS_XFER_LEN]
            | ((uint16_t)request->bytes[IOC_OFF_FS_XFER_LEN + 1u] << 8);

    if ((*len == 0u) || (*len > IOC_FS_CHUNK_MAX))
        return IOC_STATUS_FS_RANGE;

    return IOC_STATUS_OK;
}

/* The file is read into SRAM BEFORE the READY reply, exactly as the record and
 * block paths do it: a READY is then a genuine promise that the bulk phase
 * cannot fail for want of the card. */
void handler_fs_read(const IocFrame *request, IocFrame *reply)
{
    uint32_t offset;
    uint16_t len;
    UINT     got = 0u;
    uint8_t  status = xfer_params(request, &offset, &len);
    FRESULT  fr;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_READ, status, 0u);
        return;
    }

    fr = seek_to(offset);
    if (fr == FR_OK)
        fr = f_read(&fil, chunk, (UINT)len, &got);

    if (fr != FR_OK) {
        /* The cached position is now unknown -- f_read advances by whatever it
         * managed before failing.  Forcing the next seek is cheaper than
         * reasoning about a partial one. */
        fil_pos = 0xFFFFFFFFuL;
        fs_reply(request, reply, RSP_FS_READ, fres_to_ioc(fr), 0u);
        return;
    }

    fil_pos = offset + got;

    /* A short read at end of file is not an error; the READY length says how
     * many bytes the bulk phase will actually carry.  Zero means the caller
     * must not enter its read loop at all. */
    fs_reply(request, reply, RSP_FS_READ, IOC_STATUS_OK,
             IOC_READY_PAYLOAD_LEN);

    if (got == 0u)
        return;

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_MCU_TO_Z80;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)got;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = (uint8_t)(got >> 8);
    put32(&reply->bytes[IOC_OFF_READY_LBA], offset);

    bulk_channel_arm(chunk, (uint16_t)got,
                     reply->bytes[IOC_OFF_READY_XFER_ID],
                     RSP_FS_READ, request->bytes[IOC_OFF_SEQ],
                     IOC_STATUS_OK);
}

#if !FF_FS_READONLY
/* Runs once the chunk has arrived and been de-shifted.  Bytes arriving says
 * nothing about whether they were stored, which is why DONE is mandatory on
 * this direction and only meaningful after this has run. */
static uint8_t commit_fs_write(void)
{
    UINT    put = 0u;
    FRESULT fr;

    if (fil_handle == 0u)
        return IOC_STATUS_FS_NO_HANDLE;

    fr = seek_to(pending_write_offset);
    if (fr == FR_OK)
        fr = f_write(&fil, chunk, (UINT)pending_write_len, &put);

    if (fr != FR_OK) {
        fil_pos = 0xFFFFFFFFuL;
        return fres_to_ioc(fr);
    }

    fil_pos = pending_write_offset + put;

    /* A short write means the card or the volume is full.  Reporting OK here
     * would lose the tail of a file silently, which is the whole failure class
     * the DONE round trip exists to catch. */
    if (put != pending_write_len)
        return IOC_STATUS_FS_ERROR;

    return IOC_STATUS_OK;
}

void handler_fs_write(const IocFrame *request, IocFrame *reply)
{
    uint32_t offset;
    uint16_t len;
    uint8_t  status = xfer_params(request, &offset, &len);

    if ((status == IOC_STATUS_OK) && !fil_writing)
        status = IOC_STATUS_FS_NO_HANDLE;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_WRITE, status, 0u);
        return;
    }

    pending_write_offset = offset;
    pending_write_len    = len;

    fs_reply(request, reply, RSP_FS_WRITE, IOC_STATUS_OK,
             IOC_READY_PAYLOAD_LEN);

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_Z80_TO_MCU;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)len;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = (uint8_t)(len >> 8);
    put32(&reply->bytes[IOC_OFF_READY_LBA], offset);

    bulk_channel_arm_receive(chunk, len,
                             reply->bytes[IOC_OFF_READY_XFER_ID],
                             CMD_FS_WRITE, request->bytes[IOC_OFF_SEQ],
                             commit_fs_write);
}

#endif /* !FF_FS_READONLY */

/* The exact length arrives here, not on the writes.
 *
 * CP/M files are 128-byte granular and carry no true length, so a naive copy
 * out lands padded with whatever the last record held.  Truncating to the size
 * the caller means is what makes a text file written from CP/M arrive on the
 * host at the right byte. */
void handler_fs_close(const IocFrame *request, IocFrame *reply)
{
    uint32_t final_size;
    FRESULT  fr = FR_OK;
    uint8_t  status;

    if ((fil_handle == 0u) ||
        (request->bytes[IOC_OFF_FS_CLOSE_HANDLE] != fil_handle)) {
        fs_reply(request, reply, RSP_FS_CLOSE, IOC_STATUS_FS_NO_HANDLE, 0u);
        return;
    }

    final_size = get32(&request->bytes[IOC_OFF_FS_CLOSE_SIZE]);

    /* Only ever shorten.  f_lseek past the end of a file opened for writing
     * EXPANDS it, so an oversized value here would pad the file rather than
     * trim it -- the opposite of what this command is for. */
#if !FF_FS_READONLY
    if (fil_writing && (final_size < (uint32_t)f_size(&fil))) {
        fr = seek_to(final_size);
        if (fr == FR_OK)
            fr = f_truncate(&fil);
    }
#else
    (void)final_size;
#endif

    if (fr == FR_OK)
        fr = f_close(&fil);
    else
        (void)f_close(&fil);

    fil_handle  = 0u;
    fil_writing = false;
    fil_pos     = 0uL;

    status = fres_to_ioc(fr);

    /* Flush here so FAT and directory updates do not sit dirty behind the
     * write-back timer.  A transient that finishes a copy and the user who
     * pulls the card thirty seconds later are the same story. */
    if ((status == IOC_STATUS_OK) && (sd_cache_flush() != SD_OK))
        status = IOC_STATUS_SD_WRITE_FAIL;

    fs_reply(request, reply, RSP_FS_CLOSE, status, 0u);
}

void handler_fs_stat(const IocFrame *request, IocFrame *reply)
{
    char    path[FS_SHARE_PREFIX_LEN + 12u + 1u];
    FILINFO fno;
    uint8_t status = need_fs();
    FRESULT fr;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_STAT, status, 0u);
        return;
    }

    if (!share_path(path, &request->bytes[IOC_OFF_FS_NAME])) {
        fs_reply(request, reply, RSP_FS_STAT, IOC_STATUS_FS_BAD_NAME, 0u);
        return;
    }

    fr = f_stat(path, &fno);
    if (fr != FR_OK) {
        fs_reply(request, reply, RSP_FS_STAT, fres_to_ioc(fr), 0u);
        return;
    }

    fs_reply(request, reply, RSP_FS_STAT, IOC_STATUS_OK,
             IOC_FS_STAT_REPLY_LEN);
    put32(&reply->bytes[IOC_OFF_FS_STAT_SIZE], (uint32_t)fno.fsize);
    reply->bytes[IOC_OFF_FS_STAT_ATTR] = fno.fattrib;
}

void handler_fs_delete(const IocFrame *request, IocFrame *reply)
{
    char    path[FS_SHARE_PREFIX_LEN + 12u + 1u];
    uint8_t status = need_fs();
    FRESULT fr;

    if (status != IOC_STATUS_OK) {
        fs_reply(request, reply, RSP_FS_DELETE, status, 0u);
        return;
    }

    if (!share_path(path, &request->bytes[IOC_OFF_FS_NAME])) {
        fs_reply(request, reply, RSP_FS_DELETE, IOC_STATUS_FS_BAD_NAME, 0u);
        return;
    }

    /* Deleting the file that is open would leave the handle pointing at freed
     * clusters.  Close first; the caller loses nothing it had not already
     * committed. */
    close_current();

#if !FF_FS_READONLY
    fr = f_unlink(path);
    if (fr == FR_OK)
        (void)sd_cache_flush();
#else
    fr = FR_DENIED;             /* read-only firmware: nothing to delete with */
#endif

    fs_reply(request, reply, RSP_FS_DELETE, fres_to_ioc(fr), 0u);
}

/* --------------------------------------------------------------------------
 * Selftest
 * -------------------------------------------------------------------------- */

/* Mount, walk /SHARED/, and checksum the first regular file in it.
 *
 * The point is not the checksum's cryptographic worth -- it is a plain additive
 * sum.  The point is that running it exercises f_mount, f_opendir, f_readdir,
 * f_open, f_read and f_close in one pass, on hardware, and returns numbers that
 * are either right or obviously not.  XC8's overlay allocator has six silent
 * corruptions to its name in the TinyUSB path; this is the cheap way to find
 * out whether FatFs joins them before any data depends on the answer.
 *
 * Uses its own DIR and FIL rather than the shared ones, so a selftest run
 * cannot disturb a transient's listing or open file. */
void handler_fs_selftest(const IocFrame *request, IocFrame *reply)
{
    /* Static, not automatic.  A DIR, a FIL and a FILINFO together are about
     * 120 bytes, and XC8's overlay allocator is the thing this test exists to
     * be suspicious of -- handing it three more large frames to place would be
     * an odd way to go looking for overlay bugs. */
    static DIR     d;
    static FIL     f;
    static FILINFO fno;
    static char    path[FS_SHARE_PREFIX_LEN + 12u + 1u];

    FATFS   *fs;
    FRESULT  fr;
    SdStatus st;
    uint16_t files = 0u;
    uint16_t sum   = 0u;
    uint32_t bytes = 0uL;
    bool     have_file = false;

    fs_reply(request, reply, RSP_FS_SELFTEST, IOC_STATUS_OK,
             IOC_FS_SELFTEST_LEN);

    st = sdfs_mount(&fs);
    if (st != SD_OK) {
        reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_SD_READ_FAIL;
        return;
    }
    if (fs == NULL) {
        reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_FS_NOT_MOUNTED;
        return;
    }

    reply->bytes[IOC_OFF_FS_SELF_MOUNTED] = 1u;
    reply->bytes[IOC_OFF_FS_SELF_FSTYPE]  = fs->fs_type;
    reply->bytes[IOC_OFF_FS_SELF_CSIZE]   = (uint8_t)fs->csize;
    reply->bytes[IOC_OFF_FS_SELF_CSIZE + 1u] = (uint8_t)(fs->csize >> 8);
    put32(&reply->bytes[IOC_OFF_FS_SELF_DATABASE], (uint32_t)fs->database);

    fr = f_opendir(&d, FS_SHARE_DIR);
    if (fr != FR_OK) {
        reply->bytes[IOC_OFF_FS_SELF_FRESULT] = (uint8_t)fr;
        reply->bytes[IOC_OFF_STATUS] = fres_to_ioc(fr);
        return;
    }

    for (;;) {
        fr = f_readdir(&d, &fno);
        if ((fr != FR_OK) || (fno.fname[0] == '\0'))
            break;
        if ((fno.fattrib & AM_DIR) != 0u)
            continue;

        files++;
        if (!have_file) {
            memcpy(path, FS_SHARE_PREFIX, FS_SHARE_PREFIX_LEN);
            strcpy(&path[FS_SHARE_PREFIX_LEN], fno.fname);
            have_file = true;
        }
    }
    (void)f_closedir(&d);

    reply->bytes[IOC_OFF_FS_SELF_FILES]      = (uint8_t)files;
    reply->bytes[IOC_OFF_FS_SELF_FILES + 1u] = (uint8_t)(files >> 8);

    if ((fr == FR_OK) && have_file) {
        fr = f_open(&f, path, FA_READ);
        if (fr == FR_OK) {
            for (;;) {
                UINT     got = 0u;
                uint16_t i;

                fr = f_read(&f, chunk, (UINT)IOC_FS_CHUNK_MAX, &got);
                if ((fr != FR_OK) || (got == 0u))
                    break;

                for (i = 0u; i < (uint16_t)got; i++)
                    sum = (uint16_t)(sum + chunk[i]);

                bytes += got;
            }
            (void)f_close(&f);
        }
    }

    reply->bytes[IOC_OFF_FS_SELF_SUM]      = (uint8_t)sum;
    reply->bytes[IOC_OFF_FS_SELF_SUM + 1u] = (uint8_t)(sum >> 8);
    put32(&reply->bytes[IOC_OFF_FS_SELF_BYTES], bytes);
    reply->bytes[IOC_OFF_FS_SELF_FRESULT] = (uint8_t)fr;

    if (fr != FR_OK)
        reply->bytes[IOC_OFF_STATUS] = fres_to_ioc(fr);
}
