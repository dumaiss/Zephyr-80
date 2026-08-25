#include <xc.h>

#include "config.h"
#include "power.h"
#include "timebase.h"

/* PPS input encoding: PORT in bits 5:3, PIN in bits 2:0.
 *
 * Two independent sources agree, neither of them the Q84 datasheet:
 *
 *   - the Q84 device header gives the FIELD LAYOUT directly:
 *     _INT2PPS_PORT_MASK = 0x38 (bits 5:3), _INT2PPS_PIN_MASK = 0x07;
 *   - the K42 datasheet (DS40001919G, Register 17-1) gives the CODES for that
 *     same layout: 101 = PORTF, 111 = pin 7.
 *
 * So RF7 is 0b101_111 = 0x2F.
 *
 * INT0 and INT1 cannot be used here whatever the code: their port fields are
 * two bits wide (_INT0PPS_PORT_MASK = 0x18) and cannot leave ports A-D.  INT2
 * is one of the few inputs with a three-bit port field.
 */
#define INT2PPS_RF7     (uint8_t)((5u << 3) | 7u)   /* RF7 = 0x2F */

/* How long /SHUTDOWN_RQ must stay asserted before it is believed.
 *
 * Cheap insurance rather than a fix for anything known: the request is a
 * deliberate human action and the PMU holds the line until the rails drop, so
 * nothing legitimate is anywhere near this short.  The flush that follows takes
 * far longer than the wait. */
#define SHUTDOWN_DEBOUNCE_TICKS  (50u / TIMEBASE_TICK_MS)

static bool     pending;
static uint16_t pending_since;

void power_init(void)
{
    /* Input, analog off, and hold it at the deasserted level ourselves.
     *
     * The pull-up is the whole reason both signals are active low.  With it,
     * an unpowered or high-Z PMU reads as "nothing requested" instead of
     * floating, so the controller cannot be talked into shutting down by a
     * disconnected wire.  Neither MCU has programmable pull-downs, so this only
     * works in this polarity. */
    SHUTDOWN_RQ_ANSEL = 0;
    SHUTDOWN_RQ_TRIS  = 1;
    SHUTDOWN_RQ_WPU   = 1;

    /* Latch the request edge in hardware.  Falling, because the signal is
     * active low.
     *
     * Port F has no interrupt-on-change -- IOC exists on ports A, B, C and E
     * only -- and the main loop can be blind for a couple of hundred
     * milliseconds inside an SD write, so a short request would otherwise be
     * missed entirely.
     *
     * INT2IE stays clear.  Only the flag is used, as a latch that software
     * polls.  This firmware bit-bangs both SIO lanes with cycle-level timing
     * and has no ISRs at all; taking one here would corrupt a transfer in
     * flight.  The flag sets on the edge whether or not the interrupt is
     * enabled, which is exactly the behaviour wanted. */
    INT2PPS = INT2PPS_RF7;
    INTCON0bits.INT2EDG = 0;      /* falling edge */
    PIR10bits.INT2IF = 0;
    PIE10bits.INT2IE = 0;         /* explicitly NOT enabled */

    pending = false;

    /* /PWR_OFF is already driven idle -- platform_init() does it in its first
     * few instructions, because every millisecond before that is a millisecond
     * the PMU sees an undriven net. Re-asserting the idle level here is
     * harmless and keeps this module's ownership of the pin explicit. */
    PWR_OFF_ANSEL = 0;
    PWR_OFF_LAT   = PWR_OFF_IDLE;
    PWR_OFF_TRIS  = 0;
}

bool power_shutdown_requested(void)
{
    /* The level is what counts, and it has to persist.
     *
     * The INT2 latch still earns its keep -- it proves an edge happened even if
     * the main loop was inside an SD write at the time -- but it is not
     * sufficient alone.  A latched edge whose level has since gone away is a
     * glitch, so the latch is cleared and the request dropped. */
    if (SHUTDOWN_RQ_PORT != SHUTDOWN_RQ_ACTIVE) {
        pending = false;
        PIR10bits.INT2IF = 0;
        return false;
    }

    if (!pending) {
        pending = true;
        pending_since = timebase_ticks();
        return false;
    }

    return (uint16_t)(timebase_ticks() - pending_since) >= SHUTDOWN_DEBOUNCE_TICKS;
}

void power_off(void)
{
    PWR_OFF_LAT = PWR_OFF_ASSERTED;

    /* The PMU cuts the rails from here.  Spin rather than return: there is
     * nothing sensible to do afterwards, and returning would let the main loop
     * start another transaction against a machine that is losing power. */
    for (;;)
        NOP();
}
