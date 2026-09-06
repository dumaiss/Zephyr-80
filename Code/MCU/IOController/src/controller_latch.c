#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "config.h"
#include "spi1_bus.h"
#include "controller_latch.h"
#include "timebase.h"

/* ---------------------------------------------------------------------------
 * Controller latch — first bring-up of the port C peripheral bus
 * ---------------------------------------------------------------------------
 *
 * The d-pad / joystick is a USB HID device.  The intended data flow is
 *
 *   USB device -> USB bridge -> PIC -> 74HC595 pair -> Z80 host
 *
 * so the 595s are serial-in/parallel-out: the PIC writes the decoded controller
 * state into them and the host reads the parallel outputs.
 *
 * Wiring:
 *
 *   SER                <- MOSI          RC5  (SPI1 SDO)
 *   common SRCLK/RCLK  <- gated SPI_CLK RC3  (SPI1 SCK)
 *   clock-buffer /OE   <- /CTRL_LAT_CS  RA1
 *
 * Two differences from the SIO link on SPI2 are deliberate:
 *
 *   - LSBF = 0.  The 595 shifts most-significant bit first; the Z80 SIO shifts
 *     bit 0 first.  The two buses genuinely disagree, so this is per-module.
 *   - No inter-byte pacing.  Nothing on the far side has to keep up in
 *     software, unlike the Z80's polled receive loop.
 * --------------------------------------------------------------------------- */

/* Conservative bring-up rate for verifying the cascaded latch transaction. */
#define CTRL_SPI_BAUD         SPI1_BAUD_1MHZ

/* Bytes presented to a standard Coleco controller read.  Inputs are active
 * low.  D7 is high; D6 is fire and D3..D0 are
 * left/down/right/up respectively when read as individual bit positions. */
#define CTRL_UP               0x01u
#define CTRL_RIGHT            0x02u
#define CTRL_DOWN             0x04u
#define CTRL_LEFT             0x08u
#define CTRL_FIRE             0x40u
#define CTRL_KEYPAD_1         0x02u
#define CTRL_KEYPAD_2         0x08u

static uint8_t controller_value[CONTROLLER_LATCH_PORTS];
static uint8_t controller_tx[3];

#define CTRL_UPDATE_MS        500u
#define CTRL_TICKS_PER_UPDATE (CTRL_UPDATE_MS / TIMEBASE_TICK_MS)

#if CONTROLLER_LATCH_COUNTER_TEST
static uint16_t last_update;
static uint8_t  counter;
#endif

void controller_latch_init(void)
{
    /* The bus itself is owned by spi1_bus_init(), called from platform_init().
     * The bus owner already parked the controller clock buffer disabled. */

#if CONTROLLER_LATCH_COUNTER_TEST
    last_update = timebase_ticks();
    counter     = 0u;
#endif

    /* Park both ports at a standard-controller idle value rather than whatever
     * the 595s powered up holding. */
    controller_value[0] = CONTROLLER_LATCH_IDLE;
    controller_value[1] = CONTROLLER_LATCH_IDLE;
    controller_latch_write(controller_value[0], controller_value[1]);
}

void controller_latch_write(uint8_t byte0, uint8_t byte1)
{
    /* U4/U5 have SRCLK and RCLK tied to the same gated clock.  In this
     * configuration the 595 shift register is one clock ahead of its output
     * register.  Send 24 clocks with the requested 16 bits in serial positions
     * 8..23; the 24th rising edge copies exactly those preceding 16 bits to
     * the two output registers.
     *
     * Keep the packed bytes in static storage.  This driver is foreground-only,
     * and static storage also protects values which must survive nested SPI
     * calls from XC8's non-reentrant automatic-variable overlay. */
    controller_tx[0] = (uint8_t)(byte0 >> 7);
    controller_tx[1] = (uint8_t)(byte0 << 1);
    controller_tx[1] |= (uint8_t)(byte1 >> 7);
    controller_tx[2] = (uint8_t)(byte1 << 1);

    /* The SD card shares this bus and runs it at a different rate, so claim the
     * settings this device needs.  Reconfiguring also empties the FIFOs. */
    spi1_bus_configure(CTRL_SPI_BAUD, SPI1_MSB_FIRST);

    /* Enable the controller clock path for the whole packed shift.  The
     * central selector first releases the SD and USB devices, so this
     * transaction is electrically one-hot even if a previous driver returned
     * through an error path. */
    spi1_bus_select(SPI1_DEVICE_CONTROLLER_LATCH);

    if (spi1_bus_write(controller_tx[0]) &&
        spi1_bus_write(controller_tx[1]))
        (void)spi1_bus_write(controller_tx[2]);

    /* Release the controller clock path after both bytes. */
    spi1_bus_select(SPI1_DEVICE_NONE);
}

