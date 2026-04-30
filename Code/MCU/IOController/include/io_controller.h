#ifndef IO_CONTROLLER_H
#define IO_CONTROLLER_H

#include <stdint.h>

typedef struct {
    uint8_t pmu_reset_or_shutdown;
    uint8_t storage_busy;
    uint8_t usb_busy;
} io_controller_inputs_t;

typedef struct {
    uint8_t pwr_off_rq;
    uint8_t host_reset;
} io_controller_outputs_t;

typedef struct {
    uint8_t shutdown_pending;
} io_controller_t;

void io_controller_init(io_controller_t *controller);

io_controller_outputs_t io_controller_step(
    io_controller_t *controller,
    const io_controller_inputs_t *inputs);

#endif
