#include <xc.h>
#include <string.h>
#include "handlers.h"
#include "ioc_frame.h"
#include "config.h"
#include "sd_card.h"
#include "sd_cache.h"
#include "external_sync.h"
#include "timebase.h"

/* Every record read the host asks for, whether it hits the cache or not.  This
 * is the number that says whether CP/M is issuing the reads the file size
 * implies, or many times more.  Defined here rather than beside its handler so
 * handler_ping(), which reports it, sees it. */
static uint16_t rec_reads;
#include "bulk_channel.h"

void handler_ping(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_PING;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
    /* The common packet is variable length.  Include every diagnostic byte
     * through offset 29; the first 16 payload bytes still echo the request. */
    reply->bytes[IOC_OFF_LEN]    = IOC_COMMAND_MAX_DATA;
    /* Echo test pattern from payload bytes 4-19 */
    memcpy(&reply->bytes[IOC_OFF_PAYLOAD],
           &request->bytes[IOC_OFF_PAYLOAD],
           16u);
    /* Bytes 20-31: reserved, already zero from memset -- except the firmware
     * level, so a host never has to infer which build answered. */
    reply->bytes[IOC_OFF_PING_LEVEL] = IOC_FW_LEVEL;

    /* Power handshake snapshot; see IOC_OFF_PING_POWER. */
    {
        uint8_t p = 0u;
        if (PWR_OFF_PORT)          p |= IOC_PING_PWR_OFF_PIN;
        if (PWR_OFF_LAT)           p |= IOC_PING_PWR_OFF_LAT;
        if (PWR_OFF_TRIS == 0u)    p |= IOC_PING_PWR_OFF_DRIVEN;
        if (SHUTDOWN_RQ_PORT)      p |= IOC_PING_SHUTDOWN_PIN;
        if (PIR10bits.INT2IF)      p |= IOC_PING_SHUTDOWN_LATCH;
        if (SHUTDOWN_RQ_WPU)       p |= IOC_PING_SHUTDOWN_WPU;
        if (external_sync_is_established()) p |= IOC_PING_LINK_SYNCED;
        reply->bytes[IOC_OFF_PING_POWER] = p;
    }

    /* Service-loop accounting, carried by PING itself so it survives a link too
     * flaky to complete a second transaction. */
    {
        extern uint16_t svc_calls, svc_aborts;
        uint16_t r = svc_calls;
        uint16_t i = svc_aborts;
        reply->bytes[IOC_OFF_PING_CALLS_LO]  = (uint8_t)r;
        reply->bytes[IOC_OFF_PING_CALLS_HI]  = (uint8_t)(r >> 8);
        reply->bytes[IOC_OFF_PING_ABORTS_LO] = (uint8_t)i;
        reply->bytes[IOC_OFF_PING_ABORTS_HI] = (uint8_t)(i >> 8);

        r = external_sync_last_rx_edges();
        i = external_sync_last_tx_edges();
        reply->bytes[IOC_OFF_PING_RX_EDGES_LO] = (uint8_t)r;
        reply->bytes[IOC_OFF_PING_RX_EDGES_HI] = (uint8_t)(r >> 8);
        reply->bytes[IOC_OFF_PING_TX_EDGES_LO] = (uint8_t)i;
        reply->bytes[IOC_OFF_PING_TX_EDGES_HI] = (uint8_t)(i >> 8);
    }
}

/* RESET is a terminal, disruptive command.
 * Assert the host reset pair for ~10 ms, then reset the MCU.
 * This function does not return normally.
 */
void handler_reset(void)
{
    /* Assert host reset (same polarity as boot_reset_pulse) */
    HOST_RESET_LAT      = HOST_RESET_ASSERTED;
    HOST_RESET_HIGH_LAT = HOST_RESET_HIGH_ASSERTED;

    /* Hold for ~10 ms at 64 MHz (rough busy-wait) */
    __delay_ms(10);

    /* Self-reset via software reset — MCU will restart and re-run boot */
    RESET();

    /* Should not reach here.  Spin as a fallback. */
    for (;;)
        ;
}

/* The 512-byte block lives here rather than on the stack: the frame handlers
 * run from the main loop, and a half-kilobyte automatic would dwarf everything
 * else the PIC has on the stack. */
static uint8_t xfer_block[SD_BLOCK_SIZE];

