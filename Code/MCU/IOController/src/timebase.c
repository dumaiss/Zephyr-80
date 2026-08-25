#include <xc.h>

#include "timebase.h"

static volatile uint16_t ticks;

/* Timer2 produces a 10 ms tick:
 *
 *   FOSC/4 = 16 MHz, 1:128 prescale         -> 125 kHz
 *   T2PR = 249, so the period is 250 counts -> 500 Hz
 *   1:5 postscale                           -> 100 Hz = 10 ms
 */
void timebase_init(void)
{
    T2CON = 0x00;             /* stop the timer while it is reconfigured */
    T2CLKCON = 0x01;          /* CS = 00001 -> FOSC/4 = 16 MHz */
    T2HLT = 0x00;             /* free running, software gated */
    T2PR = 249u;              /* restarts at 0 on reaching PR -> 250 counts */
    T2TMR = 0x00;

    T2CONbits.CKPS  = 0b111;  /* 1:128 prescale  -> 125 kHz */
    T2CONbits.OUTPS = 0b0100; /* 1:5 postscale   -> 100 Hz = 10 ms */

    ticks = 0u;

    PIR3bits.TMR2IF = 0;
    T2CONbits.ON = 1;
}

void timebase_poll(void)
{
    if (!PIR3bits.TMR2IF)
        return;

    PIR3bits.TMR2IF = 0;
    ticks++;
}

uint16_t timebase_ticks(void)
{
    return ticks;
}
