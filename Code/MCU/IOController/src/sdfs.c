#include <string.h>

#include "sdfs.h"
#include "sd_card.h"
#include "sd_cache.h"
#include "ff.h"

/* The single FATFS object.  In FF_FS_TINY mode this carries the only 512-byte
 * sector window in the system: every FIL and DIR shares it, which is what
 * holds the whole library's RAM cost under a kilobyte. */
static FATFS fs_obj;
static bool  fs_mounted;


bool sdfs_ready(void)
{
    return fs_mounted;
}

void sdfs_invalidate(void)
{
    if (fs_mounted) {
        /* Unregister rather than just clearing the flag: FatFs keeps a pointer
         * to fs_obj in its own volume table, and a stale one would be handed
         * back to any f_* call that arrived before the next mount. */
        (void)f_mount(NULL, "", 0);
        fs_mounted = false;
    }

    memset(&fs_obj, 0, sizeof(fs_obj));
}

SdStatus sdfs_mount(FATFS **fs)
{
    FRESULT  fr;
    SdStatus st;

    *fs = NULL;

    if (fs_mounted) {
        *fs = &fs_obj;
        return SD_OK;
    }

    /* Bring the card up explicitly.  f_mount with the mount-now option would
     * do it through disk_initialize(), but then a card fault and a missing
     * filesystem would come back as the same FRESULT, and those two need
     * different answers: one is an error, the other is raw mode. */
    st = sd_card_init();
    if (st != SD_OK)
        return st;

    /* ===================================================================
     * LOOK BEFORE HANDING THE CARD TO FATFS
     * ===================================================================
     *
     * f_mount does not stop politely at "there is no filesystem here".  When
     * sector 0 is not a FAT boot record it treats bytes 446..509 of it as an
     * MBR partition table and probes the four LBAs it finds there.
     *
     * On a raw dd'd CP/M card sector 0 is the head of the CP/M directory, so
     * those bytes are filename and allocation-map data.  The LBAs they decode
     * to are arbitrary -- typically far past the end of the card -- and the
     * reads that follow fail and invalidate the SD session.  A card that
     * worked perfectly before is then unusable, and the reason is a filesystem
     * probe it never asked for.
     *
     * One block read and one 16-bit compare closes that off.  Both an MBR and
     * a FAT volume boot record carry 55AAh at offset 510; a CP/M directory
     * sector does not, except by coincidence.  A card without it is reported
     * as "no filesystem", which is exactly what it is. */
    {
        uint8_t sig[2];

        if (sd_cache_read_bytes(0uL, SD_BLOCK_SIZE - 2u, 2u, sig) != SD_OK)
            return SD_ERR_READ;

        if ((sig[0] != 0x55u) || (sig[1] != 0xAAu))
            return SD_OK;        /* no signature: not a FAT card */
    }

    /* Option 1: mount immediately, so a card with no filesystem is discovered
     * here instead of on the first f_open. */
    fr = f_mount(&fs_obj, "", 1);
    if (fr != FR_OK) {
        memset(&fs_obj, 0, sizeof(fs_obj));
        return SD_OK;            /* no filesystem; not a card failure */
    }

    fs_mounted = true;
    *fs = &fs_obj;

    return SD_OK;
}
