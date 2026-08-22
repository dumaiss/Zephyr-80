#include <xc.h>
#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "ioc_frame.h"
#include "external_sync.h"
#include "dispatch.h"
#include "spi1_bus.h"
#include "controller_latch.h"

/* ---------------------------------------------------------------------------
 * Platform initialization
 * ---------------------------------------------------------------------------
 *
 * The firmware runs as a foreground polling loop.  Interrupts stay disabled:
 * the Z80 requests service by asserting /SIO1B_INT low, and the PIC services
 * exactly one command transaction on that falling edge.
 */
static void platform_init(void)
{
    INTCON0bits.GIE = 0;

    /* 64 MHz HFINTOSC. */
    OSCCON1 = 0x60;
    OSCFRQ  = 0x08;
    OSCTUNE = 0x00;

    /* Every pin in the map is digital. */
    ANSELA = 0x00;
    ANSELB = 0x00;
    ANSELD = 0x00;
    ANSELE = 0x00;
    ANSELF = 0x00;
    ODCONA = 0x00;
    WPUA   = 0x00;

    /* Inactive shared-bus selects stay idle while the command link clocks. */
    IO_USB_CS_LAT  = IO_USB_CS_IDLE;
    IO_USB_CS_TRIS = 0;

    IO_SD_CS_LAT  = IO_SD_CS_IDLE;
    IO_SD_CS_TRIS = 0;

    SIOA_CS_LAT  = SIOA_CS_IDLE;
    SIOA_CS_TRIS = 0;

    CTRL_LAT_CS_LAT  = CTRL_LAT_CS_IDLE;
    CTRL_LAT_CS_TRIS = 0;

    /* SIO1/A External Sync is wired but unused; park it deasserted. */
    SYNCA_LAT  = SYNCA_IDLE;
    SYNCA_TRIS = 0;

    /* SIO1 modem control: the PIC drives all four, parked deasserted. */
    CTSA_LAT  = CTSA_IDLE;
    CTSA_TRIS = 0;
    CTSB_LAT  = CTSB_IDLE;
    CTSB_TRIS = 0;
    DCDA_LAT  = DCDA_IDLE;
    DCDA_TRIS = 0;
    DCDB_LAT  = DCDB_IDLE;
    DCDB_TRIS = 0;

    /* /NMI is an output and must be idle before anything else runs. */
    HOST_NMI_LAT  = HOST_NMI_IDLE;
    HOST_NMI_TRIS = 0;

    /* Power management stays floating: the PMU side is not finished, and
     * driving RF6 at all stops the machine from starting.  TRIS only — do not
     * write LATF6 here. */
    PWR_OFF_TRIS     = 1;
    SHUTDOWN_RQ_TRIS = 1;

    USB_INT_TRIS     = 1;
    NMI_RQ_TRIS      = 1;

    SIO1B_INT_TRIS = 1;
    SIO1A_INT_TRIS = 1;

    /* GPIO header: inputs until something claims it. */
    IOC_GPIO_TRIS = 0xFF;

    external_sync_init();

    /* Port C peripheral bus.  Claims RC3/RC4/RC5 and enables SPI1; each device
     * on that bus sets its own clock rate before a transaction.  Nothing uses
     * it yet -- this step exists to prove it does not disturb the SIO link. */
    spi1_bus_init();

    /* Controller latch: 500 ms bring-up counter on the same port C bus.  The
     * SD card is not touched here -- it initialises lazily on the first
     * SD_READ, so a missing card costs nothing at boot. */
    controller_latch_init();
}

/* ---------------------------------------------------------------------------
 * Host reset pair
 * ---------------------------------------------------------------------------
 *
 * RF2 RESET is active-low.  RF3 RESET_HIGH is the complementary active-high
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
 * /SIO1B_INT is level-low for the whole IOCALL transaction.  The PIC services
 * only the high-to-low edge; a level-triggered loop would repeatedly clock idle
 * windows while the host still holds the line asserted.
 */
static uint8_t sio1b_int_prev_level = 1u;

static bool command_request_started(void)
{
    uint8_t now = SIO1B_INT_PORT;
    bool falling = (sio1b_int_prev_level != SIO1B_INT_ACTIVE) &&
                   (now == SIO1B_INT_ACTIVE);

    sio1b_int_prev_level = now;
    return falling;
}

/* ---------------------------------------------------------------------------
 * Command transaction
 * ---------------------------------------------------------------------------
 *
 *   Z80 BIOS                            PIC firmware
 *   --------                            ------------
 *   assert /SIO1B_INT low  -----------> edge detected
 *                                       select SIO1/B on the shared bus
 *                                       clock request from SIO TXDB
 *                                       dispatch command frame
 *                                       clock reply to SIO RXDB
 *   deassert /SIO1B_INT after reply
 *
 * CMD_RESET is terminal: its handler asserts the reset pair and resets the PIC.
 */
static void service_command_request(void)
{
    IocFrame request;
    IocFrame reply;

    if (!external_sync_receive(&request))
        return;

    if (dispatch_command(&request, &reply)) {
        external_sync_send(&reply);

        /* Bring-up diagnostic: expose the first two echoed PING payload bytes
         * through the cascaded controller latches after the reply completes. */
        if (request.bytes[IOC_OFF_CLASS] == CMD_PING) {
            controller_latch_write(
                request.bytes[IOC_OFF_PAYLOAD],
                request.bytes[IOC_OFF_PAYLOAD + 1u]);
        }
    }
}

int main(void)
{
    platform_init();
    boot_reset_pulse();

    for (;;) {
        if (command_request_started())
            service_command_request();

        /* Non-blocking: returns immediately unless the 500 ms period elapsed. */
        controller_latch_tick();

        NOP();
    }
}
