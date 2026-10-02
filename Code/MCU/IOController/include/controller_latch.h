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

/* Quiescent controller byte: D6 fire released, D5:D4 spinner idle, D3:D0 no
 * direction, and **D7 low**.
 *
 * D7 was 1 here until Montezuma's Revenge showed it must be 0.  The BIOS
 * complements every controller read, so a game sees ~latch.  Monte merges the
 * two mode bytes and tests the result:
 *
 *     LD A,(73EEh) / AND 0C0h / CP 0C0h      ; its jump test, at 90FFh
 *
 * With D7 high the complemented value can only ever be 00h or 40h, so that
 * compare can never match and the jump button is dead.  With D7 low it yields
 * 80h released and C0h pressed, which is what the test is written for.
 *
 * The BIOS itself only ever looks at D3:D0 and D6, and no other title in the
 * test set reads D7 of a controller byte, so this is the single point to
 * revert if a game is ever found that wants the opposite. */
#define CONTROLLER_LATCH_IDLE  0x7fu

/* Passed to controller_latch_keypad() when no keypad key is held. */
#define CONTROLLER_KEYPAD_NONE 0xffu

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
/* Hold, or release, a ColecoVision keypad code on one controller port.
 *
 * `code` is the active-low 4-bit matrix nibble the latch must present, or
 * CONTROLLER_KEYPAD_NONE to release.  The high nibble, which carries the fire
 * line, is preserved.  While a code is held it overrides the direction nibble
 * of every gamepad report, because a real controller cannot report a keypad
 * key and a joystick direction at the same time.
 *
 * The ColecoVision has no hardware copy of the keypad/joystick mode select --
 * Zephyr decodes neither 80h-9Fh nor C0h-DFh -- so the latch presents one
 * merged byte and the mode-select writes are ignored.  This is how a USB
 * keyboard reaches the eight keypad keys the gamepad substitutes cannot
 * produce.  Blocking for one SPI transaction when the value changes; not
 * ISR-safe. */
void controller_latch_keypad(uint8_t controller, uint8_t code);

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
