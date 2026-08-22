#include <xc.h>
#include <string.h>
#include "handlers.h"
#include "ioc_frame.h"
#include "config.h"
#include "sd_card.h"

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
static uint8_t sd_block[SD_BLOCK_SIZE];

static uint8_t sd_status_to_ioc(SdStatus st)
{
    switch (st) {
    case SD_OK:              return IOC_STATUS_OK;
    case SD_ERR_NO_RESPONSE: return IOC_STATUS_SD_NO_RESPONSE;
    case SD_ERR_UNUSABLE:    return IOC_STATUS_SD_UNUSABLE;
    case SD_ERR_NOT_READY:   return IOC_STATUS_SD_NOT_READY;
    case SD_ERR_READ:        return IOC_STATUS_SD_READ_FAIL;
    case SD_ERR_BUS:         return IOC_STATUS_SD_BUS;
    default:                 return IOC_STATUS_ERROR;
    }
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

    st = sd_card_read_block(0uL, sd_block);
    reply->bytes[IOC_OFF_STATUS] = sd_status_to_ioc(st);

    if (st != SD_OK) {
        /* Length stays zero so the host does not read stale payload bytes. */
        return;
    }

    reply->bytes[IOC_OFF_LEN] = IOC_SD_READ_BYTES;
    memcpy(&reply->bytes[IOC_OFF_PAYLOAD], sd_block, IOC_SD_READ_BYTES);
}

void handler_unknown(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_UNKNOWN_COMMAND;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_UNKNOWN_CMD;
}
