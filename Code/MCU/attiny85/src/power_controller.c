#include "power_controller.h"

static power_controller_action_t hold_io_reset(power_controller_t *controller)
{
    controller->io_reset_held = 1;
    return POWER_CONTROLLER_ACTION_HOLD_IO_RESET;
}

static power_controller_action_t release_io_reset(power_controller_t *controller)
{
    controller->io_reset_held = 0;
    return POWER_CONTROLLER_ACTION_RELEASE_IO_RESET;
}

void power_controller_init(power_controller_t *controller,
                           uint8_t initial_switch_pressed,
                           uint8_t initial_pwr_ok)
{
    /*
     * PWR_STATE starts high so the IO Controller remains in reset until the
     * controller sees a stable powered state and explicitly releases it.
     */
    controller->was_pressed = initial_switch_pressed;
    controller->power_on_pending = 0;
    controller->power_button_armed = initial_switch_pressed && initial_pwr_ok;
    controller->force_off_done = 0;
    controller->io_reset_held = 1;
    controller->press_ticks = 0;
}

power_controller_action_t power_controller_step(
    power_controller_t *controller,
    const power_controller_inputs_t *inputs)
{
    power_controller_action_t action = POWER_CONTROLLER_ACTION_NONE;

    /*
     * The normal shutdown path is controlled by the IO Controller. Once it
     * asserts PWR_OFF_RQ, turn off the PSU immediately and clear any
     * in-progress button action.
     */
    if (inputs->pwr_off_requested) {
        controller->power_on_pending = 0;
        controller->power_button_armed = 0;
        controller->force_off_done = 0;
        controller->press_ticks = 0;
        controller->was_pressed = inputs->pwr_switch_pressed;
        return POWER_CONTROLLER_ACTION_PSU_OFF | hold_io_reset(controller);
    }

    /*
     * A new press means different things depending on current power state:
     * - off: turn on the PSU and wait for PWR_OK before releasing reset
     * - on: hold the IO Controller in reset so it can finish shutdown work
     */
    if (inputs->pwr_switch_pressed && !controller->was_pressed) {
        controller->press_ticks = 0;
        controller->force_off_done = 0;

        if (inputs->pwr_ok) {
            controller->power_button_armed = 1;
            action |= hold_io_reset(controller);
        } else {
            controller->power_on_pending = 1;
            controller->power_button_armed = 0;
            action |= POWER_CONTROLLER_ACTION_PSU_ON;
            action |= hold_io_reset(controller);
        }
    }

    /*
     * Power-on is a two-stage sequence. The switch press enables the PSU first.
     * PWR_STATE stays high until the PSU asserts PWR_OK, then the IO Controller
     * is released from reset.
     */
    if (controller->power_on_pending && inputs->pwr_ok) {
        action |= release_io_reset(controller);
        controller->power_on_pending = 0;
    } else if (inputs->pwr_ok &&
               !controller->power_button_armed &&
               !controller->power_on_pending &&
               controller->io_reset_held) {
        action |= release_io_reset(controller);
    }

    /*
     * Holding the button for the force-off threshold bypasses the IO Controller
     * and removes PSU enable directly.
     */
    if (inputs->pwr_switch_pressed &&
        controller->power_button_armed &&
        !controller->force_off_done) {
        if (controller->press_ticks < POWER_CONTROLLER_FORCE_OFF_TICKS) {
            controller->press_ticks++;
        }

        if (controller->press_ticks >= POWER_CONTROLLER_FORCE_OFF_TICKS) {
            action |= POWER_CONTROLLER_ACTION_PSU_OFF;
            action |= hold_io_reset(controller);
            controller->power_button_armed = 0;
            controller->force_off_done = 1;
        }
    }

    /* Releasing the switch clears hold timing for the next press. */
    if (!inputs->pwr_switch_pressed) {
        controller->press_ticks = 0;
        controller->force_off_done = 0;
    }

    controller->was_pressed = inputs->pwr_switch_pressed;
    return action;
}
