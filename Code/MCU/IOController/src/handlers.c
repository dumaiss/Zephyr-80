#include <xc.h>
#include <string.h>
#include "handlers.h"
#include "ioc_frame.h"
#include "config.h"
#include "sd_card.h"
#include "bulk_channel.h"

void handler_ping(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_PING;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_OK;
    reply->bytes[IOC_OFF_LEN]    = request->bytes[IOC_OFF_LEN];
    /* Echo test pattern from payload bytes 4-19 */
    memcpy(&reply->bytes[IOC_OFF_PAYLOAD],
           &request->bytes[IOC_OFF_PAYLOAD],
           16u);
    /* Bytes 20-31: reserved, already zero from memset */
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
                     reply->bytes[IOC_OFF_READY_XFER_ID]);
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
                     reply->bytes[IOC_OFF_READY_XFER_ID]);
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
        for (i = 0u; i < IOC_DONE_PEEK_BYTES; i++)
            reply->bytes[IOC_OFF_DONE_PEEK + i] = xfer_block[i];
        for (i = 0u; i < IOC_DONE_RAW_BYTES; i++)
            reply->bytes[IOC_OFF_DONE_RAW + i] = raw[i];
    }
}

void handler_unknown(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_UNKNOWN_COMMAND;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_UNKNOWN_CMD;
}
