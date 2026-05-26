#include <stdint.h>

#include <util/delay.h>

#include "config.h"
#include "power_controller.h"

static void psu_off(void);

/*
 * Configure the PMU GPIO.
 *
 * Active-low external inputs use internal pull-ups. PWR_OK is left without an
 * internal pull-up because it is driven by the ATX PSU. Outputs start with the
 * IO Controller held in reset and the PSU disabled.
 */
static void io_init(void)
{
#if !PMU_IGNORE_IO_CONTROLLER_SIGNALS
    PWR_OFF_RQ_DDR &= ~_BV(PWR_OFF_RQ_PIN);
    PWR_OFF_RQ_PORT |= _BV(PWR_OFF_RQ_PIN);
#endif

    PWR_SW_DDR &= ~_BV(PWR_SW_PIN);
    PWR_SW_PORT |= _BV(PWR_SW_PIN);

    PWR_OK_DDR &= ~_BV(PWR_OK_PIN);
    PWR_OK_PORT &= ~_BV(PWR_OK_PIN);

#if !PMU_IGNORE_IO_CONTROLLER_SIGNALS
    PWR_STATE_DDR |= _BV(PWR_STATE_PIN);
    PWR_STATE_PORT |= _BV(PWR_STATE_PIN);
#else
    PWR_STATE_DDR &= ~_BV(PWR_STATE_PIN);
    PWR_STATE_PORT &= ~_BV(PWR_STATE_PIN);
#endif

    PS_ON_DDR |= _BV(PS_ON_PIN);
    psu_off();
}

static uint8_t pwr_off_requested(void)
{
    /* PWR_OFF_RQ is asserted by the IO Controller when low. */
#if PMU_IGNORE_IO_CONTROLLER_SIGNALS
    return 0;
#else
    return (PWR_OFF_RQ_PINR & _BV(PWR_OFF_RQ_PIN)) == 0;
#endif
}

static uint8_t pwr_switch_pressed(void)
{
    /* The enclosure power switch shorts the input low when pressed. */
    return (PWR_SW_PINR & _BV(PWR_SW_PIN)) == 0;
}

static uint8_t pwr_ok(void)
{
    /* ATX PWR_OK is high when the supply reports stable outputs. */
    return (PWR_OK_PINR & _BV(PWR_OK_PIN)) != 0;
}

static void psu_on(void)
{
    /* Enable the MOSFET so ATX PS_ON# is pulled low. */
#if PS_ON_MOSFET_ON_LEVEL
    PS_ON_PORT |= _BV(PS_ON_PIN);
#else
    PS_ON_PORT &= ~_BV(PS_ON_PIN);
#endif
}

static void psu_off(void)
{
    /* Disable the MOSFET so ATX PS_ON# is released inactive. */
#if PS_ON_MOSFET_OFF_LEVEL
    PS_ON_PORT |= _BV(PS_ON_PIN);
#else
    PS_ON_PORT &= ~_BV(PS_ON_PIN);
#endif
}

static void hold_io_reset(void)
{
    /* PWR_STATE high tells the IO Controller to hold the system in reset. */
#if !PMU_IGNORE_IO_CONTROLLER_SIGNALS
    PWR_STATE_PORT |= _BV(PWR_STATE_PIN);
#endif
}

static void release_io_reset(void)
{
    /* PWR_STATE low tells the IO Controller that the system may run. */
#if !PMU_IGNORE_IO_CONTROLLER_SIGNALS
    PWR_STATE_PORT &= ~_BV(PWR_STATE_PIN);
#endif
}

static void apply_controller_action(power_controller_action_t action)
{
    if (action & POWER_CONTROLLER_ACTION_PSU_ON) {
        psu_on();
    }

    if (action & POWER_CONTROLLER_ACTION_PSU_OFF) {
        psu_off();
    }

    if (action & POWER_CONTROLLER_ACTION_HOLD_IO_RESET) {
        hold_io_reset();
    }

    if (action & POWER_CONTROLLER_ACTION_RELEASE_IO_RESET) {
        release_io_reset();
    }
}

int main(void)
{
    power_controller_t controller;

    io_init();
    power_controller_init(&controller, pwr_switch_pressed(), pwr_ok());

    for (;;) {
        const power_controller_inputs_t inputs = {
            .pwr_switch_pressed = pwr_switch_pressed(),
            .pwr_ok = pwr_ok(),
            .pwr_off_requested = pwr_off_requested(),
        };

        apply_controller_action(power_controller_step(&controller, &inputs));
        _delay_ms(POLL_INTERVAL_MS);
    }
}
