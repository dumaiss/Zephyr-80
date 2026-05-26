#include <xc.h>
#include <stdint.h>

#include "config.h"

volatile uint8_t boot_pcon0;

static void platform_init(void)
{
    INTCON0bits.GIE = 0;

    OSCCON1 = 0x60;
    OSCFRQ = 0x08;
    OSCTUNE = 0x00;

    ANSELB = 0x00;
}

static void write_reset(uint8_t asserted)
{
    HOST_RESET_LAT = asserted ? HOST_RESET_ASSERTED : HOST_RESET_IDLE;
    HOST_RESET_HIGH_LAT = asserted ? HOST_RESET_HIGH_ASSERTED : HOST_RESET_HIGH_IDLE;
}

static void boot_reset_pulse(void)
{
    HOST_RESET_ANSEL = 0;
    HOST_RESET_HIGH_ANSEL = 0;

    write_reset(1);
    HOST_RESET_TRIS = 0;
    HOST_RESET_HIGH_TRIS = 0;

    __delay_ms(100);
    write_reset(0);
}

int main(void)
{
    boot_pcon0 = PCON0;   // capture before clearing anything
    platform_init();
    boot_reset_pulse();

    for (;;) {
        NOP();
    }
}
