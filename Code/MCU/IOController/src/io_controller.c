#include "io_controller.h"

void io_controller_init(io_controller_t *controller)
{
    controller->shutdown_pending = 0;
}

io_controller_outputs_t io_controller_step(
    io_controller_t *controller,
    const io_controller_inputs_t *inputs)
{
    io_controller_outputs_t outputs = {
        .pwr_off_rq = 0,
        .host_reset = 0,
    };

    /*
     * PWR_STATE high from the PMU means the IO Controller should hold the
     * system in reset or initiate shutdown work.
     */
    if (inputs->pmu_reset_or_shutdown) {
        controller->shutdown_pending = 1;
        outputs.host_reset = 1;
    } else {
        controller->shutdown_pending = 0;
    }

    /*
     * Request power-off only after local work has drained. The busy flags are
     * placeholders for SD, USB, filesystem, or buffered serial activity.
     */
    if (controller->shutdown_pending &&
        !inputs->storage_busy &&
        !inputs->usb_busy) {
        outputs.pwr_off_rq = 1;
    }

    return outputs;
}
