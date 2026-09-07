#include <string.h>

#include "volume.h"
#include "sd_card.h"
#include "sd_cache.h"
#include "fatmap.h"
#include "boot_guard.h"

typedef struct {
    VolMode   mode;
    uint8_t   n_extents;
    uint32_t  records;                    /* volume length, 128-byte records */
    uint8_t   name[VOL_NAME_LEN];
    FatExtent extent[VOL_MAX_EXTENTS];
} VolUnit;

static VolUnit units[VOL_UNITS];

/* False until vol_ensure_mounted() has run to completion once. */
static bool mount_attempted;

/* False until vol_service() has made its one auto-mount attempt.  Separate from
 * mount_attempted because they are answers to different questions: one is "is
 * there a volume to read", the other is "have we already tried the filesystem
 * and been told no". */
static bool automount_done;

void vol_init(void)
{
    uint8_t u;

    for (u = 0u; u < VOL_UNITS; u++) {
        units[u].mode      = VOL_MODE_NONE;
        units[u].n_extents = 0u;
        units[u].records   = 0uL;
        memset(units[u].name, ' ', VOL_NAME_LEN);
    }

    mount_attempted = false;
    automount_done  = false;
}

void vol_invalidate(void)
{
    vol_init();
    fatmap_invalidate();
}

void vol_report(uint8_t unit, uint8_t *out)
{
    const VolUnit *v;
    uint32_t       base;
    uint8_t        i;

    for (i = 0u; i < VOL_REPORT_LEN; i++)
        out[i] = 0u;

    /* Blank the name field explicitly.  No const source, no returned pointer:
     * the padding is written here, in RAM, by this loop. */
    for (i = 0u; i < VOL_NAME_LEN; i++)
        out[10u + i] = ' ';

    if (unit >= VOL_UNITS)
        return;

    v    = &units[unit];
    base = (v->n_extents != 0u) ? v->extent[0].start_lba : 0uL;

    out[0] = (uint8_t)v->mode;
    out[1] = v->n_extents;

    out[2] = (uint8_t)base;
    out[3] = (uint8_t)(base >> 8);
    out[4] = (uint8_t)(base >> 16);
    out[5] = (uint8_t)(base >> 24);

    out[6] = (uint8_t)v->records;
    out[7] = (uint8_t)(v->records >> 8);
    out[8] = (uint8_t)(v->records >> 16);
    out[9] = (uint8_t)(v->records >> 24);

    for (i = 0u; i < VOL_NAME_LEN; i++)
        out[10u + i] = v->name[i];
}

/* ---------------------------------------------------------------------------
 * Record mapping
 *
 * The whole hot path is here: a bound check, a walk of at most sixteen
 * extents, and an add.  Nothing on this path can fail for a filesystem reason,
 * because no filesystem code runs on it.
 * --------------------------------------------------------------------------- */

/* Translate a relative record to an absolute card record.
 * Returns false if the unit is unmounted or the record is past its end. */
static bool vol_map(uint8_t unit, uint32_t record, uint32_t *abs_record)
{
    const VolUnit *v;
    uint32_t       lba;
    uint32_t       i;

    if (unit >= VOL_UNITS)
        return false;

    v = &units[unit];
    if (v->mode == VOL_MODE_NONE)
        return false;

    /* The bound that SD_CACHE_MAX_RECORD used to be.  It has to be here: the
     * cache sees absolute records on a card of unknown size and has nothing
     * left to compare them against.  Refused rather than wrapped -- a wrapped
     * record is a write to the wrong sector, which destroys data while
     * reporting success. */
    if (record >= v->records)
        return false;

    lba = record >> SD_CACHE_REC_SHIFT;

    for (i = 0u; i < v->n_extents; i++) {
        if (lba < v->extent[i].blocks) {
            *abs_record = ((v->extent[i].start_lba + lba)
                           << SD_CACHE_REC_SHIFT)
                        | (record & SD_CACHE_REC_MASK);
            return true;
        }
        lba -= v->extent[i].blocks;
    }

    /* Unreachable while records and the extent table agree.  Refusing rather
     * than falling through keeps a table-building bug from becoming a write to
     * an arbitrary sector. */
    return false;
}

/* Why the mapping failed, so the two non-card reasons stay distinguishable. */
static uint8_t map_failure(uint8_t unit)
{
    if ((unit >= VOL_UNITS) || (units[unit].mode == VOL_MODE_NONE))
        return IOC_STATUS_VOL_UNMOUNTED;

    return IOC_STATUS_VOL_RANGE;
}

uint8_t vol_read_record(uint8_t unit, uint32_t record, uint8_t *dst)
{
    uint32_t abs_record;
    SdStatus st;

    st = vol_ensure_mounted();
    if (st != SD_OK)
        return ioc_status_from_sd(st);

    if (!vol_map(unit, record, &abs_record))
        return map_failure(unit);

    return ioc_status_from_sd(sd_cache_read_record(abs_record, dst));
}

