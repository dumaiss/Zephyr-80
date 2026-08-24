#include <xc.h>
#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "ioc_frame.h"
#include "external_sync.h"
#include "dispatch.h"
#include "spi1_bus.h"
#include "controller_latch.h"
#include "bulk_channel.h"
#include "sd_card.h"

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

    /* SD activity indicator: parked off until a card access starts. */
    SD_BUSY_ANSEL = 0;
    SD_BUSY_LAT   = SD_BUSY_IDLE;
    SD_BUSY_TRIS  = 0;

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
 * /SIO1B_INT is an ACKNOWLEDGED REQUEST line, not a transaction-active line:
 *
 *     low   = the host has a request outstanding
 *     high  = the request has been accepted
 *
 * The host drops it as soon as it has finished transmitting its frame -- long
 * before the reply -- and the PIC observes that release as a required step of
 * servicing, below.  Because the PIC is already committed to the service when
 * it looks, it cannot miss it.
 *
 * Detection is therefore a plain level test.  No edge is involved anywhere, and
 * that is deliberate: the PIC samples this line only in its main loop and is
 * blind for the length of a bulk transfer or a card write -- hundreds of
 * milliseconds.  Anything encoded in an edge during that window is lost with no
 * trace, because the line is already low and will never fall again.
 *
 * Two earlier schemes both failed on exactly that:
 *
 *   - Sampled edge (remember the previous level, look for high-to-low).  Only
 *     works if the PIC happens to sample inside the gap between one request's
 *     release and the next one's assertion.  A host issuing back-to-back
 *     commands re-asserts within microseconds, so the request was simply lost
 *     until the host's ~11 s timeout.
 *
 *   - Level plus a wait-for-release AFTER servicing.  Fails the other way.
 *     During a write the host releases, transmits the bulk payload, waits for
 *     /CTSA and re-asserts for its DONE query -- all while the PIC is still
 *     inside the bulk receive and the card write.  By the time the PIC waited,
 *     the release had already happened and would not repeat.  A short bound
 *     meant it gave up and re-serviced the same low level, clocking junk
 *     windows into a listening host; a long bound meant a ~10 s deadlock.
 *
 * Requiring the release mid-service removes the ambiguity instead of trying to
 * out-sample it.  Having seen this request acknowledged, any low level found
 * while idle must belong to a later one.
 *
 * The bound below only has to cover the host finishing its frame.  The host
 * sends 35 bytes into a 48-byte window, so it has normally released before
 * external_sync_receive() even returns and this costs nothing.  A timeout here
 * is a real fault and is reported by declining to reply, which the host sees as
 * a clean receive timeout rather than as framing garbage.
 */
#define REQUEST_RELEASE_TIMEOUT_LOOPS  20000u

/* ---------------------------------------------------------------------------
 * COMMAND_READY on /DCDB
 * ---------------------------------------------------------------------------
 *
 * /DCDB is a PIC output into the host's SIO1/B, readable by the host as RR0
 * bit 3.  It carries a persistent level, not a pulse:
 *
 *     asserted     the PIC is in command-idle and will accept a request
 *     deasserted   the PIC will not accept a new command
 *
 * The contract is "READY means the host may make exactly one request", which is
 * what the architecture actually supports: one SPI engine, no concurrent lanes,
 * one transaction in flight.  The host must not assert RTS unless READY.
 *
 * This is backpressure and diagnosability, NOT the fix for the request race --
 * that is the acknowledged-request handshake (see command_request_started()).
 * What it adds is that a host talking to a busy controller can tell, rather
 * than discovering it after an 11 s timeout, and a host talking to a DEAD
 * controller finds out immediately instead of looking identical to a busy one.
 *
 * READY is asserted only after the request has been acknowledged AND all work
 * it triggered has finished -- including the bulk phase and any card write.
 * Asserting earlier would invite a request the PIC cannot yet service.
 *
 * DO NOT ENABLE AUTO ENABLES ON CHANNEL B.  With WR3 bit 5 clear, as it is
 * today, /DCDB is a pure status bit with no side effects.  Set that bit and
 * /DCDB starts gating the host's RECEIVER, so deasserting it mid-transaction
 * would silently kill reception.  /DCDA on the bulk lane does exactly that, on
 * purpose -- the asymmetry between the two channels is deliberate and is a trap
 * for anyone who assumes they are configured alike.
 */
static void command_ready_set(bool ready)
{
    DCDB_LAT = ready ? DCDB_ASSERTED : DCDB_IDLE;
}

static bool command_request_started(void)
{
    return SIO1B_INT_PORT == SIO1B_INT_ACTIVE;
}

static bool wait_request_release(void)
{
    uint16_t guard;

    for (guard = 0u; guard < REQUEST_RELEASE_TIMEOUT_LOOPS; guard++) {
        if (SIO1B_INT_PORT != SIO1B_INT_ACTIVE)
            return true;
    }

    return false;
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
    bool     have_request;

    have_request = external_sync_receive(&request);

    /* Acknowledge before replying, whether or not the frame decoded.
     *
     * Doing it on the failure path too is what stops a single missed frame
     * from cascading: the host is left waiting for a reply that will not come,
     * but its RTS is already high, so the PIC cannot mistake that wait for a
     * fresh request and clock junk windows into a receiver that is listening
     * for a preamble. */
    if (!wait_request_release())
        return;

    if (!have_request)
        return;

    if (dispatch_command(&request, &reply)) {
        external_sync_send(&reply);

        /* READY -> BULK.  A handler may have staged a bulk transfer; it runs
         * only now, because the bytes must not be clocked onto SIO1/A until
         * the READY reply has actually reached the host.
         *
         * The old PING diagnostic that wrote payload bytes to the controller
         * latch lived here.  It is gone: the latch now shows the 500 ms
         * bring-up counter, and the two fight over the same two devices. */
        (void)bulk_channel_run_if_armed();
    }
}

int main(void)
{
    platform_init();
    boot_reset_pulse();

#if SD_CMD0_LOOP
    sd_card_cmd0_loop();   /* does not return */
#endif

    /* Advertise readiness only once everything is initialised.  Before this
     * the pin sits at its parked idle level, so a host that boots first
     * correctly sees "not ready" rather than talking to a half-configured
     * controller. */
    command_ready_set(true);

    for (;;) {
        if (command_request_started()) {
            command_ready_set(false);   /* accepting: no further requests */
            service_command_request();
            command_ready_set(true);    /* all work done, including bulk/SD */
        }

        /* Non-blocking: returns immediately unless the 500 ms period elapsed. */
        controller_latch_tick();

        NOP();
    }
}
