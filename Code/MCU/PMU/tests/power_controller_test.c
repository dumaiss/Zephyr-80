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

static void test_press_while_off_turns_psu_on_and_waits_for_pwr_ok(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 0);

    expect_action("press while off turns PSU on and holds IO reset",
                  step(&controller, 1, 0, 0),
                  POWER_CONTROLLER_ACTION_PSU_ON |
                      POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("release while PWR_OK is low keeps IO reset held",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("PWR_OK assertion releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

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
                  POWER_CONTROLLER_ACTION_PSU_ON |
                      POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("held off-state press waits for PWR_OK",
                  step(&controller, 1, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);

    expect_action("held off-state press releases IO reset after PWR_OK",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);
}

static void test_pwr_ok_releases_io_reset(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("PWR_OK releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("IO reset remains released while powered",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_short_press_while_powered_holds_io_reset(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("powered press holds IO reset",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("powered release leaves IO reset held",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_short_press_does_not_turn_psu_off_without_io_reply(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("powered short press requests IO shutdown",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

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

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("IO Controller shutdown request turns PSU off",
                  step(&controller, 0, 1, 1),
                  POWER_CONTROLLER_ACTION_PSU_OFF |
                      POWER_CONTROLLER_ACTION_HOLD_IO_RESET);
}

static void test_io_power_off_clears_pending_button_notification(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("powered press arms shutdown request",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("IO reply wins while button is held",
                  step(&controller, 1, 1, 1),
                  POWER_CONTROLLER_ACTION_PSU_OFF |
                      POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("release after IO reply has no action",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_hold_under_force_threshold_uses_soft_shutdown_path(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 0, 1);

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("powered press starts hold timing",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

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

    expect_action("initial powered state releases IO reset",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_RELEASE_IO_RESET);

    expect_action("powered press starts force-off timing",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    for (uint16_t tick = 1; tick < POWER_CONTROLLER_FORCE_OFF_TICKS - 1; tick++) {
        expect_action("hold before force threshold has no action",
                      step(&controller, 1, 1, 0),
                      POWER_CONTROLLER_ACTION_NONE);
    }

    expect_action("five second hold turns PSU off directly",
                  step(&controller, 1, 1, 0),
                  POWER_CONTROLLER_ACTION_PSU_OFF |
                      POWER_CONTROLLER_ACTION_HOLD_IO_RESET);

    expect_action("release after force-off has no action",
                  step(&controller, 0, 0, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

static void test_button_held_at_reset_keeps_io_reset_held(void)
{
    power_controller_t controller;

    power_controller_init(&controller, 1, 1);

    expect_action("release after reset-held button leaves IO reset held",
                  step(&controller, 0, 1, 0),
                  POWER_CONTROLLER_ACTION_NONE);
}

int main(void)
{
    test_press_while_off_turns_psu_on_and_waits_for_pwr_ok();
    test_held_press_while_off_turns_psu_on_before_pwr_ok();
    test_pwr_ok_releases_io_reset();
    test_short_press_while_powered_holds_io_reset();
    test_short_press_does_not_turn_psu_off_without_io_reply();
    test_io_controller_power_off_request_turns_psu_off();
    test_io_power_off_clears_pending_button_notification();
    test_hold_under_force_threshold_uses_soft_shutdown_path();
    test_five_second_hold_forces_psu_off();
    test_button_held_at_reset_keeps_io_reset_held();

    if (failures != 0) {
        printf("%u test assertion(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    printf("power_controller_test: all tests passed\n");
    return EXIT_SUCCESS;
}
