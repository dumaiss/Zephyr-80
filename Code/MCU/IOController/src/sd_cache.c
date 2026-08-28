#include <string.h>

#include "sd_cache.h"
#include "sd_card.h"
#include "timebase.h"

/* One cached 512-byte block.  Every slot participates in the same LRU policy;
 * LBA 0 remains write-through, but is no longer pinned in SRAM. */
typedef struct {
    uint32_t lba;
    uint8_t  data[SD_BLOCK_SIZE];
    uint16_t age;     /* timebase tick of last use; oldest loses */
    bool     valid;
    bool     dirty;
} SdCacheSlot;

static SdCacheSlot slots[SD_CACHE_SLOTS];
static uint16_t    last_flush_tick;

/* Monotonic use counter, separate from the timebase.
 *
 * LRU cannot key off timebase_ticks(): a whole burst of commands can complete
 * inside one 10 ms tick, leaving every slot with an identical age and the
 * eviction choice decided by array order instead of by use.  This counter
 * advances on every access, so the ordering is always real. */
static uint16_t use_counter;

void sd_cache_init(void)
{
    uint8_t i;

    for (i = 0u; i < SD_CACHE_SLOTS; i++) {
        slots[i].lba   = 0uL;
        slots[i].valid = false;
        slots[i].dirty = false;
        slots[i].age   = 0u;
    }

    use_counter     = 0u;
    last_flush_tick = timebase_ticks();
}

static void touch(SdCacheSlot *s)
{
    s->age = ++use_counter;
}

/* Commit one slot if it is dirty.  Clears the dirty bit only on success: a
 * failed write must stay dirty so the next flush retries it, and so a later
 * eviction cannot drop the block on the floor believing it was committed. */
static SdStatus slot_commit(SdCacheSlot *s)
{
    SdStatus st;

    if (!s->valid || !s->dirty)
        return SD_OK;

    st = sd_card_write_block(s->lba, s->data);
    if (st == SD_OK)
        s->dirty = false;

    return st;
}

/* Find the slot holding this LBA, or NULL. */
static SdCacheSlot *lookup(uint32_t lba)
{
    uint8_t i;

    for (i = 0u; i < SD_CACHE_SLOTS; i++) {
        if (slots[i].valid && (slots[i].lba == lba))
            return &slots[i];
    }

    return NULL;
}

/* Choose a victim: an invalid slot if there is one, otherwise the least
 * recently used. */
static SdCacheSlot *choose_victim(void)
{
    uint8_t i;
    uint8_t oldest = 0u;

    for (i = 0u; i < SD_CACHE_SLOTS; i++) {
        if (!slots[i].valid)
            return &slots[i];
    }

    for (i = 1u; i < SD_CACHE_SLOTS; i++) {
        /* Unsigned difference, so the comparison survives use_counter wrapping
         * at 65536.  Comparing the raw values would pick the wrong victim once
         * per wrap, which is a bug that would surface roughly never and be
         * untraceable when it did. */
        if ((uint16_t)(use_counter - slots[i].age) >
            (uint16_t)(use_counter - slots[oldest].age))
            oldest = i;
    }

    return &slots[oldest];
}

static uint16_t cache_misses;

uint16_t sd_cache_misses(void) { return cache_misses; }

/* Get the slot for an LBA, loading it from the card if necessary.
 * Returns NULL with *st set on a card failure. */
static SdCacheSlot *acquire(uint32_t lba, SdStatus *st)
{
    SdCacheSlot *s;

    *st = SD_OK;

    s = lookup(lba);
    if (s != NULL) {
        touch(s);
        return s;
    }

    /* A miss: from here the request costs a real 512-byte card read.  Counted
     * so the hit rate is observable -- with four records per block a sequential
     * file should miss once every four reads, and anything close to one miss
     * per read means the cache is being thrashed rather than used. */
    cache_misses++;

    s = choose_victim();

    /* Evicting a dirty block means committing it first.  If that fails the
     * cache must NOT reuse the slot: doing so would discard data the host was
     * told had been accepted.  Fail the whole request instead and leave the
     * slot dirty for the next flush to retry. */
    *st = slot_commit(s);
    if (*st != SD_OK)
        return NULL;

    *st = sd_card_read_block(lba, s->data);
    if (*st != SD_OK) {
        s->valid = false;
        return NULL;
    }

    s->lba   = lba;
    s->valid = true;
    s->dirty = false;
    touch(s);

    return s;
}

