#include <stdio.h>
#include <stdlib.h>

#include "power_management.h"

static unsigned failures;

static power_management_outputs_t step(power_management_t *power,
                                       uint8_t pmu_reset_or_shutdown,
                                       uint8_t local_work_busy)
{
    const power_management_inputs_t inputs = {
        .pmu_reset_or_shutdown = pmu_reset_or_shutdown,
        .local_work_busy = local_work_busy,
    };

    return power_management_step(power, &inputs);
}

static void expect_pwr_off_rq(const char *test_name,
                              power_management_outputs_t outputs,
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

static void expect_host_reset(const char *test_name,
                              power_management_outputs_t outputs,
                              uint8_t expected)
{
    if (outputs.host_reset != expected) {
        printf("FAIL: %s: expected host_reset=%u, got %u\n",
               test_name,
               expected,
               outputs.host_reset);
        failures++;
    }
}

static void test_idle_controller_does_not_request_power_off(void)
{
    power_management_t power;
    power_management_outputs_t outputs;

    power_management_policy_init(&power);
    outputs = step(&power, 0, 0);

    expect_pwr_off_rq("idle run state has no power-off request",
                      outputs,
                      0);
    expect_host_reset("idle run state leaves host reset released",
                      outputs,
                      0);
}

static void test_shutdown_request_asserts_when_idle(void)
{
    power_management_t power;
    power_management_outputs_t outputs;

    power_management_policy_init(&power);
    outputs = step(&power, 1, 0);

    expect_pwr_off_rq("shutdown request asserts power-off when idle",
                      outputs,
                      1);
    expect_host_reset("shutdown request asserts host reset",
                      outputs,
                      1);
}

static void test_host_reset_follows_pmu_request_while_busy(void)
{
    power_management_t power;
    power_management_outputs_t outputs;

    power_management_policy_init(&power);
    outputs = step(&power, 1, 1);

    expect_pwr_off_rq("busy shutdown delays power-off request",
                      outputs,
                      0);
    expect_host_reset("busy shutdown keeps host reset asserted",
                      outputs,
                      1);
}

static void test_shutdown_waits_for_local_work_to_drain(void)
{
    power_management_t power;

    power_management_policy_init(&power);

    expect_pwr_off_rq("local work busy delays power-off request",
                      step(&power, 1, 1),
                      0);

    expect_pwr_off_rq("local work idle allows power-off request",
                      step(&power, 1, 0),
                      1);
}

static void test_run_state_clears_pending_shutdown(void)
{
    power_management_t power;

    power_management_policy_init(&power);

    expect_pwr_off_rq("shutdown request starts pending state",
                      step(&power, 1, 1),
                      0);

    expect_pwr_off_rq("run state clears pending shutdown",
                      step(&power, 0, 0),
                      0);
    expect_host_reset("run state releases host reset",
                      step(&power, 0, 0),
                      0);

    expect_pwr_off_rq("remaining in run state stays clear",
                      step(&power, 0, 0),
                      0);
}

int main(void)
{
    test_idle_controller_does_not_request_power_off();
    test_shutdown_request_asserts_when_idle();
    test_host_reset_follows_pmu_request_while_busy();
    test_shutdown_waits_for_local_work_to_drain();
    test_run_state_clears_pending_shutdown();

    if (failures != 0) {
        printf("%u test assertion(s) failed\n", failures);
        return EXIT_FAILURE;
    }

    printf("io_controller_test: all tests passed\n");
    return EXIT_SUCCESS;
}
