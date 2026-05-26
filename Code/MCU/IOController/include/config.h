#ifndef CONFIG_H
#define CONFIG_H

/* PIC18F57Q84 HFINTOSC is configured to 64 MHz in platform_init(). */
#define _XTAL_FREQ 64000000UL

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

#endif

#pragma config WDTE = OFF
#pragma config LVP = ON
