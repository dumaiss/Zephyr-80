#include <xc.h>
#include <stdint.h>
#include <stdbool.h>
#include "config.h"
#include "spi1_bus.h"
#include "controller_latch.h"

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

#define CTRL_TICK_PERIOD_MS   10u
#define CTRL_UPDATE_MS        500u
#define CTRL_TICKS_PER_UPDATE (CTRL_UPDATE_MS / CTRL_TICK_PERIOD_MS)

static uint8_t tick_count;
static uint8_t counter;

/* Timer2 produces a 10 ms tick:
 *
 *   FOSC/4 = 16 MHz, 1:128 prescale         -> 125 kHz
 *   T2PR = 249, so the period is 250 counts -> 500 Hz
 *   1:5 postscale                           -> 100 Hz = 10 ms
 *
 * Fifty of those is the 500 ms bring-up period. */
static void timer_init(void)
{
    T2CON = 0x00;             /* stop the timer while it is reconfigured */
    T2CLKCON = 0x01;          /* CS = 00001 -> FOSC/4 = 16 MHz */
    T2HLT = 0x00;             /* free running, software gated */
    T2PR = 249u;              /* restarts at 0 on reaching PR -> 250 counts */
    T2TMR = 0x00;

    T2CONbits.CKPS  = 0b111;  /* 1:128 prescale  -> 125 kHz */
    T2CONbits.OUTPS = 0b0100; /* 1:5 postscale   -> 100 Hz = 10 ms */

    PIR3bits.TMR2IF = 0;
    T2CONbits.ON = 1;
}

void controller_latch_init(void)
{
    /* The bus itself is owned by spi1_bus_init(), called from platform_init().
     * The select is also RCLK, so it must rest deasserted (high). */
    CTRL_LAT_CS_ANSEL = 0;
    CTRL_LAT_CS_LAT   = CTRL_LAT_CS_IDLE;
    CTRL_LAT_CS_TRIS  = 0;

    timer_init();

    tick_count = 0u;
    counter    = 0u;

    /* Park the outputs at a known value rather than whatever the 595s powered
     * up holding. */
    controller_latch_write(0u, 0u);
}

void controller_latch_write(uint8_t byte0, uint8_t byte1)
{
    /* The SD card shares this bus and runs it at a different rate, so claim the
     * settings this device needs.  Reconfiguring also empties the FIFOs. */
    spi1_bus_configure(CTRL_SPI_BAUD, SPI1_MSB_FIRST);

    /* Hold the select asserted for the whole 16-bit shift. */
    CTRL_LAT_CS_LAT = CTRL_LAT_CS_ASSERTED;

    if (spi1_bus_write(byte0))
        (void)spi1_bus_write(byte1);

    /* Releasing the select is the RCLK rising edge that commits both devices'
     * shift registers to their output pins. */
    CTRL_LAT_CS_LAT = CTRL_LAT_CS_IDLE;
}

void controller_latch_tick(void)
{
    if (!PIR3bits.TMR2IF)
        return;

    PIR3bits.TMR2IF = 0;

    if (++tick_count < CTRL_TICKS_PER_UPDATE)
        return;

    tick_count = 0u;

    /* (0,1) then (1,2) then (2,3)...  Both bytes wrap at 255 independently,
     * which is fine -- the point is only that the monitor shows them counting. */
    //controller_latch_write(counter, (uint8_t)(counter + 1u));
    counter++;
}