uint8_t vol_write_record(uint8_t unit, uint32_t record, const uint8_t *src)
{
    uint32_t abs_record;
    SdStatus st;

    st = vol_ensure_mounted();
    if (st != SD_OK)
        return ioc_status_from_sd(st);

    if (!vol_map(unit, record, &abs_record))
        return map_failure(unit);

    /* Write-through for the block holding the head of the CP/M directory.
     *
     * This is the line the old `lba == 0` test in sd_cache.c became.  The test
     * is on the RELATIVE record, so it follows the volume wherever it lives;
     * the old absolute one would now be testing the card's boot sector, and
     * would fail silently -- the directory head would simply stop being
     * committed synchronously. */
    return ioc_status_from_sd(
        sd_cache_write_record(abs_record, src,
                              record < SD_CACHE_RECS_PER_BLOCK));
}

/* ---------------------------------------------------------------------------
 * Mounting
 * --------------------------------------------------------------------------- */

/* Build "/CPM/NAME.EXT" from a packed 8.3 name.  The caller never supplies a
 * path: the directory is fixed here, which is what confines images to /CPM/. */
static void image_path(char *out, const uint8_t *name11)
{
    uint8_t i;
    uint8_t n = 0u;

    memcpy(out, "/CPM/", 5u);
    n = 5u;

    for (i = 0u; i < 8u; i++) {
        if (name11[i] == ' ')
            break;
        out[n++] = (char)name11[i];
    }

    if (name11[8] != ' ') {
        out[n++] = '.';
        for (i = 8u; i < VOL_NAME_LEN; i++) {
            if (name11[i] == ' ')
                break;
            out[n++] = (char)name11[i];
        }
    }

    out[n] = '\0';
}

/* Mount one unit in raw mode: the card itself, base LBA 0.  Exactly the
 * addressing the firmware used before volumes existed. */
static void mount_raw(uint8_t unit)
{
    VolUnit *v = &units[unit];

    v->mode              = VOL_MODE_RAW;
    v->n_extents         = 1u;
    v->extent[0].start_lba = 0uL;
    v->extent[0].blocks    = VOL_IMAGE_BLOCKS;
    v->records           = VOL_IMAGE_RECORDS;
    memcpy(v->name, "*RAW*      ", VOL_NAME_LEN);
}

SdStatus vol_mount(uint8_t unit, const uint8_t *name11)
{
    /* The directory images live in, packed 8.3.  Fixed here so a caller can
     * never supply a path -- which is what keeps a user program structurally
     * unable to reach an image, rather than merely discouraged from it. */
    static const uint8_t cpm_dir[VOL_NAME_LEN] = {
        'C', 'P', 'M', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '
    };

    VolUnit     *v;
    FatMapStatus fst;
    uint8_t      n = 0u;

    if (unit >= VOL_UNITS)
        return SD_ERR_READ;

    /* The guard has tripped: this is the path under suspicion, so it is the
     * path that gets skipped.  Raw mode still works and the machine still
     * boots, which is what makes the failure interrogable at all. */
    if (boot_degraded())
        return SD_ERR_UNUSABLE;

    v = &units[unit];

    /* Drop the old mount before anything can fail.  A unit left describing a
     * file that is no longer the one being addressed is worse than one left
     * unmounted, which simply refuses every record. */
    v->mode      = VOL_MODE_NONE;
    v->n_extents = 0u;
    v->records   = 0uL;
    memset(v->name, ' ', VOL_NAME_LEN);

    fst = fatmap_resolve(cpm_dir, name11, VOL_IMAGE_BYTES,
                         v->extent, VOL_MAX_EXTENTS, &n);

    if (fst != FATMAP_OK) {
        switch (fst) {
        case FATMAP_IO:   return SD_ERR_READ;
        case FATMAP_NO_FS:
        case FATMAP_NO_FILE: return SD_ERR_NO_RESPONSE;  /* nothing to mount */
        default:          return SD_ERR_UNUSABLE;        /* wrong size, or too
                                                          * fragmented */
        }
    }

    memcpy(v->name, name11, VOL_NAME_LEN);
    v->n_extents = n;
    v->records   = VOL_IMAGE_RECORDS;
    v->mode      = VOL_MODE_FILE;

    return SD_OK;
}

/* The two images the controller mounts by convention.  Packed 8.3, so these
 * are the same eleven bytes a CP/M FCB would hold. */
static const uint8_t default_image[VOL_UNITS][VOL_NAME_LEN] = {
    { 'C', 'P', 'M', '_', '1', ' ', ' ', ' ', 'D', 'R', 'V' },
    { 'C', 'P', 'M', '_', '2', ' ', ' ', ' ', 'D', 'R', 'V' }
};

