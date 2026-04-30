#include <xc.h>

#include "config.h"
#include "io_controller.h"

#define PPS_RA2 0x02
#define PPS_RA5 0x05
#define PPS_RA6 0x06
#define PPS_RA7 0x07

#define PPS_SPI1_SCK 0x31
#define PPS_SPI1_SDO 0x32

#define USB_INT_ANSEL ANSELAbits.ANSELA2
#define USB_INT_TRIS  TRISAbits.TRISA2

#define USB_CS_ANSEL ANSELAbits.ANSELA3
#define USB_CS_TRIS  TRISAbits.TRISA3
#define USB_CS_LAT   LATAbits.LATA3

#define SD_CS_ANSEL ANSELAbits.ANSELA4
#define SD_CS_TRIS  TRISAbits.TRISA4
#define SD_CS_LAT   LATAbits.LATA4

#define SPI_MOSI_ANSEL ANSELAbits.ANSELA5
#define SPI_MOSI_TRIS  TRISAbits.TRISA5

#define SPI_MISO_ANSEL ANSELAbits.ANSELA6
#define SPI_MISO_TRIS  TRISAbits.TRISA6

#define SPI_CLK_ANSEL ANSELAbits.ANSELA7
#define SPI_CLK_TRIS  TRISAbits.TRISA7

#define SD_PRESENT_ANSEL ANSELFbits.ANSELF4
#define SD_PRESENT_TRIS  TRISFbits.TRISF4

#define SD_BUSY_ANSEL ANSELFbits.ANSELF5
#define SD_BUSY_TRIS  TRISFbits.TRISF5
#define SD_BUSY_LAT   LATFbits.LATF5

static void write_host_reset(uint8_t asserted)
{
    HOST_RESET_LAT = asserted ? HOST_RESET_ASSERTED : HOST_RESET_IDLE;
    HOST_RESET_HIGH_LAT = asserted ? HOST_RESET_HIGH_ASSERTED : HOST_RESET_HIGH_IDLE;
}

static void pulse_bus_nmi(void)
{
    BUS_NMI_LAT = BUS_NMI_ASSERTED;
    __delay_ms(100);
    BUS_NMI_LAT = BUS_NMI_IDLE;
}

static void service_nmi_request(void)
{
    static uint8_t nmi_rq_was_asserted;
    const uint8_t nmi_rq_asserted = NMI_RQ_PORT == NMI_RQ_ASSERTED;

    if (nmi_rq_asserted && !nmi_rq_was_asserted) {
        pulse_bus_nmi();
    }

    nmi_rq_was_asserted = nmi_rq_asserted;
}

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

    LATA = 0x18;
    LATB = 0x00;
    LATC = 0x00;
    LATD = 0x00;
    LATE = 0x00;
    LATF = 0x00;

    TRISA = 0x47;
    TRISB = 0xFF;
    TRISC = 0xFF;
    TRISD = 0xFF;
    TRISE = 0xFF;
    TRISF = 0xDF;

    USB_INT_ANSEL = 0;
    USB_INT_TRIS = 1;
    USB_CS_ANSEL = 0;
    USB_CS_LAT = 1;
    USB_CS_TRIS = 0;
    SD_CS_ANSEL = 0;
    SD_CS_LAT = 1;
    SD_CS_TRIS = 0;

    SPI_MOSI_ANSEL = 0;
    SPI_MOSI_TRIS = 0;
    SPI_MISO_ANSEL = 0;
    SPI_MISO_TRIS = 1;
    SPI_CLK_ANSEL = 0;
    SPI_CLK_TRIS = 0;

    SD_PRESENT_ANSEL = 0;
    SD_PRESENT_TRIS = 1;
    SD_BUSY_ANSEL = 0;
    SD_BUSY_LAT = 0;
    SD_BUSY_TRIS = 0;

    PPSLOCK = 0x55;
    PPSLOCK = 0xAA;
    PPSLOCKbits.PPSLOCKED = 0;

    RA5PPS = PPS_SPI1_SDO;
    RA7PPS = PPS_SPI1_SCK;
    SPI1SCKPPS = PPS_RA7;
    SPI1SDIPPS = PPS_RA6;

    PPSLOCK = 0x55;
    PPSLOCK = 0xAA;
    PPSLOCKbits.PPSLOCKED = 1;

    U1CON0 = 0x00;
    U1CON1 = 0x00;
    U1CON2 = 0x00;
    U1BRG = (_XTAL_FREQ / (16UL * 115200UL)) - 1UL;

    SPI1CON0 = 0x00;
    SPI1CON1 = 0x10;
    SPI1CON2 = 0x03;
    SPI1CLK = 0x00;
    SPI1BAUD = 0x00;
    SPI1CON0 = 0x82;

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

static io_controller_inputs_t read_inputs(void)
{
    io_controller_inputs_t inputs = {
        .pmu_reset_or_shutdown = PWR_STATE_PORT == PWR_STATE_ASSERTED,

        /*
         * TODO: replace busy placeholders with real SD/filesystem and USB HID
         * activity tracking.
         */
        .storage_busy = 0,
        .usb_busy = 0,
    };

    return inputs;
}

static void write_outputs(const io_controller_outputs_t *outputs)
{
    PWR_OFF_RQ_LAT = outputs->pwr_off_rq ? PWR_OFF_RQ_ASSERTED : PWR_OFF_RQ_IDLE;
    write_host_reset(outputs->host_reset);
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
        service_nmi_request();
    }
}