static uint8_t sd_status_to_ioc(SdStatus st)
{
    switch (st) {
    case SD_OK:              return IOC_STATUS_OK;
    case SD_ERR_NO_CARD:     return IOC_STATUS_SD_NO_CARD;
    case SD_ERR_NO_RESPONSE: return IOC_STATUS_SD_NO_RESPONSE;
    case SD_ERR_UNUSABLE:    return IOC_STATUS_SD_UNUSABLE;
    case SD_ERR_NOT_READY:   return IOC_STATUS_SD_NOT_READY;
    case SD_ERR_READ:        return IOC_STATUS_SD_READ_FAIL;
    case SD_ERR_NO_TOKEN:    return IOC_STATUS_SD_NO_TOKEN;
    case SD_ERR_CRC:         return IOC_STATUS_SD_CRC;
    case SD_ERR_BUS:         return IOC_STATUS_SD_BUS;
    case SD_ERR_WRITE:       return IOC_STATUS_SD_WRITE_FAIL;
    case SD_ERR_WRITE_REJECTED: return IOC_STATUS_SD_WRITE_REJ;
    case SD_ERR_WRITE_BUSY:  return IOC_STATUS_SD_WRITE_BUSY;
    default:                 return IOC_STATUS_ERROR;
    }
}

/* Echo the LBA the MCU decoded, so the host can verify it before moving data.
 * See IOC_OFF_READY_LBA for why this exists. */
static void reply_echo_lba(IocFrame *reply, uint32_t lba)
{
    reply->bytes[IOC_OFF_READY_LBA + 0u] = (uint8_t)lba;
    reply->bytes[IOC_OFF_READY_LBA + 1u] = (uint8_t)(lba >> 8);
    reply->bytes[IOC_OFF_READY_LBA + 2u] = (uint8_t)(lba >> 16);
    reply->bytes[IOC_OFF_READY_LBA + 3u] = (uint8_t)(lba >> 24);
}

/* Read block 0 and hand back its first IOC_SD_READ_BYTES bytes.
 *
 * Blocking: the first call also initialises the card, which can take about a
 * second.  The host tolerates that easily -- its per-byte receive timeout is
 * several seconds -- but the main loop is stalled meanwhile, so the controller
 * latch counter pauses for the duration.
 */
void handler_sd_read(const IocFrame *request, IocFrame *reply)
{
    SdStatus st;

    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS] = RSP_SD_READ;
    reply->bytes[IOC_OFF_SEQ]   = request->bytes[IOC_OFF_SEQ];

    st = sd_card_read_block(0uL, xfer_block);
    reply->bytes[IOC_OFF_STATUS] = sd_status_to_ioc(st);

    if (st != SD_OK) {
        /* Hand back what the card actually said instead of nothing.  All FFh
         * means nothing drove DO at all; anything else means it is talking. */
        reply->bytes[IOC_OFF_LEN] = (uint8_t)SD_TRACE_BYTES;
        memcpy(&reply->bytes[IOC_OFF_PAYLOAD], sd_card_trace(), SD_TRACE_BYTES);
        return;
    }

    reply->bytes[IOC_OFF_LEN] = IOC_SD_READ_BYTES;
    memcpy(&reply->bytes[IOC_OFF_PAYLOAD], xfer_block, IOC_SD_READ_BYTES);
}

/* Channel-A bring-up: stream a known ramp so the bulk lane can be verified
 * independently of the SD card.  Reuses the transfer buffer; nothing else is
 * live at the same time because the foreground loop is single-threaded. */
void handler_bulk_test(const IocFrame *request, IocFrame *reply)
{
    uint16_t length;
    uint16_t i;

    length = (uint16_t)request->bytes[IOC_OFF_PAYLOAD] |
             ((uint16_t)request->bytes[IOC_OFF_PAYLOAD + 1u] << 8);
    if ((length == 0u) || (length > SD_BLOCK_SIZE))
        length = 256u;

    for (i = 0u; i < length; i++)
        xfer_block[i] = (uint8_t)i;

    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_BULK_TEST;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
    reply->bytes[IOC_OFF_LEN]    = IOC_READY_PAYLOAD_LEN;

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_MCU_TO_Z80;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)length;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = (uint8_t)(length >> 8);

    /* Staged, not sent: the bytes must not be clocked until this READY reply
     * has actually reached the host. */
    bulk_channel_arm(xfer_block, length,
                     reply->bytes[IOC_OFF_READY_XFER_ID],
                     RSP_BULK_TEST, request->bytes[IOC_OFF_SEQ],
                     IOC_STATUS_OK);
}

