#ifndef CONTROLLER_LATCH_H
#define CONTROLLER_LATCH_H

#include <stdint.h>
#include <stdbool.h>

/* Cascaded controller 74AHC595 pair on the port C peripheral bus (SPI1).
 *
 * Two 8-bit devices in series, 16 bits total.  /CTRL_LAT_CS on RA1 enables the
 * board's clock buffer while the 16 controller bits are shifted.
 */

#define CONTROLLER_LATCH_PORTS 2u
#define CONTROLLER_LATCH_IDLE  0xffu

/* Diagnostic only.  Leave disabled during SD-card bring-up: when enabled it
 * deliberately creates periodic MOSI/SCK traffic on the shared SPI1 bus. */
#ifndef CONTROLLER_LATCH_COUNTER_TEST
#define CONTROLLER_LATCH_COUNTER_TEST 0
#endif

/* Initialise both Coleco controller ports to their inactive value.
 * spi1_bus_init() owns the bus pins. */
void controller_latch_init(void);

/* Shift two bytes into the cascaded 595s and latch them.
 *
 * byte0 is shifted first and therefore ends up in the FAR device of the chain;
 * byte1 lands in the near one.  Both are shifted most-significant bit first.
 * Blocking, for 24 SPI clocks.  Not ISR-safe. */
void controller_latch_write(uint8_t byte0, uint8_t byte1);

/* Set one logical controller port and immediately commit both saved bytes.
 *
 * controller 0 is the first/far byte (U5, /CE_CTRL0); controller 1 is the
 * second/near byte (U4, /CE_CTRL1).  Values are the active-low bytes presented
 * directly to the Z80 data bus.  Values which have not changed do not consume
 * a shared-SPI transaction.  Blocking; not ISR-safe. */
void controller_latch_set(uint8_t controller, uint8_t value);

/* Decode one Logitech F310 DirectInput HID report and update a controller.
 *
 * The report must contain at least the first six bytes of the F310's fixed
 * report layout.  Returns false for a bad controller number or short report.
 * Blocking only when the decoded latch value changed; not ISR-safe. */
bool controller_latch_f310_report(uint8_t controller,
                                  uint8_t const *report, uint16_t len);

/* Return one controller port to its inactive value. */
void controller_latch_release(uint8_t controller);

/* Return the byte currently requested for one controller port.  Invalid port
 * numbers read as the inactive value.  Passive and ISR-safe. */
uint8_t controller_latch_value(uint8_t controller);

/* Optional bring-up counter.
 *
 * When CONTROLLER_LATCH_COUNTER_TEST is 1, call from the main loop to write an
 * incrementing pair (n, n+1) every 500 ms.  The counter is disabled by default
 * so an idle controller produces no shared-bus clocks during SD-card bring-up.
 *
 * With the test disabled this routine is an empty stub. */
void controller_latch_tick(void);

#endif /* CONTROLLER_LATCH_H */
