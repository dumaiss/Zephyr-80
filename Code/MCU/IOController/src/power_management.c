#include "power_management.h"

#ifndef UNIT_TEST
#include <xc.h>

#include "config.h"
#endif

/*
 * Reset the pure PMU policy state. This is separate from hardware pin setup so
 * the shutdown decision logic can be tested on the host compiler.
 */
void power_management_policy_init(power_management_t *power)
{
    power->shutdown_pending = 0;
}

/*
 * Run one step of the PMU shutdown policy. PWR_STATE starts or clears the
 * pending shutdown, host reset follows that request, and PWR_OFF_RQ waits until
 * the rest of the firmware reports no local work is busy.
 */
power_management_outputs_t power_management_step(
    power_management_t *power,
    const power_management_inputs_t *inputs)
{
    power_management_outputs_t outputs = {
        .pwr_off_rq = 0,
        .host_reset = 0,
    };

    if (inputs->pmu_reset_or_shutdown) {
        power->shutdown_pending = 1;
        outputs.host_reset = 1;
    } else {
        power->shutdown_pending = 0;
    }

    if (power->shutdown_pending && !inputs->local_work_busy) {
        outputs.pwr_off_rq = 1;
    }

    return outputs;
}

#ifndef UNIT_TEST

/*
 * Power management owns the PMU handshake and local front-panel reset/NMI
 * behavior, including the shutdown policy state machine.
 *
 * Startup path:
 * - power_management_init() configures PWR_STATE as the PMU input and
 *   PWR_OFF_RQ as the active-low response back to the PMU.
 * - Host reset is driven as a complementary pair: RB2 is active-low RESET and
 *   RB5 is RESET_HIGH. write_host_reset() is the only place that writes them so
 *   they always move together with inverse values.
 * - During IO Controller startup the host bus is held in reset for 500 ms. If
 *   PWR_STATE is still asserted after that delay, reset remains asserted.
 *
 * Runtime path:
 * - power_management_read_inputs() samples PWR_STATE. The main loop supplies
 *   local_work_busy from the subsystem that owns the outstanding work.
 * - power_management_write_outputs() applies the policy output: PWR_OFF_RQ is
 *   asserted when the IO Controller is ready for power removal, and host reset
 *   follows the controller's host_reset output.
 * - power_management_service() polls the active-low NMI_RQ momentary switch on
 *   RB3. On a new press, it pulses the host bus NMI output on RB4 low for
 *   100 ms.
 */

/*
 * Drive the complementary reset outputs together. Callers pass logical
 * "asserted"; this helper handles RB2 active-low and RB5 active-high polarity.
 */
static void write_host_reset(uint8_t asserted)
{
    HOST_RESET_LAT = asserted ? HOST_RESET_ASSERTED : HOST_RESET_IDLE;
    HOST_RESET_HIGH_LAT = asserted ? HOST_RESET_HIGH_ASSERTED : HOST_RESET_HIGH_IDLE;
}

/*
 * Generate the host bus NMI pulse requested by the enclosure momentary switch.
 * The output is active-low and held for the documented 100 ms pulse width.
 */
static void pulse_bus_nmi(void)
{
    BUS_NMI_LAT = BUS_NMI_ASSERTED;
    __delay_ms(100);
    BUS_NMI_LAT = BUS_NMI_IDLE;
}

/*
 * Configure PMU handshake pins, reset/NMI pins, and the startup reset hold.
 * Host reset is asserted before the output drivers are enabled.
 */
void power_management_init(void)
{
    PWR_STATE_ANSEL = 0;
    PWR_STATE_TRIS = 1;

    PWR_OFF_RQ_ANSEL = 0;
    PWR_OFF_RQ_LAT = PWR_OFF_RQ_IDLE;
    PWR_OFF_RQ_TRIS = 0;

    NMI_RQ_ANSEL = 0;
    NMI_RQ_WPU = 1;
    NMI_RQ_TRIS = 1;

    BUS_NMI_ANSEL = 0;
    BUS_NMI_LAT = BUS_NMI_IDLE;
    BUS_NMI_TRIS = 0;

    HOST_RESET_ANSEL = 0;
    HOST_RESET_HIGH_ANSEL = 0;
    write_host_reset(1);
    HOST_RESET_TRIS = 0;
    HOST_RESET_HIGH_TRIS = 0;
    __delay_ms(500);
    if (PWR_STATE_PORT != PWR_STATE_ASSERTED) {
        write_host_reset(0);
    }
}

/*
 * Sample PMU-facing inputs for the policy state machine. Other subsystems fill
 * in local_work_busy after this returns.
 */
power_management_inputs_t power_management_read_inputs(void)
{
    power_management_inputs_t inputs = {
        .pmu_reset_or_shutdown = PWR_STATE_PORT == PWR_STATE_ASSERTED,
        .local_work_busy = 0,
    };

    return inputs;
}

/*
 * Apply one policy output step to the hardware pins: PWR_OFF_RQ to the PMU and
 * the complementary host reset pair to the bus.
 */
void power_management_write_outputs(const power_management_outputs_t *outputs)
{
    PWR_OFF_RQ_LAT = outputs->pwr_off_rq ? PWR_OFF_RQ_ASSERTED : PWR_OFF_RQ_IDLE;
    write_host_reset(outputs->host_reset);
}

/*
 * Poll the front-panel NMI request switch and turn each new press into one NMI
 * pulse on the host bus.
 */
void power_management_service(void)
{
    static uint8_t nmi_rq_was_asserted;
    const uint8_t nmi_rq_asserted = NMI_RQ_PORT == NMI_RQ_ASSERTED;

    if (nmi_rq_asserted && !nmi_rq_was_asserted) {
        pulse_bus_nmi();
    }

    nmi_rq_was_asserted = nmi_rq_asserted;
}

#endif
