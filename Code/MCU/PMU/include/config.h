#ifndef CONFIG_H
#define CONFIG_H

#include <avr/io.h>

#include "power_controller.h"

/*
 * Set to 1 to run the PMU without participating in the IO Controller
 * handshake. In that mode the firmware ignores PWR_OFF_RQ and does not drive
 * PWR_STATE.
 */
#ifndef PMU_IGNORE_IO_CONTROLLER_SIGNALS
#define PMU_IGNORE_IO_CONTROLLER_SIGNALS 1
#endif

/*
 * PMU power-controller pin map.
 *
 * Each signal defines the data-direction register, output/input register, and
 * bit used by main.c. Keeping these names signal-oriented makes the firmware
 * easier to check against the schematic.
 */

/* IO Controller asks the PMU to shut down the PSU. Active low input. */
#define PWR_OFF_RQ_DDR  DDRB
#define PWR_OFF_RQ_PORT PORTB
#define PWR_OFF_RQ_PINR PINB
#define PWR_OFF_RQ_PIN  PB4

/* PWR_STATE high holds the IO Controller in reset; low allows it to run. */
#define PWR_STATE_DDR   DDRB
#define PWR_STATE_PORT  PORTB
#define PWR_STATE_PIN   PB3

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
