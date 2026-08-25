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

/*
 * How long after the rails come good before /PWR_OFF_RQ is believed.
 *
 * The IO Controller is not running yet when PWR_OK asserts; its own supply is
 * only just up and its pins are whatever reset leaves them. Until its firmware
 * takes ownership of /PWR_OFF_RQ and drives it to the deasserted level, the net
 * is held only by pull-ups and is the least trustworthy it will ever be. Acting
 * on it during that window turns a power-up into an immediate power-down, which
 * presents as "the machine will not start".
 *
 * The grace period is measured from PWR_OK, not from PMU reset: the PMU runs on
 * the always-on rail and may have been up for hours before the user pressed the
 * button.
 *
 * A timeout alone is not enough, though, and should not be relied on. If the IO
 * Controller never releases /PWR_OFF_RQ -- because it is not running, not
 * flashed, or the net is held low by something on its card -- then any timeout
 * merely chooses how many seconds the machine stays up before dying. That is
 * why the request must also be ARMED: see pwr_off_seen_idle.
 */
#define POWER_CONTROLLER_PWR_OFF_GRACE_MS 5000
#define POWER_CONTROLLER_PWR_OFF_GRACE_TICKS \
    (POWER_CONTROLLER_PWR_OFF_GRACE_MS / POWER_CONTROLLER_POLL_INTERVAL_MS)

typedef struct {
    uint8_t pwr_switch_pressed;
    uint8_t pwr_ok;
    uint8_t pwr_off_requested;
} power_controller_inputs_t;

/*
 * ASSERT_SHUTDOWN_RQ / DEASSERT_SHUTDOWN_RQ drive /SHUTDOWN_RQ, which asks the
 * IO Controller to clean up and then tell us it is done. They do NOT reset the
 * IO Controller and they do not gate whether the system may run.
 *
 * The previous names said IO_RESET, which invited exactly that misreading --
 * and wiring this signal to the IO Controller's own reset would stop it
 * flushing the SD write-back cache, losing data on every clean shutdown while
 * appearing to work.
 */
typedef enum {
    POWER_CONTROLLER_ACTION_NONE = 0,
    POWER_CONTROLLER_ACTION_PSU_ON = 1 << 0,
    POWER_CONTROLLER_ACTION_PSU_OFF = 1 << 1,
    POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ = 1 << 2,
    POWER_CONTROLLER_ACTION_DEASSERT_SHUTDOWN_RQ = 1 << 3,
} power_controller_action_t;

typedef struct {
    uint8_t was_pressed;
    uint8_t power_on_pending;
    uint8_t power_button_armed;
    uint8_t force_off_done;
    uint8_t shutdown_rq_asserted;
    uint16_t press_ticks;
    uint16_t pwr_off_grace;
    uint8_t  pwr_off_seen_idle;
} power_controller_t;

void power_controller_init(power_controller_t *controller,
                           uint8_t initial_switch_pressed,
                           uint8_t initial_pwr_ok);

power_controller_action_t power_controller_step(
    power_controller_t *controller,
    const power_controller_inputs_t *inputs);

#endif