/* Read one sector and hand it to the bulk lane.
 *
 * Ordering matters: the card is read here, before the reply goes out, so the
 * READY the host receives is a genuine promise that 512 bytes are sitting in
 * SRAM ready to stream.  That keeps SD latency out of the SIO1/A transaction
 * and leaves room to double-buffer multi-sector reads later without changing
 * this API.
 */
void handler_sd_read_bulk(const IocFrame *request, IocFrame *reply)
{
    SdStatus st;
    uint32_t lba;
    uint8_t  ioc_status;

    lba =  (uint32_t)request->bytes[IOC_OFF_LBA_0]
        | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 1u] << 8)
        | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 2u] << 16)
        | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 3u] << 24);

    st = sd_card_read_block(lba, xfer_block);
    ioc_status = sd_status_to_ioc(st);

    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_SD_READ_BULK;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = ioc_status;
    reply->bytes[IOC_OFF_LEN]    = IOC_READY_PAYLOAD_LEN;

    if (st != SD_OK) {
        /* No transfer id, no length: the host must not enter its read loop. */
        return;
    }

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_MCU_TO_Z80;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)SD_BLOCK_SIZE;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = (uint8_t)(SD_BLOCK_SIZE >> 8);
    reply_echo_lba(reply, lba);

    bulk_channel_arm(xfer_block, SD_BLOCK_SIZE,
                     reply->bytes[IOC_OFF_READY_XFER_ID],
                     RSP_SD_READ_BULK, request->bytes[IOC_OFF_SEQ],
                     IOC_STATUS_OK);
}

/* LBA staged by handler_sd_write_bulk for the commit callback.  The bulk
 * receive runs after the reply has gone out, so the target block has to
 * survive from handler time to commit time. */
static uint32_t pending_write_lba;

/* Runs after the payload has been received and de-shifted.  This is the only
 * point at which the write is real, which is why the DONE query is mandatory
 * for a write: the bytes reaching the MCU says nothing about the card. */
static uint8_t commit_sd_write(void)
{
    return sd_status_to_ioc(sd_card_write_block(pending_write_lba, xfer_block));
}

/* Write one sector, payload arriving on the bulk lane.
 *
 * Mirror image of handler_sd_read_bulk, with the ordering necessarily
 * reversed.  A read touches the card BEFORE replying READY, so the READY is a
 * genuine promise that 512 bytes are ready to stream.  A write cannot: the
 * data does not exist yet at reply time, so READY only promises the MCU is
 * ready to RECEIVE, and the card is touched afterwards in commit_sd_write().
 *
 * That is why a write must always take the DONE round trip, and why the fast
 * path in the read program is documented as read-only.
 */
void handler_sd_write_bulk(const IocFrame *request, IocFrame *reply)
{
    pending_write_lba =  (uint32_t)request->bytes[IOC_OFF_LBA_0]
                      | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 1u] << 8)
                      | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 2u] << 16)
                      | ((uint32_t)request->bytes[IOC_OFF_LBA_0 + 3u] << 24);

    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_SD_WRITE_BULK;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
    reply->bytes[IOC_OFF_LEN]    = IOC_READY_PAYLOAD_LEN;

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_Z80_TO_MCU;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)SD_BLOCK_SIZE;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = (uint8_t)(SD_BLOCK_SIZE >> 8);
    reply_echo_lba(reply, pending_write_lba);

    bulk_channel_arm_receive(xfer_block, SD_BLOCK_SIZE,
                             reply->bytes[IOC_OFF_READY_XFER_ID],
                             CMD_SD_WRITE_BULK, request->bytes[IOC_OFF_SEQ],
                             commit_sd_write);
}

/* The DONE half of the lifecycle. */
void handler_xfer_status(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_XFER_STATUS;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
    reply->bytes[IOC_OFF_LEN]    = IOC_DONE_PAYLOAD_LEN;

    reply->bytes[IOC_OFF_DONE_XFER_ID] = bulk_channel_last_xfer_id();
    reply->bytes[IOC_OFF_DONE_STATUS]  = bulk_channel_last_status();

    /* Bring-up diagnostic: what the transfer buffer actually holds. */
    {
        uint8_t i;
        const uint8_t *raw = bulk_channel_rx_window();
        /* Peek the buffer the transfer was actually armed into, not a fixed
         * one -- record transfers do not use xfer_block. */
        const uint8_t *got = bulk_channel_rx_target();
        for (i = 0u; i < IOC_DONE_PEEK_BYTES; i++)
            reply->bytes[IOC_OFF_DONE_PEEK + i] = (got != 0) ? got[i] : 0u;
        /* Caller-selected slice of the raw window, so a failure can be walked
         * a byte at a time instead of guessed at from its first eight. */
        uint16_t off  = request->bytes[IOC_OFF_STATUS_RAW_OFF];
        uint16_t size = bulk_channel_rx_window_size();
        for (i = 0u; i < IOC_DONE_RAW_BYTES; i++) {
            uint16_t k = (uint16_t)(off + i);
            reply->bytes[IOC_OFF_DONE_RAW + i] = (k < size) ? raw[k] : 0u;
        }
    }
}

