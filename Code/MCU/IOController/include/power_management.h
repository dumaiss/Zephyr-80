#ifndef POWER_MANAGEMENT_H
#define POWER_MANAGEMENT_H

#include <stdint.h>

typedef struct {
    uint8_t pmu_reset_or_shutdown;
    uint8_t local_work_busy;
} power_management_inputs_t;

typedef struct {
    uint8_t pwr_off_rq;
    uint8_t host_reset;
} power_management_outputs_t;

typedef struct {
    uint8_t shutdown_pending;
} power_management_t;

void power_management_policy_init(power_management_t *power);
power_management_outputs_t power_management_step(
    power_management_t *power,
    const power_management_inputs_t *inputs);

void power_management_init(void);
power_management_inputs_t power_management_read_inputs(void);
void power_management_write_outputs(const power_management_outputs_t *outputs);
void power_management_service(void);

#endif
