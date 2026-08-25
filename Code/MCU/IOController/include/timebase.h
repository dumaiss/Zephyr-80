#ifndef TIMEBASE_H
#define TIMEBASE_H

#include <stdint.h>

/* Shared 10 ms tick, sourced from Timer2.
 *
 * This module exists because Timer2's rollover flag can only be consumed once.
 * The controller latch used to poll and clear PIR3bits.TMR2IF directly, which
 * was fine while it was the only consumer.  The SD cache flush timer is a
 * second consumer, and two pollers of one flag means whichever runs first eats
 * the other's tick -- silently, and at a rate that depends on how long the
 * previous command took.  One owner, a free-running counter, and everyone else
 * compares against it.
 *
 * The counter is polled, not interrupt driven, and only advances when
 * timebase_poll() runs.  The main loop is single-threaded and a command
 * transaction runs to completion, so ticks are not observed during one; a long
 * SD access simply means several tick periods elapse and the counter jumps by
 * more than one.  Every consumer must therefore compare elapsed time rather
 * than test for equality.
 */

#define TIMEBASE_TICK_MS  10u

void timebase_init(void);

/* Advance the tick counter if Timer2 has rolled over.  Cheap and non-blocking;
 * call it once per main-loop pass. */
void timebase_poll(void);

/* Free-running count of 10 ms ticks.  Wraps at 65536 (about 11 minutes);
 * unsigned subtraction makes elapsed-time comparisons wrap correctly. */
uint16_t timebase_ticks(void);

#endif /* TIMEBASE_H */
