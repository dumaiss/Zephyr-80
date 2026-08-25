#ifndef CONFIG_H
#define CONFIG_H

#include <avr/io.h>

#include "power_controller.h"

/*
 * Set to 1 to run the PMU standalone, ignoring /PWR_OFF_RQ and leaving
 * /SHUTDOWN_RQ deasserted.
 *
 * Both signals are ACTIVE LOW so each end can hold its own input at the
 * deasserted level with a programmed pull-up. A net whose partner is unpowered
 * or high-Z then reads "nothing requested" rather than floating. Neither MCU
 * has programmable pull-downs -- the AVR has pull-ups only, and so does the PIC
 * -- so this is the only polarity that is fail-safe in firmware alone.
 *
 * Because of that, standalone mode is now genuinely inert rather than merely
 * untested: /SHUTDOWN_RQ idles high either way.
 */
#ifndef PMU_IGNORE_IO_CONTROLLER_SIGNALS
#define PMU_IGNORE_IO_CONTROLLER_SIGNALS 0
#endif

/*
 * PMU power-controller pin map.
 *
 * Each signal defines the data-direction register, output/input register, and
 * bit used by main.c. Keeping these names signal-oriented makes the firmware
 * easier to check against the schematic.
 */

/*
 * /PWR_OFF_RQ: the IO Controller telling us it is done and power may go.
 * Active low, held high by the internal pull-up when nothing drives it.
 */
#define PWR_OFF_RQ_DDR  DDRB
#define PWR_OFF_RQ_PORT PORTB
#define PWR_OFF_RQ_PINR PINB
#define PWR_OFF_RQ_PIN  PB4

/*
 * /SHUTDOWN_RQ: us asking the IO Controller to clean up. Active low, idle high.
 *
 * A shutdown request and nothing more. It does NOT gate whether the system may
 * run -- the PSU comes up when PWR_OK is good and that is the whole start-up
 * story. It was previously called PWR_STATE and described as holding the IO
 * Controller in reset, which is a name and a description that appear nowhere on
 * the schematic; the net is SHUTDOWN_RQ.
 */
#define SHUTDOWN_RQ_DDR   DDRB
#define SHUTDOWN_RQ_PORT  PORTB
#define SHUTDOWN_RQ_PIN   PB3

/* Enclosure power switch. Active low input, handled as an edge/hold signal. */
#define PWR_SW_DDR      DDRB
#define PWR_SW_PORT     PORTB
#define PWR_SW_PINR     PINB
#define PWR_SW_PIN      PB2

/* ATX PSU power-good signal. Active high input from the ATX connector. */
#define PWR_OK_DDR      DDRB
#define PWR_OK_PORT     PORTB
#define PWR_OK_PINR     PINB
#define PWR_OK_PIN      PB1

/* MOSFET gate that controls the ATX PS_ON# line. */
#define PS_ON_DDR       DDRB
#define PS_ON_PORT      PORTB
#define PS_ON_PIN       PB0

/*
 * PB0 drives a MOSFET gate, not the ATX PS_ON# net directly.
 * PB0 high enables the MOSFET and pulls ATX PS_ON# low.
 * PB0 low disables the MOSFET and lets ATX PS_ON# return inactive.
 */
#define PS_ON_MOSFET_ON_LEVEL  1
#define PS_ON_MOSFET_OFF_LEVEL 0

/* Timing values are based on the polling loop in main.c. */
#define POLL_INTERVAL_MS   POWER_CONTROLLER_POLL_INTERVAL_MS

#endif
