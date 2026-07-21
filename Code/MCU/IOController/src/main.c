#include <xc.h>
#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "ioc_frame.h"
#include "external_sync.h"
#include "dispatch.h"

/* ---------------------------------------------------------------------------
 * Platform initialization
 * ---------------------------------------------------------------------------
 *
 * The firmware runs as a foreground polling loop.  Interrupts stay disabled:
 * the Z80 requests service by asserting SIO1/B RTSB low, and the PIC services
 * exactly one command transaction on that falling edge.
 */
static void platform_init(void)
{
    INTCON0bits.GIE = 0;

    /* 64 MHz HFINTOSC. */
    OSCCON1 = 0x60;
    OSCFRQ  = 0x08;
    OSCTUNE = 0x00;

    ANSELA = 0x00;
    ANSELB = 0x00;
    ODCONA = 0x00;
    WPUA   = 0x00;

    /* Inactive Port A selects stay idle-high while the command link clocks. */
    UNUSED_RA0_LAT  = UNUSED_RA0_IDLE;
    UNUSED_RA0_TRIS = 0;

    USB_BRIDGE_CS_LAT  = USB_BRIDGE_CS_IDLE;
    USB_BRIDGE_CS_TRIS = 0;

    SD_CS_LAT  = SD_CS_IDLE;
    SD_CS_TRIS = 0;

    USB_INT_TRIS = 1;

    HOST_RESET_ANSEL      = 0;
    HOST_RESET_HIGH_ANSEL = 0;

    SIO_CMD_RTS_ANSEL = 0;
    SIO_CMD_RTS_TRIS  = 1;

    external_sync_init();
}

/* ---------------------------------------------------------------------------
 * Host reset pair
 * ---------------------------------------------------------------------------
 *
 * RB2 RESET is active-low.  RB5 RESET_HIGH is the complementary active-high
 * reset signal.  Both are driven during boot and during CMD_RESET.
 */
static void write_reset(uint8_t asserted)
{
    HOST_RESET_LAT      = asserted ? HOST_RESET_ASSERTED : HOST_RESET_IDLE;
    HOST_RESET_HIGH_LAT = asserted ? HOST_RESET_HIGH_ASSERTED : HOST_RESET_HIGH_IDLE;
}

static void boot_reset_pulse(void)
{
    write_reset(1u);
    HOST_RESET_TRIS      = 0;
    HOST_RESET_HIGH_TRIS = 0;

    __delay_ms(100);
    write_reset(0u);
}

/* ---------------------------------------------------------------------------
 * Command request detection
 * ---------------------------------------------------------------------------
 *
 * RTSB is level-low for the whole IOCALL transaction.  The PIC services only
 * the high-to-low edge; a level-triggered loop would repeatedly clock idle
 * windows while the host still holds RTSB asserted.
 */
static uint8_t rts_prev_level = 1u;

static bool command_request_started(void)
{
    uint8_t now = SIO_CMD_RTS_PORT;
    bool falling = (rts_prev_level != SIO_CMD_RTS_ACTIVE) &&
                   (now == SIO_CMD_RTS_ACTIVE);

    rts_prev_level = now;
    return falling;
}

/* ---------------------------------------------------------------------------
 * Command transaction
 * ---------------------------------------------------------------------------
 *
 *   Z80 BIOS                         PIC firmware
 *   --------                         ------------
 *   assert RTSB low  --------------> edge detected
 *                                    clock request from SIO TXDB
 *                                    dispatch command frame
 *                                    clock reply to SIO RXDB
 *   deassert RTSB after reply
 *
 * CMD_RESET is terminal: its handler asserts the reset pair and resets the PIC.
 */
static void service_command_request(void)
{
    IocFrame request;
    IocFrame reply;

    if (!external_sync_receive(&request))
        return;

    if (dispatch_command(&request, &reply))
        external_sync_send(&reply);
}

int main(void)
{
    platform_init();
    boot_reset_pulse();

    for (;;) {
        if (command_request_started())
            service_command_request();

        NOP();
    }
}
