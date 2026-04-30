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

#endif
