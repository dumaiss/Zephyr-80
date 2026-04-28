#include <stdio.h>
#include <stdlib.h>

#include "io_controller.h"

static unsigned failures;

static io_controller_outputs_t step(io_controller_t *controller,
                                    uint8_t pmu_hold_reset,
                                    uint8_t storage_busy,
                                    uint8_t usb_busy)
{
    const io_controller_inputs_t inputs = {
        .pmu_hold_reset = pmu_hold_reset,
        .storage_busy = storage_busy,
        .usb_busy = usb_busy,
    };

    return io_controller_step(controller, &inputs);
}

static void expect_pwr_off_rq(const char *test_name,
                              io_controller_outputs_t outputs,
                              uint8_t expected)
{
    if (outputs.pwr_off_rq != expected) {
        printf("FAIL: %s: expected pwr_off_rq=%u, got %u\n",
               test_name,
               expected,
               outputs.pwr_off_rq);
        failures++;
    }
}

static void test_idle_controller_does_not_request_power_off(void)
{
    io_controller_t controller;

    io_controller_init(&controller);

    expect_pwr_off_rq("idle run state has no power-off request",
                      step(&controller, 0, 0, 0),
                      0);
}

static void test_shutdown_request_asserts_when_idle(void)
{
    io_controller_t controller;

    io_controller_init(&controller);

    expect_pwr_off_rq("shutdown request asserts power-off when idle",
                      step(&controller, 1, 0, 0),
                      1);
}

static void test_shutdown_waits_for_storage_to_drain(void)
{
    io_controller_t controller;

    io_controller_init(&controller);

    expect_pwr_off_rq("storage busy delays power-off request",
                      step(&controller, 1, 1, 0),
                      0);

    expect_pwr_off_rq("storage idle allows power-off request",
                      step(&controller, 1, 0, 0),
                      1);
}

static void test_shutdown_waits_for_usb_to_drain(void)
{
    io_controller_t controller;

    io_controller_init(&controller);

    expect_pwr_off_rq("usb busy delays power-off request",
                      step(&controller, 1, 0, 1),
                      0);

    expect_pwr_off_rq("usb idle allows power-off request",
                      step(&controller, 1, 0, 0),
                      1);
}

static void test_run_state_clears_pending_shutdown(void)
{
    io_controller_t controller;

    io_controller_init(&controller);

    expect_pwr_off_rq("shutdown request starts pending state",
                      step(&controller, 1, 1, 0),
                      0);

    expect_pwr_off_rq("run state clears pending shutdown",
                      step(&controller, 0, 0, 0),
                      0);

    expect_pwr_off_rq("remaining in run state stays clear",
                      step(&controller, 0, 0, 0),
                      0);
}

int main(void)
{
    test_idle_controller_does_not_request_power_off();
    test_shutdown_request_asserts_when_idle();
    test_shutdown_waits_for_storage_to_drain();
    test_shutdown_waits_for_usb_to_drain();
    test_run_state_clears_pending_shutdown();

    if (failures != 0) {
        printf("%u test assertion(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    printf("io_controller_test: all tests passed\n");
    return EXIT_SUCCESS;
}
