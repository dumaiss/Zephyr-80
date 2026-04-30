#include <xc.h>

#include "config.h"
#include "power_management.h"
#include "spi_management.h"

#define SD_PRESENT_ANSEL ANSELFbits.ANSELF4
#define SD_PRESENT_TRIS  TRISFbits.TRISF4

#define SD_BUSY_ANSEL ANSELFbits.ANSELF5
#define SD_BUSY_TRIS  TRISFbits.TRISF5
#define SD_BUSY_LAT   LATFbits.LATF5

static void platform_init(void)
{
    INTCON0bits.GIE = 0;

    OSCCON1 = 0x60;
    OSCFRQ = 0x08;
    OSCTUNE = 0x00;

    ANSELA = 0x00;
    ANSELB = 0x00;
    ANSELC = 0x00;
    ANSELD = 0x00;
    ANSELE = 0x00;
    ANSELF = 0x00;

    LATA = 0x1B;
    LATB = 0x00;
    LATC = 0x00;
    LATD = 0x00;
    LATE = 0x00;
    LATF = 0x00;

    TRISA = 0xFF;
    TRISB = 0xFF;
    TRISC = 0xFF;
    TRISD = 0xFF;
    TRISE = 0xFF;
    TRISF = 0xDF;

    SD_PRESENT_ANSEL = 0;
    SD_PRESENT_TRIS = 1;
    SD_BUSY_ANSEL = 0;
    SD_BUSY_LAT = 0;
    SD_BUSY_TRIS = 0;

    U1CON0 = 0x00;
    U1CON1 = 0x00;
    U1CON2 = 0x00;
    U1BRG = (_XTAL_FREQ / (16UL * 115200UL)) - 1UL;

    PIE0 = 0x00;
    PIE1 = 0x00;
    PIE2 = 0x00;
    PIE3 = 0x00;
    PIE4 = 0x00;
    PIE5 = 0x00;
    PIE6 = 0x00;
    PIE7 = 0x00;
    PIR0 = 0x00;
    PIR1 = 0x00;
    PIR2 = 0x00;
    PIR3 = 0x00;
    PIR4 = 0x00;
    PIR5 = 0x00;
    PIR6 = 0x00;
    PIR7 = 0x00;

    spi_management_init();
    power_management_init();
}

int main(void)
{
    power_management_t power;

    platform_init();
    power_management_policy_init(&power);

    for (;;) {
        power_management_inputs_t inputs = power_management_read_inputs();
        inputs.local_work_busy = spi_management_busy();
        const power_management_outputs_t outputs =
            power_management_step(&power, &inputs);

        power_management_write_outputs(&outputs);
        power_management_service();
        spi_management_service();
    }
}
