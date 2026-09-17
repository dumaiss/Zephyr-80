/* TICKTEST.COM -- the CTC tick stub, without a CTC.
 *
 * Installs the common-memory stubs and calls the tick callback exactly as the
 * BIOS dispatcher would (C = channel), then checks the phase accumulator,
 * saturation and counters through the public timer API.  Runs anywhere,
 * including RunCPM.
 */
#include <stdio.h>
#include <string.h>
#include <zephyr/timer.h>
#include "zep_internal.h"

extern void zep_test_tick(uint8_t channel) __z88dk_fastcall;

static uint8_t failures;

static void set_rate(uint8_t channel, uint8_t rate)
{
    uint8_t *s = (uint8_t *)(ZEP__TICK_STATE + (uint16_t)channel * ZEP__TS_SIZE);
    memset(s, 0, ZEP__TS_SIZE);
    s[ZEP__TS_RATE] = rate;
}

static void check(uint8_t channel, uint8_t rate, uint16_t calls,
                  uint8_t want_pending, uint16_t want_overflows)
{
    uint16_t i, taken = 0;
    uint8_t pending, ok;
    uint16_t overflows;
    uint32_t count;

    set_rate(channel, rate);
    for (i = 0; i < calls; i++)
        zep_test_tick(channel);

    pending = zep_timer_pending(channel);
    overflows = zep_timer_overflows(channel);
    count = zep_timer_count(channel);
    while (zep_timer_take_tick(channel))
        taken++;

    ok = pending == want_pending && overflows == want_overflows &&
         count == calls && taken == want_pending && zep_timer_pending(channel) == 0;
    printf("  CTC%u rate %3u x %3u calls: pending %3u overflow %2u count %4lu  %s\n",
           channel, rate, calls, pending, overflows, count, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

int main(void)
{
    const uint8_t *sig = (const uint8_t *)0xE3F0;
    uint8_t *other;

    printf("TICKTEST - ZephyrC tick stub\n");
    zep__stubs_install();
    if (memcmp(sig, "ZEPSTUB2", 8) != 0) {
        printf("  stub signature missing\n");
        return 1;
    }

    check(0, 60, 180, 60, 0);       /* the exact divide-by-three case */
    check(1, 1, 180, 1, 0);
    check(2, 180, 180, 180, 0);     /* one tick per interrupt */
    check(3, 7, 180, 7, 0);
    check(1, 59, 540, 177, 0);
    check(2, 100, 9, 5, 0);         /* 900 / 180 */
    check(0, 180, 300, 255, 45);    /* saturates at 255, counts the rest */

    /* Channels must not disturb each other. */
    set_rate(3, 90);
    other = (uint8_t *)(ZEP__TICK_STATE + 3 * ZEP__TS_SIZE);
    other[ZEP__TS_PRODUCED] = 42;
    check(2, 60, 180, 60, 0);
    if (other[ZEP__TS_PRODUCED] != 42 || other[ZEP__TS_RATE] != 90) {
        printf("  CTC3 state disturbed by CTC2  FAIL\n");
        failures++;
    }

    printf(failures ? "TICKTEST: %u FAILED\n" : "TICKTEST: all passed\n", failures);
    return failures != 0;
}
