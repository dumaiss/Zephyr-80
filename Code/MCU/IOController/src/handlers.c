#include <xc.h>
#include <string.h>
#include "handlers.h"
#include "ioc_frame.h"
#include "config.h"

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

void handler_unknown(const IocFrame *request, IocFrame *reply)
{
    memset(reply->bytes, 0, IOC_FRAME_SIZE);
    reply->bytes[IOC_OFF_CLASS]  = RSP_UNKNOWN_COMMAND;
    reply->bytes[IOC_OFF_SEQ]    = request->bytes[IOC_OFF_SEQ];
    reply->bytes[IOC_OFF_STATUS] = IOC_STATUS_UNKNOWN_CMD;
}
