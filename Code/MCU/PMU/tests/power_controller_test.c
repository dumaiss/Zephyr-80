#include <stdio.h>
#include <stdlib.h>

#include "power_controller.h"

static unsigned failures;

static power_controller_inputs_t inputs(uint8_t pressed,
                                        uint8_t pwr_ok,
                                        uint8_t off_requested)
{
    power_controller_inputs_t result = {
        .pwr_switch_pressed = pressed,
        .pwr_ok = pwr_ok,
        .pwr_off_requested = off_requested,
    };

    return result;
}

static power_controller_action_t step(power_controller_t *controller,
                                      uint8_t pressed,
                                      uint8_t pwr_ok,
                                      uint8_t off_requested)
{
    const power_controller_inputs_t current =
        inputs(pressed, pwr_ok, off_requested);

    return power_controller_step(controller, &current);
}

/* Run out the startup grace period so /PWR_OFF_RQ is believed.
 *
 * Tests that are about the shutdown handshake are about steady-state
 * behaviour: the machine has been up for a while and the IO Controller is
 * running. Without this they would be testing the grace period instead, and
 * would have started failing the moment it was introduced -- which is exactly
 * what happened. */
static void settle(power_controller_t *controller, uint8_t pwr_ok)
{
    uint16_t i;

    for (i = 0; i < POWER_CONTROLLER_PWR_OFF_GRACE_TICKS; i++) {
        (void)step(controller, 0, pwr_ok, 0);
    }
}

static void expect_action(const char *test_name,
                          power_controller_action_t actual,
                          power_controller_action_t expected)
{
    if (actual != expected) {
        printf("FAIL: %s: expected action 0x%x, got 0x%x\n",
               test_name,
               expected,
               actual);
        failures++;
    }
}

/* Weaker than expect_action on purpose: the boot-path regression test cares
 * about one thing only -- that nothing, on any step, tells a booting IO
 * Controller to shut down. Other bits are free to change. */
static void expect_no_assert(const char *stage, power_controller_action_t actual)
{
    if ((actual & POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ) != 0) {
        printf("FAIL: %s asserted /SHUTDOWN_RQ during power-on (action 0x%x)\n",
               stage, (unsigned)actual);
        failures++;
    }
}