/* Link bring-up.  Releasing /SYNC and clearing the flag BEFORE the reply is
 * sent is the whole point: external_sync_send() samples it on entry, so this
 * reply is the one that carries a fresh falling /SYNC edge and re-establishes
 * the host's character boundary.  Idempotent, so it doubles as recovery. */
void handler_link_sync(const IocFrame *request, IocFrame *reply)
{
    /* BOTH lanes.  They are kept behaviourally identical apart from block size,
     * so a link bring-up re-establishes both character boundaries rather than
     * leaving the bulk lane in whatever state it happened to be in. */
    external_sync_request_resync();
    bulk_channel_request_resync();

    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_LINK_SYNC;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
}

void handler_unknown(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_UNKNOWN_COMMAND;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_UNKNOWN_CMD;
}

/* ---------------------------------------------------------------------------
 * Record-addressed access
 *
 * The CP/M BIOS storage driver talks in 128-byte records and never sees a
 * block.  Everything below is a thin shell over sd_cache: decode the record
 * number, hand off, report.  The deblocking, the LRU and the write policy all
 * live in sd_cache.c, which is where they can be reasoned about without a
 * frame layout in the way.
 * --------------------------------------------------------------------------- */

/* Staging buffer for one record.  Separate from xfer_block because the bulk
 * lane streams straight out of (or into) it while the cache slot it came from
 * stays intact -- copying is what keeps the cache from being aliased by a
 * transfer that might fail halfway. */
static uint8_t xfer_record[IOC_SD_RECORD_BYTES];

static uint32_t decode_record(const IocFrame *request)
{
    return  (uint32_t)request->bytes[IOC_OFF_RECORD_0]
         | ((uint32_t)request->bytes[IOC_OFF_RECORD_0 + 1u] << 8)
         | ((uint32_t)request->bytes[IOC_OFF_RECORD_0 + 2u] << 16)
         | ((uint32_t)request->bytes[IOC_OFF_RECORD_0 + 3u] << 24);
}

static void reply_header(const IocFrame *request, IocFrame *reply,
                         uint8_t cls, uint8_t status, uint8_t len)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = cls;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = status;
    reply->bytes[IOC_OFF_LEN]    = len;
}

/* Read one record.  The cache is consulted BEFORE the reply goes out, so a
 * READY here is the same genuine promise the block read makes: the bytes are
 * already in SRAM and the bulk phase cannot fail for want of the card. */
void handler_sd_read_rec(const IocFrame *request, IocFrame *reply)
{
    uint32_t record = decode_record(request);

    rec_reads++;
    SdStatus st     = sd_cache_read_record(record, xfer_record);

    reply_header(request, reply, RSP_SD_READ_REC,
                 sd_status_to_ioc(st), IOC_READY_PAYLOAD_LEN);

    if (st != SD_OK)
        return;                 /* no id, no length: host must not read */

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_MCU_TO_Z80;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)IOC_SD_RECORD_BYTES;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = 0u;
    reply_echo_lba(reply, record);

    bulk_channel_arm(xfer_record, IOC_SD_RECORD_BYTES,
                     reply->bytes[IOC_OFF_READY_XFER_ID],
                     RSP_SD_READ_REC, request->bytes[IOC_OFF_SEQ],
                     IOC_STATUS_OK);
}

static uint32_t pending_write_record;

/* Runs once the record has arrived and been de-shifted.
 *
 * Unlike the block write path this usually does NOT touch the card: the record
 * lands in a cache slot and is committed by the flush timer.  The exception is
 * the write-through block, where this returns the card's own status.  Either
 * way the DONE query stays mandatory -- it is the only thing that reports a
 * bulk CRC failure, and a deferred write can still fail here by being unable to
 * read the containing block. */
static uint8_t commit_sd_write_record(void)
{
    return sd_status_to_ioc(sd_cache_write_record(pending_write_record,
                                                  xfer_record));
}

