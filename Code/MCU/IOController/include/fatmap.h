#ifndef FATMAP_H
#define FATMAP_H

#include <stdint.h>
#include <stdbool.h>

/* Read-only FAT16/FAT32 resolver: find one file, hand back where its data
 * physically lives, and get out of the way.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS ALONGSIDE FATFS
 * ---------------------------------------------------------------------------
 *
 * FatFs IS linked in this firmware -- it serves /SHARED/ for the user-space
 * file tools.  This module exists anyway, and the split is the point:
 *
 *   mounting a CP/M image is boot-critical; serving /SHARED/ is not.
 *
 * If image resolution went through FatFs, then every fault in 7,000 lines of
 * general-purpose filesystem code would be a fault in the path the machine
 * needs to reach CP/M at all.  Here it is 500 lines doing exactly one job, with
 * a call graph you can verify by reading it -- which matters more than usual on
 * a part where XC8 cannot analyse the call graph itself (warning 1393, from
 * TinyUSB's function-pointer driver tables).  A bug in FatFs costs a transient.
 * A bug here costs the boot.
 *
 * It is also a third of the size: about +8.7 KB against FatFs's +26.6 KB.
 *
 * HISTORICAL NOTE, because the tree recorded the opposite for a while: this was
 * originally written on the conclusion that FatFs could not be linked into this
 * firmware at all.  That was wrong -- a confound in the bisect, where every
 * build linking FatFs also carried an unrelated defect (a function returning a
 * pointer that might address either RAM or program memory, which reset-looped
 * the PIC from code that never ran).  Once that was fixed, FatFs linked and ran
 * fine.  The reasoning above is why this module was kept, not why it was
 * written.
 *
 * The constraints below are still worth honouring for the reason given, and
 * were cheap to meet:
 *
 *   NO RECURSION.  Every loop here is bounded and flat.
 *   NO FUNCTION POINTERS.  They are what poisoned the call graph elsewhere.
 *   NO BUFFERS.  Directory and FAT entries are read a few bytes at a time
 *   through sd_cache_read_bytes(), so this adds no SRAM beyond one small
 *   geometry struct.  The cache is already holding the sector.
 *   SHALLOW.  Three levels at the deepest, over sd_cache.
 *
 * ---------------------------------------------------------------------------
 * WHAT IT DELIBERATELY DOES NOT DO
 * ---------------------------------------------------------------------------
 *
 * No writing, no creating, no deleting, no directory listing, no long
 * filenames, no FAT12, no exFAT.  This resolves a fixed path to an extent list
 * and nothing else, because that is the entire requirement: the design's
 * premise is that the filesystem is consulted ONCE at mount and is then out of
 * the picture, with every CP/M record afterwards costing a table lookup and an
 * add.  A general filesystem was always more than the job needed; it turned out
 * to be more than the toolchain could carry as well.
 */

/* One contiguous run of a file, in card blocks. */
typedef struct {
    uint32_t start_lba;
    uint32_t blocks;
} FatExtent;

typedef enum {
    FATMAP_OK = 0,
    FATMAP_IO,           /* the card failed a read */
    FATMAP_NO_FS,        /* no FAT16/FAT32 volume found */
    FATMAP_NO_FILE,      /* the directory or the file is not there */
    FATMAP_BAD_SIZE,     /* found, but not the length the caller requires */
    FATMAP_FRAGMENTED    /* more runs than the caller has room for */
} FatMapStatus;

/* Resolve /<dir11>/<name11> into extents.
 *
 * Both names are packed 8.3 -- eleven bytes, space padded, no dot -- because
 * that is the on-disk directory format AND the CP/M FCB format, so no
 * conversion happens anywhere in this path.
 *
 * `want_bytes` is the exact size the file must be; a mismatch is
 * FATMAP_BAD_SIZE rather than a partial mapping.  The caller gets an all-or-
 * nothing answer: on anything but FATMAP_OK, *n_out is 0 and `out` is
 * untouched.
 *
 * Volume geometry is cached across calls, so resolving a second image costs
 * only its two directory scans and its chain walk. */
FatMapStatus fatmap_resolve(const uint8_t *dir11, const uint8_t *name11,
                            uint32_t want_bytes,
                            FatExtent *out, uint8_t max_extents,
                            uint8_t *n_out);

/* Forget the cached geometry.  Call when the card session is lost: the
 * geometry describes a card that may not be the one in the socket. */
void fatmap_invalidate(void);

/* True once a FAT volume has been found and its geometry cached.  For
 * reporting only -- fatmap_resolve() mounts on demand. */
bool fatmap_mounted(void);

#endif /* FATMAP_H */
