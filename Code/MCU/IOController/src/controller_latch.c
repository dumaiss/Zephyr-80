#include <xc.h>
#include <stdint.h>
#include "config.h"
#include "controller_latch.h"

/* ---------------------------------------------------------------------------
 * Controller latch — deliberately a no-op on this revision
 * ---------------------------------------------------------------------------
 *
 * The d-pad / joystick is a USB HID device.  The intended data flow is
 *
 *   USB device -> USB bridge -> PIC (interrupt) -> 74HC595 pair -> Z80 host
 *
 * so the 595s really are serial-in/parallel-out: the PIC writes the decoded
 * controller state into them and the host reads the parallel outputs.
 *
 * The previous implementation shifted them on RB1/RB3, which dates from when a
 * single bit-banged bus served every peripheral.  That is no longer true --
 * RB1/RB3 are the SIO bus, and the 595s moved to the port C peripheral bus
 * (SPI_CLK on RC3, MISO on RC4, MOSI on RC5) alongside the SD card and the USB
 * bridge, with /CTRL_LAT_CS on RA1 as their select and register clock.
 *
 * Driving RB1/RB3 from here would now corrupt the SIO bus, and would silently
 * become a no-op anyway once PPS hands those pins to SPI2.  Rather than leave a
 * plausible-looking routine pointed at the wrong wires, this is stubbed until
 * the external peripherals are brought up on SPI1 / port C.
 *
 * Reimplementing means: assert /CTRL_LAT_CS, shift 16 bits MSB-first out of
 * SPI1 (LSBF = 0 for the 595s, unlike the SIO link), then release the select --
 * the 595 latches on that rising edge.
 * --------------------------------------------------------------------------- */
void controller_latch_write(uint8_t byte0, uint8_t byte1)
{
    (void)byte0;
    (void)byte1;
}
