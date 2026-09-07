#ifndef SD_CACHE_H
#define SD_CACHE_H

#include <stdint.h>
#include <stdbool.h>

#include "sd_card.h"

/* Write-back block cache in front of the SD card, addressed by CP/M record.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS
 * ---------------------------------------------------------------------------
 *
 * CP/M's unit of I/O is a 128-byte record; the card's is a 512-byte block.
 * Somebody has to bridge the two.  Doing it on the Z80 costs a 512-byte buffer
 * in a BIOS that has 844 spare bytes of code space, plus deblocking logic, plus
 * a pre-read on every partial write.  Doing it here costs SRAM the PIC has in
 * abundance and firmware that is trivial to change.
 *
 * So the BIOS asks for a record and gets a record.  It never learns that the
 * card has blocks at all.
 *
 * ---------------------------------------------------------------------------
 * RECORD ADDRESSING
 * ---------------------------------------------------------------------------
 *
 *   lba    = record >> 2          four 128-byte records per 512-byte block
 *   offset = (record & 3) << 7
 *
 * The record numbers reaching this module are ABSOLUTE card records, not the
 * relative ones the BIOS sends.  volume.c does the translation, because it is
 * the only thing that knows where a mounted image starts.  A 32 GB card holds
 * about 2^30 records, so the arithmetic here is 32-bit throughout and there is
 * no upper bound left to check -- SD_CACHE_MAX_RECORD is gone, and the bound it
 * enforced now lives in vol_map() as a check of the RELATIVE record against the
 * mounted image's length.  That check is not optional: a wrapped or
 * out-of-range record is a write to the wrong sector, the one failure mode that
 * destroys data while reporting success.
 *
 * FatFs shares this cache rather than keeping its own.  Its disk_read/disk_write
 * land on sd_cache_read_block()/sd_cache_write_block() below, so there is
 * exactly one cached copy of any card block and the two paths cannot disagree.
 *
 * ---------------------------------------------------------------------------
 * WRITE POLICY
 * ---------------------------------------------------------------------------
 *
 * Write-back, except for blocks the CALLER marks write-through.
 *
 * This used to be "LBA 0 is write-through", decided here.  That was correct
 * only while the CP/M volume started at LBA 0.  Once an image can live inside
 * a file, relative record 0 is somewhere else entirely and LBA 0 is the card's
 * own boot sector -- so the rule had to move out of this module, which has no
 * way to know where a volume begins.
 *
 * The volume layer now decides, and passes the answer in.  It still means the
 * same thing: the block holding the head of the CP/M directory is committed
 * synchronously.  A write-through block otherwise participates in the ordinary
 * LRU policy; no slot is reserved for it.
 *
 * Getting this wrong is silent.  Nothing fails, no status changes -- the
 * directory head simply stops being committed synchronously and rides the
 * flush timer with everything else.
 *
 * Be honest about the coverage: with BLS=4096 and AL0=F0h the directory is four
 * blocks -- 16 KiB, 32 card blocks.  Write-through on the first one covers
 * 1/32 of it.  The rest rides the flush timer, so the exposure is a power loss
 * during a burst that never went idle.  Small, but not zero, and worth knowing
 * rather than assuming away.
 *
 * ---------------------------------------------------------------------------
 * WHEN THE FLUSH RUNS
 * ---------------------------------------------------------------------------
 *
 * Automatic idle flushing runs only while the SD driver has a successfully
 * initialised session.  It never initiates or retries card initialisation: an
 * explicit SD command must recover the card after a failure.  The main loop
 * then acts on dirty slots after SD_CACHE_FLUSH_MS have elapsed.
 */

/* Block loads actually issued to the card.  Compare against the record-read
 * count in the PING reply: four records share one block, so a sequential read
 * should show roughly one miss per four records. */
uint16_t sd_cache_misses(void);

/* Eight entries double the original cache capacity without making a timed
 * write-back pass unreasonably long or consuming most of the MCU's data RAM. */
#define SD_CACHE_SLOTS      8u
#define SD_CACHE_FLUSH_MS   100u

/* Set to 0 to disable idle flushing without changing explicit CMD_SD_FLUSH or
 * the LBA-0 write-through path.  The initialized-state gate in
 * sd_cache_flush_due() prevents a failed card from creating a retry storm. */
#ifndef SD_CACHE_AUTO_FLUSH
#define SD_CACHE_AUTO_FLUSH 1
#endif

/* Records per block, and the shift/mask that follow from it. */
#define SD_CACHE_RECORD_SIZE    128u
#define SD_CACHE_RECS_PER_BLOCK (SD_BLOCK_SIZE / SD_CACHE_RECORD_SIZE)
#define SD_CACHE_REC_SHIFT      2u
#define SD_CACHE_REC_MASK       (SD_CACHE_RECS_PER_BLOCK - 1u)

void sd_cache_init(void);

/* Copy one 128-byte record out of the cache, reading the card on a miss.
 * `record` is an absolute card record; see RECORD ADDRESSING above. */
SdStatus sd_cache_read_record(uint32_t record, uint8_t *dst);

/* Copy one 128-byte record into the cache.  Reads the containing block first on
 * a miss -- a partial write cannot be committed without the other three
 * records.  Returns the card status of that read, or of the immediate commit
 * when `write_through` is set. */
SdStatus sd_cache_write_record(uint32_t record, const uint8_t *src,
                               bool write_through);

/* Whole-block access, for FatFs's disk_read/disk_write.
 *
 * Same slots, same LRU, same flush timer as the record path -- which is the
 * entire reason these exist rather than FatFs owning a buffer of its own.  A
 * filesystem structure and a CP/M record can share a card block (they will not
 * in practice, but nothing enforces it), and one cache means that case cannot
 * produce two divergent copies.
 *
 * Always write-back: FAT and directory updates are flushed explicitly by the
 * filesystem commands when they matter, and on shutdown. */
SdStatus sd_cache_read_block(uint32_t lba, uint8_t *dst);
SdStatus sd_cache_write_block(uint32_t lba, const uint8_t *src);

/* Copy `len` bytes from within one cached block.
 *
 * For a caller that wants a couple of bytes out of a sector and has no reason
 * to own half a kilobyte of SRAM to get them -- the filesystem signature check
 * in sdfs.c is the case this exists for.  Reads the card on a miss, exactly
 * like every other entry point here. */
SdStatus sd_cache_read_bytes(uint32_t lba, uint16_t offset, uint16_t len,
                             uint8_t *dst);

/* Commit dirty slots until all succeed or one card operation fails.  Stopping
 * on the first failure avoids several re-initialisation attempts in one call. */
SdStatus sd_cache_flush(void);

/* With automatic flushing enabled, true when the card is already initialized,
 * something is dirty, and the interval elapsed.  This query performs no I/O. */
bool sd_cache_flush_due(void);

/* Perform an automatic timed flush when enabled and due.  Returns false without
 * touching the card when SD_CACHE_AUTO_FLUSH is zero. */
bool sd_cache_tick(void);

/* True if any slot is dirty.  Lets the main loop skip the whole flush path. */
bool sd_cache_dirty(void);

#endif /* SD_CACHE_H */
