#ifndef VOLUME_H
#define VOLUME_H

#include <stdint.h>
#include <stdbool.h>

#include "ioc_frame.h"
#include "sd_card.h"

/* CP/M volumes: where a relative record actually lives on the card.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------------
 *
 * Until now a CP/M record WAS a card address: record 0 was LBA 0, and the whole
 * card was one 8 MiB volume written to it with dd.  That works, and it is still
 * supported, but it means the card cannot also be a filesystem -- so the images
 * cannot be copied, backed up or edited on a host without raw block tools.
 *
 * This module lets an image be an ordinary file on a FAT32 card instead.  It
 * resolves the file's cluster chain ONCE, at mount, into a small extent table,
 * and after that a CP/M record maps to a card block by table lookup and an add.
 * FatFs is not on the record path at all; sd_cache, the write-back policy, the
 * bulk lane and the READY/DONE lifecycle never learn a filesystem exists.
 *
 * That is safe because the image's SIZE never changes.  CP/M writes into a
 * fixed 8 MiB volume; it does not extend a file.  The cluster chain therefore
 * cannot move while CP/M is running, and the snapshot stays valid for the whole
 * session.
 *
 * ---------------------------------------------------------------------------
 * THE INVARIANT
 * ---------------------------------------------------------------------------
 *
 * NOTHING MAY EVER WRITE A MOUNTED IMAGE THROUGH FATFS.
 *
 * The extent table is a snapshot.  A FatFs write that reallocated or freed
 * those clusters would leave CP/M addressing blocks the filesystem has since
 * handed to something else, and the damage would be silent.  Images live in
 * /CPM/ and every filesystem command is confined to /SHARED/, which makes this
 * structurally impossible rather than a rule somebody has to remember.
 *
 * ---------------------------------------------------------------------------
 * MODES
 * ---------------------------------------------------------------------------
 *
 *   VOL_MODE_FILE   an 8 MiB file on a FAT16/FAT32 card, addressed by extents
 *   VOL_MODE_RAW    the card itself, base LBA 0 -- exactly today's behaviour,
 *                   and what a card with no filesystem falls back to
 *   VOL_MODE_NONE   nothing mounted; every record request is refused
 *
 * The fallback is what keeps every existing card working through this change.
 * It is reported rather than inferred: CMD_VOL_INFO says which mode is live.
 */

/* Two units cover A: and B:.  The extent table is the per-unit cost, so raising
 * this is affordable -- but only once the BIOS grows drive letters to use it. */
#define VOL_UNITS          2u

/* A file copied onto a freshly formatted card is one extent.  Sixteen is far
 * more than a real card produces, and the cap is deliberate: refusing a
 * pathologically fragmented image is better than mis-addressing it, and the
 * remedy -- copy it onto a clean card -- is one the user can act on. */
#define VOL_MAX_EXTENTS    16u

/* Packed 8.3, space padded, no dot.  The FCB layout, so a CP/M transient can
 * drop a name straight into an FCB without parsing anything. */
#define VOL_NAME_LEN       11u

/* An image is exactly 8 MiB: 65536 records of 128 bytes, 16384 card blocks.
 * The CP/M DPB is fixed at that size, so a file of any other length is an
 * error worth reporting rather than something to accommodate. */
#define VOL_IMAGE_RECORDS  65536uL
#define VOL_IMAGE_BLOCKS   (VOL_IMAGE_RECORDS / 4uL)
#define VOL_IMAGE_BYTES    (VOL_IMAGE_RECORDS * 128uL)

typedef enum {
    VOL_MODE_NONE = 0,
    VOL_MODE_RAW  = 1,
    VOL_MODE_FILE = 2
} VolMode;

/* Reset every unit to VOL_MODE_NONE.  Performs no I/O and touches no card. */
void vol_init(void);