SdStatus vol_ensure_mounted(void)
{
    SdStatus st;

    /* Fast path, and the only one the CP/M record path normally takes: two
     * state reads and a return. */
    if (mount_attempted && sd_card_is_initialized())
        return SD_OK;

    /* The card session was lost.  Everything mounted describes a card that may
     * not be the one in the socket any more -- an extent table pointing into
     * another card's clusters would address arbitrary data while reporting
     * success, so it is discarded rather than re-validated. */
    if (mount_attempted) {
        vol_init();
        fatmap_invalidate();
    }

    st = sd_card_init();
    if (st != SD_OK)
        return st;

    mount_attempted = true;

    /* ===================================================================
     * THE BOOT PATH DOES NOT TOUCH FATFS.  NOT EVEN TO LOOK.
     * ===================================================================
     *
     * This function is reached from the CP/M record handlers, which is the
     * path the machine boots on.  It used to attempt the conventional file
     * mounts here, and that was wrong twice over:
     *
     * 1. On a raw dd'd card there is no filesystem, but f_mount does not stop
     *    at "no FAT here".  It reads sector 0 -- which on such a card is the
     *    head of the CP/M directory -- and then reads bytes 446..509 of it as
     *    an MBR partition table.  Those bytes are directory entries.  FatFs
     *    duly probes whatever LBAs they decode to, the reads fail somewhere
     *    past the end of the card, and the failure invalidates the SD session
     *    that the boot was about to use.
     *
     * 2. Whatever the deepest FatFs call chain costs in PIC18 hardware call
     *    stack, it was being spent underneath main -> service_command_request
     *    -> dispatch_command -> handler -> here.  STVREN is ON, so overflowing
     *    the 31-level stack resets the device -- and since the controller
     *    drives the host reset pair, that presents as a machine that reboots
     *    continuously with nothing to say why.
     *
     * So the default is raw mode, reached with exactly the card I/O the
     * firmware did before volumes existed: none beyond sd_card_init().  A
     * file-backed image is mounted by vol_service() from the idle branch of
     * the main loop, or on demand by CMD_VOL_MOUNT -- never from here.
     */
    /* Raw is a FALLBACK, never a reset.
     *
     * This used to be unconditional, which was safe only while this function
     * was guaranteed to run before anything else could mount a unit.  It is
     * not any more: vol_service() now auto-mounts as soon as the card is up by
     * any path -- including the BIOS's selection probe -- so by the time the
     * first CP/M record read arrives, unit 0 may already be serving
     * /CPM/CPM_1.DRV.  Overwriting that with raw addressing pointed B: at the
     * card's own boot sector while C:, which mount_raw() does not touch, went
     * on working from its file.  VOLINFO reported exactly that: unit 0 raw,
     * unit 1 file. */
    if (units[0].mode == VOL_MODE_NONE)
        mount_raw(0u);

    return SD_OK;
}

/* ---------------------------------------------------------------------------
 * Auto-mount, from the main loop only
 * --------------------------------------------------------------------------- */

/* Attempt the conventional file mounts once.
 *
 * Called from the idle branch of the main loop, which is where the SD flush
 * and hid_host_task() already live and for the same reasons: no command is in
 * flight, nothing is waiting on a reply, and the call sits two levels below
 * main instead of six.
 *
 * Default OFF.  Turning it on is a deliberate act, because until it has been
 * run on real hardware it is a change to the boot behaviour of a machine whose
 * only other volume is a ROM disk.  Build with -DIOC_VOL_AUTOMOUNT=1 to enable;
 * CMD_VOL_MOUNT reaches the same code with the same safety and needs no
 * rebuild. */
/* ON by default: confirmed working on hardware -- the controller resolves
 * /CPM/CPM_1.DRV out of a FAT card and CP/M reads it.  Build with
 * -DIOC_VOL_AUTOMOUNT=0 to fall back to raw addressing without a source edit. */
#ifndef IOC_VOL_AUTOMOUNT
#define IOC_VOL_AUTOMOUNT 1
#endif


bool vol_service_pending(void)
{
#if IOC_VOL_AUTOMOUNT
    /* Deliberately NOT gated on mount_attempted.
     *
     * It was, and that made the auto-mount depend on a CP/M RECORD read having
     * already happened -- so selecting a unit-1 drive first, before anything
     * touched B:, found nothing mounted and failed.  The card being up is the
     * only real precondition, and sd_card_is_initialized() is a state query
     * that performs no I/O, so this still never initialises the card itself. */
    return (!automount_done) && sd_card_is_initialized() && !boot_degraded();
#else
    return false;
#endif
}

void vol_service(void)
{
#if IOC_VOL_AUTOMOUNT
    uint8_t u;

    if (automount_done)
        return;

    /* Any path may have brought the card up -- a record read, or the BIOS's
     * selection probe.  This must never be the thing that initialises it: an
     * idle-loop card init would run while the host waits on COMMAND_READY. */
    if (!sd_card_is_initialized() || boot_degraded())
        return;

    automount_done = true;

    for (u = 0u; u < VOL_UNITS; u++) {
        if (vol_mount(u, default_image[u]) != SD_OK)
            break;      /* no filesystem, or no image: raw mode stands */
    }
#endif
}
