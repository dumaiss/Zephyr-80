#ifndef SD_CARD_H
#define SD_CARD_H

#include <stdint.h>
#include <stdbool.h>

/* SD card on the port C peripheral bus (SPI1), select /IO_SD_CS on RA2.
 *
 * Card sits on the mezzanine connector.  SPI mode only -- no SD native 4-bit
 * bus, no DMA, no multi-block.  Enough to read blocks for bring-up.
 */

#define SD_BLOCK_SIZE 512u

typedef enum {
    SD_OK = 0,
    SD_ERR_NO_RESPONSE,   /* card never answered a command */
    SD_ERR_UNUSABLE,      /* answered, but not a card this driver supports */
    SD_ERR_NOT_READY,     /* ACMD41 never reported ready */
    SD_ERR_READ,          /* CMD17 rejected, or no data token arrived */
    SD_ERR_BUS            /* the SPI module itself stalled */
} SdStatus;

/* Run the SPI-mode initialisation sequence.
 *
 * Blocking, and can take up to about a second on a slow card because ACMD41 is
 * polled until the card leaves idle.  Safe to call repeatedly; a successful
 * result is cached and later calls return immediately. */
SdStatus sd_card_init(void);

/* Read one 512-byte block into buf.
 *
 * Initialises the card first if that has not happened yet, so callers do not
 * have to sequence it.  lba is a block number; the driver converts to a byte
 * address internally for standard-capacity cards. */
SdStatus sd_card_read_block(uint32_t lba, uint8_t *buf);

#endif /* SD_CARD_H */