void handler_sd_write_rec(const IocFrame *request, IocFrame *reply)
{
    pending_write_record = decode_record(request);

    reply_header(request, reply, RSP_SD_WRITE_REC,
                 IOC_STATUS_OK, IOC_READY_PAYLOAD_LEN);

    reply->bytes[IOC_OFF_READY_XFER_ID]   = bulk_channel_next_xfer_id();
    reply->bytes[IOC_OFF_READY_DIRECTION] = BULK_DIR_Z80_TO_MCU;
    reply->bytes[IOC_OFF_READY_LEN_LO]    = (uint8_t)IOC_SD_RECORD_BYTES;
    reply->bytes[IOC_OFF_READY_LEN_HI]    = 0u;
    reply_echo_lba(reply, pending_write_record);

    bulk_channel_arm_receive(xfer_record, IOC_SD_RECORD_BYTES,
                             reply->bytes[IOC_OFF_READY_XFER_ID],
                             CMD_SD_WRITE_REC, request->bytes[IOC_OFF_SEQ],
                             commit_sd_write_record);
}

/* Commit everything now.  No bulk phase: the status in the reply IS the answer,
 * so this is the one storage command a host can trust without a DONE query.
 *
 * Blocking for as long as the dirty slots take -- up to four card writes, and
 * an SD card is entitled to a couple of hundred milliseconds each on an
 * erase-block boundary.  That is the point: a host calling this wants the
 * card consistent before it does whatever comes next. */
void handler_sd_flush(const IocFrame *request, IocFrame *reply)
{
    SdStatus st = sd_cache_flush();

    reply_header(request, reply, RSP_SD_FLUSH, sd_status_to_ioc(st), 0u);
}

/* Accumulated microsecond profile.  Page 0 returns the original six 16-bit
 * millisecond totals; page 1 returns four bulk-TX subphase totals.
 *
 * A separate command rather than more PING fields: PING's payload bytes 4-19
 * carry a test pattern the host echoes back and verifies, and overwriting them
 * would trade an integrity check for a diagnostic. */
void handler_profile(const IocFrame *request, IocFrame *reply)
{
    uint8_t i;
    uint8_t page = IOC_PROFILE_PAGE_SUMMARY;

    if ((request->bytes[IOC_OFF_LEN] >= 1u) &&
        (request->bytes[IOC_OFF_PROFILE_CONTROL] == IOC_PROFILE_RESET))
        uprof_request_reset();

    if (request->bytes[IOC_OFF_LEN] >= 2u)
        page = request->bytes[IOC_OFF_PROFILE_PAGE];

    if (page == IOC_PROFILE_PAGE_BULK_TX) {
        reply_header(request, reply, RSP_PROFILE, IOC_STATUS_OK,
                     IOC_PROFILE_BULK_TX_LEN);

        for (i = 0u; i < 4u; i++) {
            uint16_t ms = uprof_ms((uint8_t)(UPROF_BULK_WAIT + i));
            reply->bytes[IOC_OFF_PROFILE_0 + (uint8_t)(i * 2u)] =
                (uint8_t)ms;
            reply->bytes[IOC_OFF_PROFILE_0 + (uint8_t)(i * 2u) + 1u] =
                (uint8_t)(ms >> 8);
        }
        return;
    }

    reply_header(request, reply, RSP_PROFILE, IOC_STATUS_OK,
                 IOC_PROFILE_PAYLOAD_LEN);

    {
        extern uint16_t svc_calls, svc_aborts;
        reply->bytes[IOC_OFF_PROFILE_CALLS]      = (uint8_t)svc_calls;
        reply->bytes[IOC_OFF_PROFILE_CALLS + 1u] = (uint8_t)(svc_calls >> 8);
        reply->bytes[IOC_OFF_PROFILE_ABORTS]      = (uint8_t)svc_aborts;
        reply->bytes[IOC_OFF_PROFILE_ABORTS + 1u] = (uint8_t)(svc_aborts >> 8);
    }

    {
        const uint8_t *tr = sd_card_trace();
        uint8_t j;
        for (j = 0u; j < SD_TRACE_BYTES; j++)
            reply->bytes[IOC_OFF_PROFILE_SDTRACE + j] = tr[j];
    }

    for (i = 0u; i < UPROF_PUBLIC_SLOTS; i++) {
        uint16_t ms = uprof_ms(i);
        reply->bytes[IOC_OFF_PROFILE_0 + (uint8_t)(i * 2u)]      = (uint8_t)ms;
        reply->bytes[IOC_OFF_PROFILE_0 + (uint8_t)(i * 2u) + 1u] = (uint8_t)(ms >> 8);
    }
}
