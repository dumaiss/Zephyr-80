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
 * The BIOS already computes record = track * 4 + sector for the VDrip backend,
 * and that number is exactly what arrives here -- 8 MiB / 128 = 65536 records,
 * so the whole volume fits a 16-bit record number.  The wire field is 32 bits
 * anyway: widening a protocol field later is a breaking change, and this one is
 * sitting precisely at its limit.
 *
 * Record 0 is LBA 0.  The volume has no reserved boot tracks -- CP/M lives in
 * ROM -- and no partition table, so a host OS will see the card as unformatted.
 *
 * ---------------------------------------------------------------------------
 * WRITE POLICY
 * ---------------------------------------------------------------------------
 *
 * Write-back, except LBA 0 which is write-through.
 *
 * That is an ADDRESS rule, not a filesystem rule, and the distinction is the
 * whole point: this module knows nothing about directories, extents or
 * allocation vectors, and must not learn.  It happens that LBA 0 is where CP/M
 * keeps the head of its directory, so committing it synchronously buys back
 * most of the exposure a write-back cache creates, at one card write per
 * directory update.
 *
 * Be honest about the coverage: with BLS=4096 and AL0=F0h the directory is four
 * blocks -- 16 KiB, LBA 0..31.  Write-through on LBA 0 covers 1/32 of it.  The
 * rest rides the flush timer, so the exposure is a power loss during a burst
 * that never went idle.  Small, but not zero, and worth knowing rather than
 * assuming away.
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

#define SD_CACHE_SLOTS      4u
#define SD_CACHE_FLUSH_MS   100u

/* Set to 0 to disable idle flushing without changing explicit CMD_SD_FLUSH or
 * the pinned LBA-0 write-through path.  The initialized-state gate in
 * sd_cache_flush_due() prevents a failed card from creating a retry storm. */
#ifndef SD_CACHE_AUTO_FLUSH
#define SD_CACHE_AUTO_FLUSH 1
#endif

/* Records per block, and the shift/mask that follow from it. */
#define SD_CACHE_RECORD_SIZE    128u
#define SD_CACHE_RECS_PER_BLOCK (SD_BLOCK_SIZE / SD_CACHE_RECORD_SIZE)
#define SD_CACHE_REC_SHIFT      2u
#define SD_CACHE_REC_MASK       (SD_CACHE_RECS_PER_BLOCK - 1u)

/* Highest record the 8 MiB volume holds.  Requests past this are refused rather
 * than wrapped: a wrapped record is a write to the wrong sector, which is the
 * one failure mode that destroys data while reporting success. */
#define SD_CACHE_MAX_RECORD  0xFFFFuL

void sd_cache_init(void);

/* Copy one 128-byte record out of the cache, reading the card on a miss. */
SdStatus sd_cache_read_record(uint32_t record, uint8_t *dst);

/* Copy one 128-byte record into the cache.  Reads the containing block first on
 * a miss -- a partial write cannot be committed without the other three
 * records.  Returns the card status of that read, or of the immediate commit
 * when the record lands in the write-through block. */
SdStatus sd_cache_write_record(uint32_t record, const uint8_t *src);

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
