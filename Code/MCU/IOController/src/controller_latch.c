#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
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
 *   SER   <- MOSI           RC5   (SPI1 SDO)
 *   SRCLK <- SPI_CLK        RC3   (SPI1 SCK)
 *   RCLK  <- /CTRL_LAT_CS   RA1
 *
 * Two differences from the SIO link on SPI2 are deliberate:
 *
 *   - LSBF = 0.  The 595 shifts most-significant bit first; the Z80 SIO shifts
 *     bit 0 first.  The two buses genuinely disagree, so this is per-module.
 *   - No inter-byte pacing.  Nothing on the far side has to keep up in
 *     software, unlike the Z80's polled receive loop.
 * --------------------------------------------------------------------------- */

/* 74HC595 shift clock.  1 MHz is conservative for the part; it is a bring-up
 * value for a mezzanine bus whose loading is not yet characterised. */
#define CTRL_SPI_BAUD         SPI1_BAUD_1MHZ

#define CTRL_UPDATE_MS        500u
#define CTRL_TICKS_PER_UPDATE (CTRL_UPDATE_MS / TIMEBASE_TICK_MS)

#if CONTROLLER_LATCH_COUNTER_TEST
static uint16_t last_update;
static uint8_t  counter;
#endif

void controller_latch_init(void)
{
    /* The bus itself is owned by spi1_bus_init(), called from platform_init().
     * The select is also RCLK; the bus owner already parked it high. */

#if CONTROLLER_LATCH_COUNTER_TEST
    last_update = timebase_ticks();
    counter     = 0u;
#endif

    /* Park the outputs at a known value rather than whatever the 595s powered
     * up holding. */
    controller_latch_write(0u, 0u);
}

void controller_latch_write(uint8_t byte0, uint8_t byte1)
{
    /* The SD card shares this bus and runs it at a different rate, so claim the
     * settings this device needs.  Reconfiguring also empties the FIFOs. */
    spi1_bus_configure(CTRL_SPI_BAUD, SPI1_MSB_FIRST);

    /* Hold RCLK low for the whole 16-bit shift.  The central selector first
     * releases the SD and USB devices, so this transaction is electrically
     * one-hot even if a previous driver returned through an error path. */
    spi1_bus_select(SPI1_DEVICE_CONTROLLER_LATCH);

    if (spi1_bus_write(byte0))
        (void)spi1_bus_write(byte1);

    /* Releasing the select is the RCLK rising edge that commits both devices'
     * shift registers to their output pins. */
    spi1_bus_select(SPI1_DEVICE_NONE);
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