void controller_latch_set(uint8_t controller, uint8_t value)
{
    if (controller >= CONTROLLER_LATCH_PORTS)
        return;
    if (controller_value[controller] == value)
        return;

    controller_value[controller] = value;
    controller_latch_write(controller_value[0], controller_value[1]);
}

void controller_latch_release(uint8_t controller)
{
    controller_latch_set(controller, CONTROLLER_LATCH_IDLE);
}

uint8_t controller_latch_value(uint8_t controller)
{
    if (controller >= CONTROLLER_LATCH_PORTS)
        return CONTROLLER_LATCH_IDLE;
    return controller_value[controller];
}

bool controller_latch_f310_report(uint8_t controller,
                                  uint8_t const *report, uint16_t len)
{
    uint8_t value = CONTROLLER_LATCH_IDLE;
    uint8_t hat;

    if (controller >= CONTROLLER_LATCH_PORTS || report == NULL || len < 6u)
        return false;

    /* There is no hardware copy of the Coleco keypad/joystick mode select.
     * Give the two start keys priority while held; all other reports carry the
     * normal direction nibble.  These are the raw active-low matrix nibbles
     * returned by the latch: keypad 1 is 02h and keypad 2 is 08h. */
    if ((report[5] & 0x10u) != 0u || (report[4] & 0x10u) != 0u) {
        value = (uint8_t)((value & 0xf0u) | CTRL_KEYPAD_1);
    } else if ((report[5] & 0x20u) != 0u ||
               (report[4] & 0x80u) != 0u) {
        value = (uint8_t)((value & 0xf0u) | CTRL_KEYPAD_2);
    } else {
        hat = (uint8_t)(report[4] & 0x0fu);
        switch (hat) {
        case 0u: value &= (uint8_t)~CTRL_UP;                      break;
        case 1u: value &= (uint8_t)~(CTRL_UP | CTRL_RIGHT);       break;
        case 2u: value &= (uint8_t)~CTRL_RIGHT;                   break;
        case 3u: value &= (uint8_t)~(CTRL_RIGHT | CTRL_DOWN);     break;
        case 4u: value &= (uint8_t)~CTRL_DOWN;                    break;
        case 5u: value &= (uint8_t)~(CTRL_DOWN | CTRL_LEFT);      break;
        case 6u: value &= (uint8_t)~CTRL_LEFT;                    break;
        case 7u: value &= (uint8_t)~(CTRL_LEFT | CTRL_UP);        break;
        default:
            /* With the F310 Mode LED on, the left stick carries the d-pad.
             * Neutral is 80h; the wide dead zone avoids centre noise. */
            if (report[0] < 0x40u)
                value &= (uint8_t)~CTRL_LEFT;
            if (report[0] > 0xc0u)
                value &= (uint8_t)~CTRL_RIGHT;
            if (report[1] < 0x40u)
                value &= (uint8_t)~CTRL_UP;
            if (report[1] > 0xc0u)
                value &= (uint8_t)~CTRL_DOWN;
            break;
        }
    }

    /* Either primary face button is the Coleco fire line.  This remains valid
     * during a keypad override, where D6 is the controller's second fire key. */
    if ((report[4] & 0x60u) != 0u)
        value &= (uint8_t)~CTRL_FIRE;

    controller_latch_set(controller, value);
    return true;
}

void controller_latch_tick(void)
{
#if CONTROLLER_LATCH_COUNTER_TEST
    uint16_t now = timebase_ticks();

    /* Elapsed-time test, not equality: a long SD access can span several tick
     * periods, and the counter then jumps by more than one. */
    if ((uint16_t)(now - last_update) < CTRL_TICKS_PER_UPDATE)
        return;

    last_update = now;

    /* (0,1) then (1,2) then (2,3)...  Both bytes wrap at 255 independently,
     * which is fine -- the point is only that the monitor shows them counting. */
    controller_latch_write(counter, (uint8_t)(counter + 1u));
    counter++;
#endif
}
