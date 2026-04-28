#ifndef POWER_CONTROLLER_H
#define POWER_CONTROLLER_H

#include <stdint.h>

/*
 * Power-controller timing. The firmware polls the switch every 10 ms, so the
 * 5 second force-off threshold is represented as a count of polling ticks.
 */
#define POWER_CONTROLLER_POLL_INTERVAL_MS  10
#define POWER_CONTROLLER_FORCE_OFF_HOLD_MS 5000
#define POWER_CONTROLLER_FORCE_OFF_TICKS \
    (POWER_CONTROLLER_FORCE_OFF_HOLD_MS / POWER_CONTROLLER_POLL_INTERVAL_MS)

typedef struct {
    uint8_t pwr_switch_pressed;
    uint8_t pwr_ok;
    uint8_t pwr_off_requested;
} power_controller_inputs_t;

typedef enum {
    POWER_CONTROLLER_ACTION_NONE = 0,
    POWER_CONTROLLER_ACTION_PSU_ON = 1 << 0,
    POWER_CONTROLLER_ACTION_PSU_OFF = 1 << 1,
    POWER_CONTROLLER_ACTION_HOLD_IO_RESET = 1 << 2,
    POWER_CONTROLLER_ACTION_RELEASE_IO_RESET = 1 << 3,
} power_controller_action_t;

typedef struct {
    uint8_t was_pressed;
    uint8_t power_on_pending;
    uint8_t power_button_armed;
    uint8_t force_off_done;
    uint8_t io_reset_held;
    uint16_t press_ticks;
} power_controller_t;

void power_controller_init(power_controller_t *controller,
                           uint8_t initial_switch_pressed,
                           uint8_t initial_pwr_ok);

power_controller_action_t power_controller_step(
    power_controller_t *controller,
    const power_controller_inputs_t *inputs);

#endif
