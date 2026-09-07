/* FatFs media layer.
 *
 * Everything here routes through sd_cache rather than sd_card, so FatFs and
 * the CP/M record path share one cached copy of every block.  That is not an
 * optimisation -- it is what makes the two paths incapable of disagreeing, so
 * there is no coherency argument to have.
 *
 * The cache is write-back.  FatFs's own CTRL_SYNC is honoured by flushing it,
 * which is what f_sync() and f_close() end up calling; that is where FAT and
 * directory updates stop being dirty.
 */

#include "ff.h"
#include "diskio.h"

#include "sd_card.h"
#include "sd_cache.h"

/* One physical drive.  FF_VOLUMES is 1 and there is one socket, so a pdrv
 * other than zero is a caller bug rather than a runtime condition. */
#define SDFS_PDRV 0

DSTATUS disk_status(BYTE pdrv)
{
    if (pdrv != SDFS_PDRV)
        return STA_NOINIT;

    /* A state query only.  sd_card_is_initialized() never selects the card or
     * starts initialisation, which matters because FatFs asks this on paths
     * where a second card init would be a surprise. */
    return sd_card_is_initialized() ? 0 : STA_NOINIT;
}

DSTATUS disk_initialize(BYTE pdrv)
{
    if (pdrv != SDFS_PDRV)
        return STA_NOINIT;

    return (sd_card_init() == SD_OK) ? 0 : STA_NOINIT;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv != SDFS_PDRV)
        return RES_PARERR;

    while (count-- != 0u) {
        if (sd_cache_read_block((uint32_t)sector, (uint8_t *)buff) != SD_OK)
            return RES_ERROR;
        buff   += SD_BLOCK_SIZE;
        sector += 1u;
    }

    return RES_OK;
}

#if !FF_FS_READONLY
DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    if (pdrv != SDFS_PDRV)
        return RES_PARERR;

    while (count-- != 0u) {
        if (sd_cache_write_block((uint32_t)sector,
                                 (const uint8_t *)buff) != SD_OK)
            return RES_ERROR;
        buff   += SD_BLOCK_SIZE;
        sector += 1u;
    }

    return RES_OK;
}
#endif

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    (void)buff;

    if (pdrv != SDFS_PDRV)
        return RES_PARERR;

    /* CTRL_SYNC is the only control FatFs issues in this configuration.
     * GET_SECTOR_SIZE is compiled out because FF_MIN_SS == FF_MAX_SS, and
     * GET_SECTOR_COUNT / GET_BLOCK_SIZE are f_mkfs's, which is disabled. */
    if (cmd == CTRL_SYNC)
        return (sd_cache_flush() == SD_OK) ? RES_OK : RES_ERROR;

    return RES_PARERR;
}
