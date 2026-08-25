#include "power_controller.h"

/*
 * ONE writer for /SHUTDOWN_RQ, and one rule: the line is asserted exactly while
 * a soft shutdown is outstanding -- that is, while power_button_armed is set.
 *
 * This is a reconciler rather than scattered assert/deassert calls because the
 * scattered version is what produced the worst bug this module has had. The
 * action was once ACTION_HOLD_IO_RESET and meant "hold the IO Controller in
 * reset while the rails come up"; asserting it during power-on and releasing it
 * on PWR_OK was correct for that meaning. When the signal was redefined as
 * "please shut down", the call sites were left alone, so the PMU spent every
 * power-on asking a booting controller to shut down. The PIC reaches its main
 * loop long before PWR_OK, so it obeyed: dropped COMMAND_READY, flushed, drove
 * /PWR_OFF and spun. Every boot, before the PMU ever released the line.
 *
 * With the state derived in one place from one flag, no path can assert this
 * signal as a side effect of meaning something else.
 */
static power_controller_action_t reconcile_shutdown_rq(
    power_controller_t *controller)
{
    if (controller->power_button_armed && !controller->shutdown_rq_asserted) {
        controller->shutdown_rq_asserted = 1;
        return POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ;
    }

    if (!controller->power_button_armed && controller->shutdown_rq_asserted) {
        controller->shutdown_rq_asserted = 0;
        return POWER_CONTROLLER_ACTION_DEASSERT_SHUTDOWN_RQ;
    }

    return POWER_CONTROLLER_ACTION_NONE;
}

void power_controller_init(power_controller_t *controller,
                           uint8_t initial_switch_pressed,
                           uint8_t initial_pwr_ok)
{
    /*
     * /SHUTDOWN_RQ starts deasserted, matching the level io_init() drives.
     * Nothing is being asked of the IO Controller until the user presses the
     * button on a running machine.
     *
     * This used to start ASSERTED, which was right when the signal held the IO
     * Controller in reset and wrong the moment it became a shutdown request.
     */
    controller->was_pressed = initial_switch_pressed;
    controller->power_on_pending = 0;
    controller->power_button_armed = initial_switch_pressed && initial_pwr_ok;
    controller->force_off_done = 0;
    controller->shutdown_rq_asserted = 0;
    controller->press_ticks = 0;

    /* Start disbelieving /PWR_OFF_RQ. If the rails are already good this is
     * spent in the first second of running; if they are not, it is reloaded
     * when they come good. */
    controller->pwr_off_grace = POWER_CONTROLLER_PWR_OFF_GRACE_TICKS;
    controller->pwr_off_seen_idle = 0;
}

power_controller_action_t power_controller_step(
    power_controller_t *controller,
    const power_controller_inputs_t *inputs)
{
    power_controller_action_t action = POWER_CONTROLLER_ACTION_NONE;
    uint8_t pwr_off_requested = inputs->pwr_off_requested;

    /*
     * Hold /PWR_OFF_RQ at arm's length while the rails settle and the IO
     * Controller boots. Reloaded whenever PWR_OK is low, so the countdown
     * always runs from the supply becoming good rather than from PMU reset.
     */
    if (!inputs->pwr_ok) {
        controller->pwr_off_grace = POWER_CONTROLLER_PWR_OFF_GRACE_TICKS;
        controller->pwr_off_seen_idle = 0;
    } else if (controller->pwr_off_grace > 0) {
        controller->pwr_off_grace--;
    }

    /*
     * Arm on the first sight of /PWR_OFF_RQ deasserted.
     *
     * The timeout says "wait a while"; this says "and do not believe it at all
     * until the IO Controller has proved it can release the line". A controller
     * that is absent, unflashed, or whose card holds the net low never releases
     * it, and without this the only question a timeout answers is how long the
     * machine stays up before shutting itself off.
     *
     * The failure mode this chooses is the right one: shutdown stops working,
     * and the machine keeps running. The other way round loses a machine that
     * will not boot.
     *
     * Only counts while PWR_OK is true. An idle line with the rails down proves
     * nothing -- the IO Controller is not powered, so the level is whatever the
     * pull-ups say and no release has happened. Arming on that was a real bug,
     * caught by test_pwr_off_never_released_never_powers_off: the flag was
     * cleared when the rails dropped and then set again in the same step,
     * making the arming a no-op and leaving only the timeout.
     */
    if (inputs->pwr_ok && !inputs->pwr_off_requested) {
        controller->pwr_off_seen_idle = 1;
    }

    if ((controller->pwr_off_grace > 0) || !controller->pwr_off_seen_idle) {
        pwr_off_requested = 0;
    }

    /*
     * The normal shutdown path is controlled by the IO Controller. Once it
     * asserts PWR_OFF_RQ, turn off the PSU immediately and clear any
     * in-progress button action.
     */
    if (pwr_off_requested) {
        controller->power_on_pending = 0;
        controller->power_button_armed = 0;
        controller->force_off_done = 0;
        controller->press_ticks = 0;
        controller->was_pressed = inputs->pwr_switch_pressed;
        return POWER_CONTROLLER_ACTION_PSU_OFF |
               reconcile_shutdown_rq(controller);
    }

    /*
     * A new press means different things depending on current power state:
     * - off: turn on the PSU and wait for PWR_OK.  /SHUTDOWN_RQ is untouched
     * - on: ask the IO Controller to shut down, and wait for /PWR_OFF_RQ
     */
    if (inputs->pwr_switch_pressed && !controller->was_pressed) {
        controller->press_ticks = 0;
        controller->force_off_done = 0;

        if (inputs->pwr_ok) {
            /* Running machine: this is the soft-shutdown request. Arming is
             * what asserts the line; see reconcile_shutdown_rq(). */
            controller->power_button_armed = 1;
        } else {
            /* Powering on. /SHUTDOWN_RQ is deliberately NOT touched here: the
             * IO Controller is about to boot and must not be greeted with a
             * request to shut down. */
            controller->power_on_pending = 1;
            controller->power_button_armed = 0;
            action |= POWER_CONTROLLER_ACTION_PSU_ON;
        }
    }

    /*
     * Power-on is a two-stage sequence: the press enables the PSU, and PWR_OK
     * says the rails are good. Both stages leave /SHUTDOWN_RQ alone.
     */
    if (controller->power_on_pending && inputs->pwr_ok) {
        controller->power_on_pending = 0;
    }

    /*
     * Holding the button for the force-off threshold bypasses the IO Controller
     * and removes PSU enable directly.
     *
     * This deliberately does NOT wait for the cache flush. Force is force: it
     * exists for a machine that is already wedged, so making it depend on the
     * component most likely to be wedged would defeat it. Data loss here is
     * accepted and expected.
     */
    if (inputs->pwr_switch_pressed &&
        controller->power_button_armed &&
        !controller->force_off_done) {
        if (controller->press_ticks < POWER_CONTROLLER_FORCE_OFF_TICKS) {
            controller->press_ticks++;
        }

        if (controller->press_ticks >= POWER_CONTROLLER_FORCE_OFF_TICKS) {
            action |= POWER_CONTROLLER_ACTION_PSU_OFF;
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

    return action | reconcile_shutdown_rq(controller);
}
