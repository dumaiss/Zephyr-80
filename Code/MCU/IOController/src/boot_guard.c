#include <xc.h>

#include "boot_guard.h"
#include "timebase.h"

#define BOOT_GUARD_MAGIC  0x5A3Cu

/* __persistent: not cleared or initialised by the startup code, so these
 * survive a reset.  That is the entire mechanism -- on a power-up the RAM
 * holds whatever it holds, which will not match the magic, and the count
 * starts clean. */
static __persistent uint16_t guard_magic;
static __persistent uint8_t  guard_resets;

static bool     stack_reset;
static bool     settled;
static bool     start_valid;
static uint16_t start_tick;

void boot_guard_init(void)
{
    /* PCON0's cause bits are sticky across resets until firmware clears them,
     * so read once and clear, or a single overflow reports itself forever. */
    stack_reset = (PCON0bits.STKOVF != 0u) || (PCON0bits.STKUNF != 0u);
    PCON0bits.STKOVF = 0u;
    PCON0bits.STKUNF = 0u;

    if (guard_magic != BOOT_GUARD_MAGIC) {
        guard_magic  = BOOT_GUARD_MAGIC;
        guard_resets = 0u;
    } else if (guard_resets < 0xFFu) {
        guard_resets++;
    }

    settled     = false;
    start_valid = false;
}

void boot_guard_settle(void)
{
    uint16_t now;

    if (settled)
        return;

    now = timebase_ticks();

    if (!start_valid) {
        start_tick  = now;
        start_valid = true;
        return;
    }

    /* Unsigned difference, so this survives the tick counter wrapping. */
    if ((uint16_t)(now - start_tick) < BOOT_GUARD_SETTLE)
        return;

    settled      = true;
    guard_resets = 0u;
}

bool    boot_degraded(void)    { return guard_resets >= BOOT_GUARD_LIMIT; }
uint8_t boot_reset_count(void) { return guard_resets; }
bool    boot_stack_reset(void) { return stack_reset; }
