#include <xc.h>
#include <stdint.h>
#include "config.h"
#include "controller_latch.h"

/* The cascaded 74HC595s hang off the shared serial bus:
 *
 *   SER   <- SIO_MOSI      RB1
 *   SRCLK <- SIO_SCK       RB3
 *   RCLK  <- /CTRL_LAT_CS  RA1
 *
 * The 595 latches on RCLK's rising edge, and /CTRL_LAT_CS is active-low, so the
 * latching edge is the deselect edge: hold the select asserted for the whole
 * 16-bit shift, then release it to commit the shift register to the outputs.
 * Electrically this is the same low-shift / rising-edge-latch sequence the
 * previous revision drove from RF0.
 *
 * SIO_MOSI is already an output for the command link, so unlike the previous
 * revision this routine does not have to borrow an input pin or flip TRIS.
 */
static void shift_byte(uint8_t value)
{
    uint8_t i;

    for (i = 0u; i < 8u; i++) {
        SIO_MOSI_LAT = (uint8_t)((value & 0x80u) != 0u);
        __delay_us(1);
        SIO_SCK_LAT = 1;
        __delay_us(1);
        SIO_SCK_LAT = 0;
        value <<= 1;
    }
}

/* Inputs: byte0, then byte1, shifted MSB-first.
 * Outputs: both 74HC595 output registers update on the /CTRL_LAT_CS release.
 * Clobbers: leaves SIO_MOSI marking high and SIO_SCK low.
 * Blocking: yes, for 16 short clock pulses.
 * Virtual Drip traffic: none.  ISR-safe: no.
 */
void controller_latch_write(uint8_t byte0, uint8_t byte1)
{
    /* Take the latch for the whole 16-bit shift window. */
    CTRL_LAT_CS_LAT = CTRL_LAT_CS_ASSERTED;
    SIO_SCK_LAT = 0;

    //shift_byte(byte0);
    //shift_byte(byte1);

    shift_byte(0);
    shift_byte(0);

    /* Releasing the select is the RCLK rising edge that latches the outputs. */
    __delay_us(1);
    CTRL_LAT_CS_LAT = CTRL_LAT_CS_IDLE;

    SIO_SCK_LAT = 0;
    SIO_MOSI_LAT = 1;
}