static void test_press_while_off_turns_psu_on_and_waits_for_pwr_ok(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 0);

    expect_action("press while off turns the PSU on and nothing else",
                  step(&controller, 1, 0, 0),
                  POWER_CONTROLLER_ACTION_PSU_ON);

    expect_action("release while PWR_OK is low does nothing",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("PWR_OK assertion does not touch /SHUTDOWN_RQ",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("after power-on no shutdown request is emitted",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_held_press_while_off_turns_psu_on_before_pwr_ok(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 0);

    expect_action("off-state press enables PSU before PWR_OK",
                  step(&controller, 1, 0, 0),
                  POWER_CONTROLLER_ACTION_PSU_ON);

    expect_action("held off-state press waits for PWR_OK",
                  step(&controller, 1, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("held off-state press still asks for no shutdown after PWR_OK",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

/* REGRESSION: a cold boot must never ask the IO Controller to shut down.
 *
 * This signal used to be ACTION_HOLD_IO_RESET, and asserting it through the
 * power-on sequence was correct for that meaning. Renaming it to a shutdown
 * request without revisiting the call sites made the PMU greet every boot with
 * "please shut down" -- and the PIC, which reaches its main loop long before
 * PWR_OK, obeyed: COMMAND_READY dropped, cache flushed, /PWR_OFF asserted,
 * spinning. The machine came up with a dead IO Controller every time.
 *
 * The old tests could not catch it because they still described the signal as
 * a reset and asserted that it WAS held during power-on. So this walks a whole
 * cold boot and insists no ASSERT ever appears. */
static void test_power_on_never_asserts_shutdown_rq(void)
{
    power_controller_t controller;
    uint16_t i;

    power_controller_init(&controller, 0, 0);

    expect_no_assert("cold-boot press", step(&controller, 1, 0, 0));
    expect_no_assert("release before rails", step(&controller, 0, 0, 0));

    /* The rails take a while. The IO Controller is booting throughout. */
    for (i = 0; i < 20; i++)
        expect_no_assert("waiting for PWR_OK", step(&controller, 0, 0, 0));

    expect_no_assert("PWR_OK arrives", step(&controller, 0, 1, 0));

    for (i = 0; i < 20; i++)
        expect_no_assert("running, button untouched", step(&controller, 0, 1, 0));
}

static void test_idle_powered_machine_emits_nothing(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("a powered idle machine is asked for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("and stays that way",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_short_press_while_powered_asserts_shutdown_rq(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("powered press holds IO reset",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    expect_action("powered release leaves IO reset held",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_short_press_does_not_turn_psu_off_without_io_reply(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("powered short press requests IO shutdown",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    expect_action("powered short release does not turn PSU off",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("PSU remains enabled while waiting for IO reply",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_io_controller_power_off_request_turns_psu_off(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    settle(&controller, 1);

    expect_action("IO Controller shutdown request turns PSU off",
                  step(&controller, 0, 1, 1),
                  POWER_CONTROLLER_ACTION_PSU_OFF);
}

/*
 * The case this grace period exists for: the IO Controller holds /PWR_OFF_RQ
 * low while it boots, because its supply has only just come up and its firmware
 * has not taken ownership of the pin. Observed on hardware as "the machine will
 * not start with the card in, and starts with it out".
 */
static void test_pwr_off_ignored_while_io_controller_boots(void)
{
    power_controller_t controller;
    uint16_t i;

    power_controller_init(&controller, 0, 0);

    /* Press while off: PSU on, rails not good yet. */
    (void)step(&controller, 1, 0, 0);

    /* Rails come good, and the IO Controller drags /PWR_OFF_RQ low for most of
     * a second while it starts. Nothing may come of that. */
    for (i = 0; i < POWER_CONTROLLER_PWR_OFF_GRACE_TICKS - 1; i++) {
        power_controller_action_t action = step(&controller, 0, 1, 1);

        if (action & POWER_CONTROLLER_ACTION_PSU_OFF) {
            printf("FAIL: PSU cut during IO Controller boot, tick %u\n",
                   (unsigned)i);
            failures++;
            break;
        }
    }

    /* The controller finishes booting and releases the line, which is what
     * arms the request. */
    (void)step(&controller, 0, 1, 0);

    /* Now a genuine request is honoured normally. */
    expect_action("shutdown request honoured after the grace period",
                  step(&controller, 0, 1, 1),
                  POWER_CONTROLLER_ACTION_PSU_OFF);
}

/*
 * The grace runs from PWR_OK, not from PMU reset. The PMU sits on the always-on
 * rail and may have been up for hours before the user pressed the button, so a
 * countdown started at its own boot would already be spent.
 */
static void test_grace_restarts_when_rails_drop(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);
    settle(&controller, 1);

    /* Rails drop and come back: the IO Controller is booting again. */
    (void)step(&controller, 0, 0, 0);

    expect_action("request ignored again after a power cycle",
                  step(&controller, 0, 1, 1),
                  POWER_CONTROLLER_ACTION_NONE);
}

/*
 * The failure this arming step exists for. A controller that never releases
 * /PWR_OFF_RQ -- absent, unflashed, or with the net held low on its card --
 * must not be able to shut the machine down, however long it holds the line.
 * Without arming the only effect of the grace period is to choose how many
 * seconds the machine runs before killing itself.
 */
static void test_pwr_off_never_released_never_powers_off(void)
{
    power_controller_t controller;
    uint16_t i;

    power_controller_init(&controller, 0, 0);
    (void)step(&controller, 1, 0, 0);           /* press while off: PSU on */

    /* Rails good, and /PWR_OFF_RQ low forever after. Ten times the grace. */
    for (i = 0; i < POWER_CONTROLLER_PWR_OFF_GRACE_TICKS * 10u; i++) {
        if (step(&controller, 0, 1, 1) & POWER_CONTROLLER_ACTION_PSU_OFF) {
            printf("FAIL: PSU cut by a request that was never released, "
                   "tick %u\n", (unsigned)i);
            failures++;
            return;
        }
    }
}

static void test_io_power_off_clears_pending_button_notification(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    settle(&controller, 1);

    expect_action("powered press arms shutdown request",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    expect_action("IO reply wins while button is held",
                  step(&controller, 1, 1, 1),
                  POWER_CONTROLLER_ACTION_PSU_OFF |
                      POWER_CONTROLLER_ACTION_DEASSERT_SHUTDOWN_RQ);

    expect_action("release after IO reply has no action",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_hold_under_force_threshold_uses_soft_shutdown_path(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("powered press starts hold timing",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    for (uint16_t tick = 1; tick < POWER_CONTROLLER_FORCE_OFF_TICKS - 1; tick++) {
        expect_action("hold under force threshold has no action",
                      step(&controller, 1, 1, 0),
                      POWER_CONTROLLER_ACTION_NONE);
    }

    expect_action("release before force threshold keeps IO reset held",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_five_second_hold_forces_psu_off(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state asks for nothing",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("powered press starts force-off timing",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    for (uint16_t tick = 1; tick < POWER_CONTROLLER_FORCE_OFF_TICKS - 1; tick++) {
        expect_action("hold before force threshold has no action",
                      step(&controller, 1, 1, 0),
                      POWER_CONTROLLER_ACTION_NONE);
    }

    expect_action("five second hold turns PSU off directly",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_PSU_OFF |
                      POWER_CONTROLLER_ACTION_DEASSERT_SHUTDOWN_RQ);

    expect_action("release after force-off has no action",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

/* A button already down when the PMU comes out of reset, on a machine whose
 * rails are already good, is a real shutdown request: power_controller_init()
 * arms it. The line is asserted on the first step -- not by init, which leaves
 * it deasserted to match the level io_init() drives. */
static void test_button_held_at_reset_is_a_shutdown_request(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 1, 1);

    expect_action("reset-held button on a powered machine requests shutdown",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_ASSERT_SHUTDOWN_RQ);

    expect_action("and the request stays up until it is served",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

int main(void)
{
    test_press_while_off_turns_psu_on_and_waits_for_pwr_ok();
    test_held_press_while_off_turns_psu_on_before_pwr_ok();
    test_power_on_never_asserts_shutdown_rq();
    test_idle_powered_machine_emits_nothing();
    test_short_press_while_powered_asserts_shutdown_rq();
    test_short_press_does_not_turn_psu_off_without_io_reply();
    test_io_controller_power_off_request_turns_psu_off();
    test_pwr_off_ignored_while_io_controller_boots();
    test_pwr_off_never_released_never_powers_off();
    test_grace_restarts_when_rails_drop();
    test_io_power_off_clears_pending_button_notification();
    test_hold_under_force_threshold_uses_soft_shutdown_path();
    test_five_second_hold_forces_psu_off();
    test_button_held_at_reset_is_a_shutdown_request();

    if (failures != 0) {
        printf("%u test assertion(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    printf("power_controller_test: all tests passed\n");
    return EXIT_SUCCESS;
}
