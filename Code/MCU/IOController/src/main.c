#include <xc.h>

#include "config.h"
#include "io_controller.h"

static void platform_init(void)
{
    /*
     * TODO: configure PIC18F57Q84 oscillator, PPS, GPIO directions, UART/SPI,
     * interrupts, and peripheral chip-select defaults.
     */
}

static io_controller_inputs_t read_inputs(void)
{
    io_controller_inputs_t inputs = {
        /*
         * TODO: replace placeholders with real port reads.
         *
         * pmu_hold_reset: PWR_STATE from PMU, high means hold/reset/shutdown.
         * storage_busy: SD/filesystem operation in progress.
         * usb_busy: USB HID or MAX3421E operation in progress.
         */
        .pmu_hold_reset = 0,
        .storage_busy = 0,
        .usb_busy = 0,
    };

    return inputs;
}

static void write_outputs(const io_controller_outputs_t *outputs)
{
    (void)outputs;

    /*
     * TODO: drive PWR_OFF_RQ output to the PMU. The state machine uses 1 for
     * asserted; adapt here if the board signal is active low.
     */
}

int main(void)
{
    io_controller_t controller;

    platform_init();
    io_controller_init(&controller);

    for (;;) {
        const io_controller_inputs_t inputs = read_inputs();
        const io_controller_outputs_t outputs =
            io_controller_step(&controller, &inputs);

        write_outputs(&outputs);
    }
}
