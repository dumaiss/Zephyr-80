#ifndef SDFS_H
#define SDFS_H

#include <stdint.h>
#include <stdbool.h>

#include "ff.h"
#include "sd_card.h"

/* The one FatFs volume on the SD card.
 *
 * Two things need it and neither should own it: volume.c resolves image files
 * into extent tables at mount, and fs_share.c serves /SHARED/ to CP/M user
 * space.  Both go through here so there is exactly one FATFS object and one
 * mount attempt.
 *
 * A card with no filesystem is not an error.  sdfs_mount() reports that by
 * returning SD_OK with a NULL FATFS, and volume.c falls back to raw mode --
 * which is what keeps every dd'd card working.
 */

/* Mount if not already mounted.  *fs receives the filesystem object, or NULL
 * if the card carries no FAT16/FAT32 volume.  The return is the card status:
 * SD_OK with *fs NULL means "the card is fine, it just isn't formatted".
 *
 * The result is cached, so this is cheap after the first call.  fs may not be
 * NULL. */
SdStatus sdfs_mount(FATFS **fs);

/* True once a filesystem is mounted. */
bool sdfs_ready(void);

/* Discard the mount so the next sdfs_mount() re-reads the card.  Used after a
 * card failure: the cached geometry describes a card that may not be the one
 * in the socket any more. */
void sdfs_invalidate(void);

#endif /* SDFS_H */
