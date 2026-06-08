#include <xc.h>
#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "ioc_frame.h"
#include "sdlc.h"
#include "dispatch.h"
#include "trace.h"

volatile uint8_t boot_pcon0;

/* ---------------------------------------------------------------------------
 * Platform init — clocks, analog/digital, pin directions, SPI CS idle state
 * ---------------------------------------------------------------------------*/
static void platform_init(void)
{
    INTCON0bits.GIE = 0;

    /* 64 MHz HFINTOSC */
    OSCCON1 = 0x60;
    OSCFRQ  = 0x08;
    OSCTUNE = 0x00;

    /* All IO ports on Port A and relevant Port F pins digital */
    ANSELB = 0x00;   /* RB2/RB5 host reset outputs */
    ANSELA = 0x00;   /* RA0-RA7 SPI bus and CS pins */
    ODCONA = 0x00;   /* Port A push-pull outputs */
    WPUA   = 0x00;   /* no weak pull-ups on shared SPI/CS pins */
    ANSELFbits.ANSELF1 = 0;   /* RF1 SIO_CMD_RTS input */
    ANSELFbits.ANSELF2 = 0;   /* RF2 SIO_BULK_RTS input */

    /* -----------------------------------------------------------------------
     * Port A direction and initial CS states
     * All CS/select lines must be deasserted (idle) BEFORE SPI is initialized
     * so that no SIO or peripheral sees spurious clock edges.
     * ----------------------------------------------------------------------- */
    /* RA0 BULK_CS  — output, idle (deasserted) */
    BULK_CS_LAT  = BULK_CS_IDLE;
    BULK_CS_TRIS = 0;

    /* RA1/CMD_CS is a single MCU-OWNED net doing two jobs:
     *   1. 74HC125 /OE that gates the SIO TxD -> MCU MISO buffer (active low).
     *   2. Z80 SIO1/B /SYNCB, used as an INPUT in External Sync mode.
     * The MCU must drive it: low = MISO buffer enabled + SIO externally synced
     * for the whole transaction; high = idle/deselected.  This requires the SIO
     * to run in External Sync mode (SYNC = input), NOT SDLC/Monosync/Bisync
     * (which drive SYNC as an output and would contend with this net). */
    CMD_CS_LAT  = CMD_CS_IDLE;
    CMD_CS_TRIS = 0;

    /* RA2 USB_INT — input (bridge data-ready signal, unused this phase) */
    USB_INT_TRIS = 1;

    /* RA3 USB_BRIDGE_CS — output, idle */
    USB_BRIDGE_CS_LAT  = USB_BRIDGE_CS_IDLE;
    USB_BRIDGE_CS_TRIS = 0;

    /* RA4 SD_CS — output, idle */
    SD_CS_LAT  = SD_CS_IDLE;
    SD_CS_TRIS = 0;

    /* RA5 SPI_MOSI — output (driven by SPI peripheral after PPS) */
    SPI_MOSI_LAT  = 1;   /* idle high before SPI takes over */
    SPI_MOSI_TRIS = 0;

    /* RA6 SPI_MISO — input */
    SPI_MISO_TRIS = 1;

    /* RA7 SPI_CLK — output (driven by SPI peripheral after PPS) */
    SPI_CLK_LAT  = 0;   /* idle low (CKP=0) before SPI takes over */
    SPI_CLK_TRIS = 0;

    /* -----------------------------------------------------------------------
     * Port B: host reset pair
     * ----------------------------------------------------------------------- */
    HOST_RESET_ANSEL      = 0;
    HOST_RESET_HIGH_ANSEL = 0;

    /* -----------------------------------------------------------------------
     * Port F: Z80 RTS inputs
     * ----------------------------------------------------------------------- */
    SIO_CMD_RTS_TRIS  = 1;   /* RF1 input — Command channel RTS from Z80 */
    SIO_BULK_RTS_TRIS = 1;   /* RF2 input — Bulk channel RTS from Z80 */
}

/* ---------------------------------------------------------------------------
 * Startup host reset pulse — unchanged from original skeleton
 * ---------------------------------------------------------------------------*/
