#ifndef TIMEBASE_H
#define TIMEBASE_H

#include "config.h"

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

/* ---------------------------------------------------------------------------
 * Controller phase profiler
 *
 * Timer3, free running from the nominal 31 kHz LFINTOSC, so one tick is about
 * 32 us and the counter wraps every 2.1 seconds.  Timer1 is deliberately not
 * used here: external_sync.c owns it as the physical RB3/SCK edge counter and
 * reconfigures it during every command transaction.
 *
 * ROLLOVER: any single bracketed span longer than 2.1 seconds is under-reported
 * by a multiple of that.  The SD driver's approximately one-second worst-case
 * initialisation and sub-second write-busy limit both fit inside that period.
 * --------------------------------------------------------------------------- */
#define UPROF_RX      0u   /* clocking the 48-byte receive window          */
#define UPROF_DECODE  1u   /* frame alignment search and CRC               */
#define UPROF_DISPATCH 2u  /* handler, including cache lookup and card I/O */
#define UPROF_SEND    3u   /* clocking the reply frame out                 */
#define UPROF_BULK    4u   /* the whole bulk-lane phase                    */
#define UPROF_TOTAL   5u   /* everything, for cross-checking the parts     */
#define UPROF_BULK_WAIT 6u /* waiting for the host's bulk RTS              */
#define UPROF_BULK_PREP 7u /* admission, sync and SPI setup before TX      */
#define UPROF_BULK_DATA 8u /* framed bytes, streaming CRC and final flush  */
#define UPROF_BULK_DONE 9u /* handshake and state teardown after TX        */
#define UPROF_PUBLIC_SLOTS 6u
#define UPROF_SLOTS   10u

/* uprof_init() and uprof_now() are NOT gated on the build profile.
 *
 * uprof_now() is a microsecond time source, not a profiler.  bulk_channel.c's
 * wait_for_host_ready() uses it to bound the wait for the host's RTS: Timer3
 * gives that its 500 ms failure contract without adding ~1 ms to every good
 * transfer, which is what sampling the millisecond tick instead would cost.
 * Compiling it out would either wedge the controller on a host that never
 * arrives or slow down every transfer that succeeds.
 *
 * The accumulation below IS the profiler, and it is gated. */
void     uprof_init(void);
uint16_t uprof_now(void);

#if IOC_DIAGNOSTIC_BUILD

void     uprof_add(uint8_t slot, uint16_t start);
uint16_t uprof_ms(uint8_t slot);

/* CMD_PROFILE can request a clean measurement interval.  The reset is applied
 * only after that command's reply and TOTAL bracket have completed, so none of
 * the reset transaction leaks into the following benchmark. */
void uprof_request_reset(void);
void uprof_apply_pending_reset(void);

#else

/* The brackets stay in the source, where they document which phase is which,
 * and compile to nothing.  Arguments are consumed so a normal build does not
 * warn about the locals that feed them. */
#define uprof_add(slot, start)     ((void)(slot), (void)(start))
#define uprof_ms(slot)             ((void)(slot), (uint16_t)0)
#define uprof_request_reset()      ((void)0)
#define uprof_apply_pending_reset() ((void)0)

#endif