/* Attempt the conventional file mounts, once, from the idle branch of the main
 * loop.  Cheap and safe to call every pass; does nothing at all unless the card
 * is already up and the build enables IOC_VOL_AUTOMOUNT.
 *
 * This exists so that FatFs is never entered from underneath a command handler.
 * See the boot-path comment in vol_ensure_mounted(). */
void vol_service(void);

/* True when vol_service() would actually do work.  The main loop drops
 * COMMAND_READY around it in that case: resolving an image walks directory
 * sectors and a whole cluster chain, and the host gates every IOCALL on that
 * line -- so without this a request arriving mid-mount waits past the BIOS's
 * timeout and comes back as IOC_XPORT_TIMEOUT_REPLY_MARKER.  Exactly the rule
 * the SD cache flush already follows. */
bool vol_service_pending(void);

/* Bring up storage addressing, if it has not happened yet.
 *
 * Called from the record path -- which is the path the machine BOOTS on, so it
 * does exactly one thing: initialise the card and put unit 0 in raw mode.  It
 * does not look for a filesystem, because looking is not free and is not safe:
 * see the long comment on the function itself.
 *
 * Idempotent and cheap after the first call. */
SdStatus vol_ensure_mounted(void);

/* Mount a named image on one unit, replacing whatever was there.
 *
 * `name11` is packed 8.3; the controller prepends /CPM/ and builds the path.
 * This exists for a MOUNT.COM to swap volumes at runtime -- boot does not
 * depend on it, which is what keeps the Z80 side free of mount code. */
SdStatus vol_mount(uint8_t unit, const uint8_t *name11);

/* Force the next record access to re-run vol_ensure_mounted().  Used after a
 * card error has invalidated the SD session: the extent tables describe a card
 * that may no longer be the one in the socket. */
void vol_invalidate(void);

/* Read/write one 128-byte record of a mounted unit.
 *
 * `record` is RELATIVE to the volume -- it is exactly what the BIOS computes
 * as track * 4 + sector.  The bound check lives here, against the mounted
 * image's own length, because this is the only layer that knows it.
 *
 * The write path decides write-through here too, for the same reason: the head
 * of the CP/M directory is at RELATIVE record 0, which is only LBA 0 in raw
 * mode.
 *
 * These return a wire status rather than an SdStatus, because the two ways
 * they fail without the card being at fault -- no volume on that unit, and a
 * record past its end -- have no SdStatus to carry them, and reporting either
 * as SD_ERR_READ would send somebody chasing a card problem that is not
 * there. */
uint8_t vol_read_record(uint8_t unit, uint32_t record, uint8_t *dst);
uint8_t vol_write_record(uint8_t unit, uint32_t record, const uint8_t *src);

/* Reporting, for CMD_VOL_INFO.
 *
 * ONE function filling a plain byte block, deliberately -- not the five small
 * accessors this used to be, and above all not a function returning a pointer
 * that may address either RAM or program memory.
 *
 * That construct was:
 *
 *     static const uint8_t blank_name[11] = { ' ', ... };
 *     const uint8_t *vol_name(uint8_t unit)
 *     { return (unit < VOL_UNITS) ? units[unit].name : blank_name; }
 *
 * On PIC18 a `const` object lives in program memory, so that return value is a
 * pointer whose target space is not known until run time, and it was then
 * handed to memcpy().  It is the one construct in this module that asks
 * anything unusual of the compiler, in a firmware whose call graph XC8 already
 * cannot analyse.  It is gone.
 *
 * `out` receives VOL_REPORT_LEN bytes:
 *
 *   0      mode (VolMode)
 *   1      extent count
 *   2..5   base LBA, little endian
 *   6..9   length in 128-byte records, little endian
 *   10..20 image name, packed 8.3, space padded
 *
 * An out-of-range unit yields mode NONE, zeroes and a blank name rather than an
 * error: the caller asked what is on that unit, and "nothing" is the answer. */
#define VOL_REPORT_LEN  (10u + VOL_NAME_LEN)

void vol_report(uint8_t unit, uint8_t *out);

#endif /* VOLUME_H */