static void write_reset(uint8_t asserted)
{
    HOST_RESET_LAT      = asserted ? HOST_RESET_ASSERTED : HOST_RESET_IDLE;
    HOST_RESET_HIGH_LAT = asserted ? HOST_RESET_HIGH_ASSERTED : HOST_RESET_HIGH_IDLE;
}

static void boot_reset_pulse(void)
{
    write_reset(1);
    HOST_RESET_TRIS      = 0;
    HOST_RESET_HIGH_TRIS = 0;
    __delay_ms(100);
    write_reset(0);
}

/* ---------------------------------------------------------------------------
 * Command channel polling
 *
 * Z80 SIO1/B asserts RTS (RF1 goes low) when a Command-channel transaction
 * is requested.  Phase 1 uses foreground polling; no interrupt-on-change
 * required.  GIE remains 0.
 * ---------------------------------------------------------------------------*/
static uint8_t rts_prev_level = 1u;   /* RF1 idle high */

static bool command_request_active(void)
{
    uint8_t now = SIO_CMD_RTS_PORT;
    dbg_rts_sample = now;

    /* Edge-triggered: service exactly once per RF1 high->low transition.
     * The Z80 holds RTS low for the whole IOCALL and transmits its frame once,
     * early.  Level-triggering re-clocked many windows per transaction, so the
     * captured window was usually a later idle one that missed the frame.
     * One window per falling edge stays aligned with the Z80's transmit (the
     * two self-synchronize via the SIO TBE flag and the MCU clock). */
    bool falling = (rts_prev_level != SIO_CMD_RTS_ACTIVE) &&
                   (now == SIO_CMD_RTS_ACTIVE);
    rts_prev_level = now;

    if (falling) {
        dbg_rts_seen_count++;
        TRACE(TRACE_RTS_POLL_LOW, now, 0, 0);
        return true;
    }
    return false;
}

/* ---------------------------------------------------------------------------
 * Command request service
 *
 * Configure SPI for Command channel, receive one SDLC frame, dispatch it,
 * and send the reply (if any).
 * ---------------------------------------------------------------------------*/
static void kernel_service_command_request(void)
{
    IocFrame request;
    IocFrame reply;
    bool     has_reply;

    TRACE(TRACE_COMMAND_SERVICE_ENTER, dbg_rts_sample, 0, 0);

    sdlc_command_config_250khz();

    if (!sdlc_recv_frame(IO_CH_COMMAND, &request, SDLC_RX_WINDOW_BYTES)) {
        TRACE(TRACE_SDLC_RX_TIMEOUT, dbg_last_sdlc_error, 0, 0);
        return;
    }

    dbg_last_cmd = request.bytes[IOC_OFF_CLASS];
    dbg_last_seq = request.bytes[IOC_OFF_SEQ];

    TRACE(TRACE_SDLC_RX_GOT_FRAME,
          request.bytes[IOC_OFF_CLASS],
          request.bytes[IOC_OFF_SEQ],
          0);

    has_reply = dispatch_command(&request, &reply);

    if (has_reply) {
        if (sdlc_send_frame(IO_CH_COMMAND, &reply)) {
            TRACE(TRACE_PING_REPLY_SENT,
                  reply.bytes[IOC_OFF_CLASS],
                  reply.bytes[IOC_OFF_SEQ],
                  0);
        } else {
            TRACE(TRACE_SDLC_TX_ERROR, 0, 0, 0);
        }
    }
}

/* ---------------------------------------------------------------------------
 * Main
 * ---------------------------------------------------------------------------*/
int main(void)
{
    boot_pcon0 = PCON0;

    platform_init();
    boot_reset_pulse();

    /* Initialize SPI1 and PPS routing for Command channel.
     * All CS lines were deasserted in platform_init(); sdlc_spi_init()
     * deasserts them again as a belt-and-suspenders measure. */
    sdlc_spi_init();

    TRACE(TRACE_BOOT_MAIN_LOOP, 0, 0, 0);

    for (;;) {
        dbg_main_loop_count++;
        if (command_request_active()) {
            kernel_service_command_request();
        }

        NOP();
    }
}
