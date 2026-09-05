#include <xc.h>
#include <stdbool.h>

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

#if IOC_DIAGNOSTIC_BUILD
static uint32_t uprof_acc[UPROF_SLOTS];
static bool     uprof_reset_pending;

static void uprof_clear(void)
{
    uint8_t i;

    for (i = 0u; i < UPROF_SLOTS; i++)
        uprof_acc[i] = 0uL;
}
#endif

void uprof_init(void)
{
    /* Timer1 belongs to external_sync.c: it is reconfigured to count physical
     * RB3/SCK edges on every command transaction.  Sharing it made every
     * profile bracket that crossed a receive or reply deterministic nonsense.
     *
     * Timer3 is otherwise unused.  LFINTOSC gives about 31 kHz (32 us/tick)
     * and a 2.1 second 16-bit period, long enough for SD initialisation and the
     * card's worst permitted write-busy interval without rollover. */
    T3CON = 0x00;             /* stop while reconfiguring */
    T3CLK = 0x04;             /* CS = 00100 -> LFINTOSC, nominally 31 kHz */
    T3CONbits.CKPS = 0b00;    /* 1:1 prescale */
    T3CONbits.RD16 = 1;       /* atomic 16-bit reads via the H latch */
    TMR3H = 0x00;
    TMR3L = 0x00;

#if IOC_DIAGNOSTIC_BUILD
    uprof_clear();
    uprof_reset_pending = false;
#endif

    /* Timer3 runs in every build: uprof_now() is the time source bulk_channel's
     * bounded wait for host RTS depends on, not a profiling facility. */
    T3CONbits.ON = 1;
}

uint16_t uprof_now(void)
{
    uint8_t lo, hi;

    /* RD16 is set, so reading TMR3L latches TMR3H.  Low byte FIRST or the two
     * halves can come from different counter values. */
    lo = TMR3L;
    hi = TMR3H;

    return (uint16_t)(((uint16_t)hi << 8) | lo);
}

#if IOC_DIAGNOSTIC_BUILD

void uprof_add(uint8_t slot, uint16_t start)
{
    /* Unsigned 16-bit subtraction, so a wrap between start and now still gives
     * the right span as long as it is under 2.1 seconds. */
    uprof_acc[slot] += (uint32_t)(uint16_t)(uprof_now() - start);
}

uint16_t uprof_ms(uint8_t slot)
{
    uint32_t ms = uprof_acc[slot] / 31uL;   /* nominal 31 kHz -> ms */

    return (ms > 0xFFFFuL) ? 0xFFFFu : (uint16_t)ms;
}

void uprof_request_reset(void)
{
    /* Deferred until the command has completely replied.  Clearing inside
     * handler_profile() would immediately add that command's SEND and TOTAL
     * time to an otherwise empty benchmark interval. */
    uprof_reset_pending = true;
}

void uprof_apply_pending_reset(void)
{
    if (!uprof_reset_pending)
        return;

    uprof_clear();
    uprof_reset_pending = false;
}

#endif /* IOC_DIAGNOSTIC_BUILD */
