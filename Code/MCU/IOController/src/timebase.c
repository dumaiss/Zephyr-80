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

/* ---------------------------------------------------------------------------
 * Microsecond phase profiler.  See timebase.h.
 * --------------------------------------------------------------------------- */

static uint32_t uprof_acc[UPROF_SLOTS];

void uprof_init(void)
{
    uint8_t i;

    T1CON = 0x00;             /* stop while reconfiguring */
    T1CLK = 0x01;             /* CS = 00001 -> FOSC/4 = 16 MHz */
    T1CONbits.CKPS = 0b11;    /* 1:8 prescale -> 2 MHz, 0.5 us per tick */
    T1CONbits.RD16 = 1;       /* atomic 16-bit reads via the H latch */
    TMR1H = 0x00;
    TMR1L = 0x00;

    for (i = 0u; i < UPROF_SLOTS; i++)
        uprof_acc[i] = 0uL;

    T1CONbits.ON = 1;
}

uint16_t uprof_now(void)
{
    uint8_t lo, hi;

    /* RD16 is set, so reading TMR1L latches TMR1H.  Low byte FIRST or the two
     * halves can come from different counter values. */
    lo = TMR1L;
    hi = TMR1H;

    return (uint16_t)(((uint16_t)hi << 8) | lo);
}

void uprof_add(uint8_t slot, uint16_t start)
{
    /* Unsigned 16-bit subtraction, so a wrap between start and now still gives
     * the right span as long as it is under 32.7 ms. */
    uprof_acc[slot] += (uint32_t)(uint16_t)(uprof_now() - start);
}

uint16_t uprof_ms(uint8_t slot)
{
    uint32_t ms = uprof_acc[slot] / 2000uL;   /* 0.5 us ticks -> ms */

    return (ms > 0xFFFFuL) ? 0xFFFFu : (uint16_t)ms;
}
