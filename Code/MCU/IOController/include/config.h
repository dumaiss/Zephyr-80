#ifndef CONFIG_H
#define CONFIG_H

/*
 * PIC18F57Q84 default clock placeholder.
 *
 * Update this value with the final oscillator configuration before enabling
 * delay-based peripheral drivers.
 */
#define _XTAL_FREQ 64000000UL

/*
 * PMU power-management handshake pins.
 *
 * PWR_STATE is driven by the PMU. High means the IO Controller should hold the
 * system in reset or initiate shutdown work.
 *
 * PWR_OFF_RQ is driven by the IO Controller back to the PMU. The board signal
 * is active low, so asserting the state-machine output drives RB1 low.
 */
#define PWR_STATE_TRIS      TRISBbits.TRISB0
#define PWR_STATE_ANSEL     ANSELBbits.ANSELB0
#define PWR_STATE_PORT      PORTBbits.RB0
#define PWR_STATE_ASSERTED  1

#define PWR_OFF_RQ_TRIS     TRISBbits.TRISB1
#define PWR_OFF_RQ_ANSEL    ANSELBbits.ANSELB1
#define PWR_OFF_RQ_LAT      LATBbits.LATB1
#define PWR_OFF_RQ_ASSERTED 0
#define PWR_OFF_RQ_IDLE     1

#define HOST_RESET_TRIS     TRISBbits.TRISB2
#define HOST_RESET_ANSEL    ANSELBbits.ANSELB2
#define HOST_RESET_LAT      LATBbits.LATB2
#define HOST_RESET_ASSERTED 0
#define HOST_RESET_IDLE     1

#define HOST_RESET_HIGH_TRIS     TRISBbits.TRISB5
#define HOST_RESET_HIGH_ANSEL    ANSELBbits.ANSELB5
#define HOST_RESET_HIGH_LAT      LATBbits.LATB5
#define HOST_RESET_HIGH_ASSERTED 1
#define HOST_RESET_HIGH_IDLE     0

#define NMI_RQ_TRIS      TRISBbits.TRISB3
#define NMI_RQ_ANSEL     ANSELBbits.ANSELB3
#define NMI_RQ_WPU       WPUBbits.WPUB3
#define NMI_RQ_PORT      PORTBbits.RB3
#define NMI_RQ_ASSERTED  0

#define BUS_NMI_TRIS     TRISBbits.TRISB4
#define BUS_NMI_ANSEL    ANSELBbits.ANSELB4
#define BUS_NMI_LAT      LATBbits.LATB4
#define BUS_NMI_ASSERTED 0
#define BUS_NMI_IDLE     1

#define CS_SIO_SD_TRIS     TRISAbits.TRISA0
#define CS_SIO_SD_ANSEL    ANSELAbits.ANSELA0
#define CS_SIO_SD_PORT     PORTAbits.RA0
#define CS_SIO_SD_ASSERTED 0

#define CS_SIO_USB_TRIS     TRISAbits.TRISA1
#define CS_SIO_USB_ANSEL    ANSELAbits.ANSELA1
#define CS_SIO_USB_PORT     PORTAbits.RA1
#define CS_SIO_USB_ASSERTED 0

#define USB_INT_TRIS     TRISAbits.TRISA2
#define USB_INT_ANSEL    ANSELAbits.ANSELA2
#define USB_INT_PORT     PORTAbits.RA2
#define USB_INT_ASSERTED 0

#define USB_CS_TRIS     TRISAbits.TRISA3
#define USB_CS_ANSEL    ANSELAbits.ANSELA3
#define USB_CS_LAT      LATAbits.LATA3
#define USB_CS_ASSERTED 0
#define USB_CS_IDLE     1

#define SD_CS_TRIS     TRISAbits.TRISA4
#define SD_CS_ANSEL    ANSELAbits.ANSELA4
#define SD_CS_LAT      LATAbits.LATA4
#define SD_CS_ASSERTED 0
#define SD_CS_IDLE     1

#define SPI_MOSI_TRIS  TRISAbits.TRISA5
#define SPI_MOSI_ANSEL ANSELAbits.ANSELA5

#define SPI_MISO_TRIS  TRISAbits.TRISA6
#define SPI_MISO_ANSEL ANSELAbits.ANSELA6

#define SPI_CLK_TRIS  TRISAbits.TRISA7
#define SPI_CLK_ANSEL ANSELAbits.ANSELA7

#define SIO_USB_RTS_TRIS     TRISFbits.TRISF1
#define SIO_USB_RTS_ANSEL    ANSELFbits.ANSELF1
#define SIO_USB_RTS_PORT     PORTFbits.RF1
#define SIO_USB_RTS_ASSERTED 0
#define SIO_USB_RTS_IOCN     IOCFNbits.IOCFN1
#define SIO_USB_RTS_IOCF     IOCFFbits.IOCFF1

#define SIO_SD_RTS_TRIS     TRISFbits.TRISF2
#define SIO_SD_RTS_ANSEL    ANSELFbits.ANSELF2
#define SIO_SD_RTS_PORT     PORTFbits.RF2
#define SIO_SD_RTS_ASSERTED 0
#define SIO_SD_RTS_IOCN     IOCFNbits.IOCFN2
#define SIO_SD_RTS_IOCF     IOCFFbits.IOCFF2

#define SIO_RTS_IOCIE PIE0bits.IOCIE
#define SIO_RTS_IOCIF PIR0bits.IOCIF

#endif
