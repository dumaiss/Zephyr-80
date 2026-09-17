/* TIMTEST.COM -- the CTC timer on real hardware, with no video involved.
 *
 * Starts the tick service on one channel and watches it, touching neither the
 * VDP nor the sound card, so anything that fails here is the timer path alone.
 *
 *   TIMTEST [channel] [rate]     defaults: channel 0, 100 Hz
 *
 * Channel means physical CTC channel / BIOS callback source. The board wires
 * CS0 to A1 and CS1 to A0, so channels 0,1,2,3 use ports 40h,42h,41h,43h; the
 * library maps that internally now, and every call here takes a channel.
 *
 * It separates the three ways a timer can be silent:
 *
 *   - the CPU is ignoring interrupts        -- "interrupts: off"
 *   - the channel is not counting           -- the counter readback never moves
 *   - the channel counts but never vectors  -- counter moves, interrupts stay 0
 */
#pragma output REGISTER_SP = 0xC030
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/timer.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

static uint8_t cookie = 0x00;

static void show_counter(uint8_t channel)
{
    uint8_t first, seen[4];
    uint16_t spin;
    uint8_t i;

    first = zep_ctc_read(channel);
    for (i = 0; i < 4; i++) {
        for (spin = 0; spin < 2000; spin++)
            ;
        seen[i] = zep_ctc_read(channel);
    }
    printf("  down-counter: %3u then %3u %3u %3u %3u -- %s\n",
           first, seen[0], seen[1], seen[2], seen[3],
           (seen[0] != first || seen[1] != first || seen[2] != first ||
            seen[3] != first) ? "counting" : "NOT counting");
}

int main(int argc, char **argv)
{
    uint8_t channel = 0, rate = 100, second, r;
    uint16_t ticks, spin;
    uint32_t base, last = 0;

    if(cookie == 0x00) {

        cookie = 0xaf;

    } else {

        printf("TIMTEST - bad restart\n");
    }

    printf("TIMTEST - ZephyrC CTC tick service\n");
    if (argc > 1)
        channel = (uint8_t)atoi(argv[1]) & 3;
    if (argc > 2)
        rate = (uint8_t)atoi(argv[2]);

    printf("interrupts at entry: %s\n", zep__iff() ? "on" : "off");
    if (zep_sysinfo() == 0) {
        printf("Not a Zephyr BIOS: BDOS 200 is unavailable here\n");
        return 1;
    }

    r = zep_timer_start(channel, rate);
    printf("start(CTC%u, port %02Xh, %u Hz) = %u; interrupts now %s\n",
           channel, zep_ctc_port(channel), rate, r,
           zep__iff() ? "on" : "off");
    if (r != ZEP_OK)
        return 1;
    show_counter(channel);

    for (second = 1; second <= 10; second++) {
        /* One second by tick count when ticks arrive, or a bounded spin when
         * they do not, so a dead channel still finishes the test. */
        ticks = 0;
        for (spin = 0; spin < 60000U && ticks < rate; spin++)
            if (zep_timer_take_tick(channel))
                ticks++;
        base = zep_timer_count(channel);
        printf("  %2u: %5u ticks, %6lu base interrupts (+%lu), %u lost\n",
               second, ticks, base, base - last, zep_timer_overflows(channel));
        last = base;
    }

    show_counter(channel);
    r = zep_timer_stop(channel);
    printf("stop = %u\n", r);
    if (last == 0)
        printf("CTC%u never interrupted.\n", channel);
    else
        printf("CTC%u delivered %lu interrupts (expect about 1800).\n", channel, last);
    return 0;
}