SdStatus sd_cache_read_record(uint32_t record, uint8_t *dst)
{
    SdCacheSlot *s;
    SdStatus     st;

    if (record > SD_CACHE_MAX_RECORD)
        return SD_ERR_READ;

    s = acquire(record >> SD_CACHE_REC_SHIFT, &st);
    if (s == NULL)
        return st;

    memcpy(dst,
           &s->data[(record & SD_CACHE_REC_MASK) * SD_CACHE_RECORD_SIZE],
           SD_CACHE_RECORD_SIZE);

    return SD_OK;
}

SdStatus sd_cache_write_record(uint32_t record, const uint8_t *src)
{
    SdCacheSlot *s;
    SdStatus     st;
    uint32_t     lba;

    if (record > SD_CACHE_MAX_RECORD)
        return SD_ERR_WRITE;

    lba = record >> SD_CACHE_REC_SHIFT;

    /* acquire() reads the block first even though we are about to overwrite a
     * quarter of it.  That read is not optional: the other three records in the
     * block belong to somebody, and writing the block back without them would
     * destroy 384 bytes of unrelated data per write. */
    s = acquire(lba, &st);
    if (s == NULL)
        return st;

    memcpy(&s->data[(record & SD_CACHE_REC_MASK) * SD_CACHE_RECORD_SIZE],
           src,
           SD_CACHE_RECORD_SIZE);
    s->dirty = true;

    if (lba == 0uL)
        return slot_commit(s);      /* write-through */

    return SD_OK;
}

bool sd_cache_dirty(void)
{
    uint8_t i;

    for (i = 0u; i < SD_CACHE_SLOTS; i++) {
        if (slots[i].valid && slots[i].dirty)
            return true;
    }

    return false;
}

SdStatus sd_cache_flush(void)
{
    SdStatus st;
    uint8_t  i;

    for (i = 0u; i < SD_CACHE_SLOTS; i++) {
        st = slot_commit(&slots[i]);
        if (st != SD_OK) {
            /* A failed block write invalidates the SD driver's initialized
             * state.  Do not turn one flush into several init/write attempts;
             * preserve this and all later dirty slots for explicit recovery. */
            last_flush_tick = timebase_ticks();
            return st;
        }
    }

    last_flush_tick = timebase_ticks();
    return SD_OK;
}

bool sd_cache_flush_due(void)
{
#if SD_CACHE_AUTO_FLUSH
    uint16_t now = timebase_ticks();

    if (!sd_cache_dirty())
        return false;

    /* Background policy must never initialise or recover the card.  A dirty
     * slot can only have been created after a successful card access, so false
     * here means a later operation failed and deliberately invalidated that
     * session.  Leave the data dirty until an explicit SD command succeeds. */
    if (!sd_card_is_initialized())
        return false;

    /* Unsigned difference so this keeps working across the counter's 11-minute
     * wrap.  The interval is a floor, not a period: a command that takes longer
     * than it simply means the flush happens at the next idle moment. */
    return (uint16_t)(now - last_flush_tick) >=
           (uint16_t)(SD_CACHE_FLUSH_MS / TIMEBASE_TICK_MS);
#else
    /* Manual bring-up override: explicit flushes still work. */
    return false;
#endif
}

bool sd_cache_tick(void)
{
    if (!sd_cache_flush_due()) {
        /* Keep the interval anchored to real time even when nothing is dirty,
         * so the first write after a long idle is not flushed instantly. */
        if (!sd_cache_dirty())
            last_flush_tick = timebase_ticks();
        return false;
    }

    (void)sd_cache_flush();
    return true;
}
