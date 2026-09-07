#ifndef BOOT_GUARD_H
#define BOOT_GUARD_H

#include <stdint.h>
#include <stdbool.h>

/* Reset-loop guard.
 *
 * ---------------------------------------------------------------------------
 * WHY
 * ---------------------------------------------------------------------------
 *
 * This controller drives the host reset pair, so a fault that resets the PIC
 * on the same code path every pass does not present as a controller problem.
 * It presents as a machine that reboots forever, with no console, nothing to
 * query, and no way in except a programmer.  Three separate firmware builds
 * have now done exactly that, and each one cost a reflash to learn a single
 * bit of information.
 *
 * The guard turns that into one bad boot instead of an infinite series.  A
 * counter in memory that survives reset -- __persistent, so the startup code
 * does not clear it -- counts consecutive boots that did not stay up.  Past the
 * limit the firmware comes up DEGRADED: it skips the paths that are allowed to
 * be risky, which lets the machine boot, so the failure can be interrogated
 * with the tools instead of inferred from a symptom.
 *
 * A power cycle clears it, because uninitialised RAM will not match the magic.
 * Staying up for the settle interval clears it too, so an ordinary reset -- the
 * user pressing reset, CTRL-ALT-ESC, a programmer attaching -- never
 * accumulates toward the limit.
 *
 * ---------------------------------------------------------------------------
 * WHAT DEGRADED MEANS
 * ---------------------------------------------------------------------------
 *
 * Storage still works, in raw mode: the machine boots and CP/M runs, because
 * that path is the one thing that must never be skipped.  What is skipped is
 * the filesystem resolution -- mounting an image out of /CPM/ -- which is new,
 * is the suspect, and which the machine can do without.
 *
 * Degraded state is REPORTED, in the CMD_VOL_INFO reply, so it is read rather
 * than guessed at.  A unit sitting in raw mode because the guard tripped and a
 * unit sitting in raw mode because the card has no filesystem look identical
 * otherwise, and those are very different problems.
 */

/* Consecutive unsettled boots before the guard trips. */
#define BOOT_GUARD_LIMIT   3u

/* How long the controller must stay up before a boot counts as healthy.
 * Ticks are TIMEBASE_TICK_MS apart; 200 is about two seconds, which is far
 * longer than any of the observed reset loops survived. */
#define BOOT_GUARD_SETTLE  200u

/* Latch the count.  Call FIRST, before anything else in main(). */
void boot_guard_init(void);

/* Call from the idle branch of the main loop.  Once the controller has been up
 * for the settle interval this clears the count, so the next real fault starts
 * from zero rather than from whatever a previous session left behind. */
void boot_guard_settle(void);

/* True when the guard has tripped and risky paths must be skipped. */
bool boot_degraded(void);

/* Consecutive unsettled boots seen, for reporting. */
uint8_t boot_reset_count(void);

/* True if the last reset was a PIC18 hardware stack overflow or underflow.
 * Latched from PCON0 by boot_guard_init(), which also clears those bits --
 * they are sticky, so without clearing them one overflow would be reported
 * forever. */
bool boot_stack_reset(void);

#endif /* BOOT_GUARD_H */
