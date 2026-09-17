/* PCTRACE.COM -- what was the machine doing before control went back to 0100h?
 *
 *   PCTRACE [channel] [seconds] [quiet]   defaults: channel 3, 60 seconds
 *   PCTRACE R                             report the retained ring and stop
 *
 * A "second" is 180 base interrupts, the rate the CTC is programmed for, not a
 * spin count: that way the run lasts what it says when the timer is healthy,
 * and the per-second line shows how many ticks actually arrived.  If a second's
 * worth never arrives the line is marked and the run moves on, so a dead
 * channel still finishes.  "quiet" prints nothing until the end, which measures
 * the tick rate without console traffic in the way.
 *
 * A callback in common memory records, for every interrupt, the interrupted PC
 * and SP, the bank latch, and the channel.  Common memory survives both a warm
 * boot and whatever sends control back to 0100h, so the next entry to main
 * prints the last moments before the fault.
 *
 * The workload deliberately resembles TIMTEST, which reproduces the fault:
 * timer interrupts arriving while the foreground prints through BDOS.  A marker
 * byte says which part of the loop main had reached.
 *
 * E000h-E2FFh belongs to this test while it runs (as it does for IRQTEST);
 * E300h-E3FFh stays with the ZephyrC tick stub, which this test does not use.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/bdos.h>
#include <zephyr/timer.h>
#include "zep_internal.h"
#include "pc_probe.h"

#define MARK_SETUP    1
#define MARK_SPIN     2
#define MARK_PRINT    3
#define MARK_STOP     4
#define MARK_DONE     5

#define BASE_HZ       180       /* 10 MHz / 256 / 217 */
#define SPIN_CAP      40000U    /* well over a second of spinning */

static uint8_t active = 0xff;

/* The callback writes this; read it twice so a half-updated value is never
 * used, the same rule the tick counters follow. */
static uint32_t interrupts(void)
{
    uint32_t a, b;

    do {
        a = *PC_COUNT;
        b = *PC_COUNT;
    } while (a != b);
    return a;
}

static const char *mark_name(uint8_t m)
{
    switch (m) {
    case MARK_SETUP: return "setting up";
    case MARK_SPIN:  return "spinning";
    case MARK_PRINT: return "printing";
    case MARK_STOP:  return "stopping the timer";
    case MARK_DONE:  return "finished";
    default:         return "before the first mark";
    }
}

static void stop_timer(void)
{
    if (active == 0xff)
        return;
    zep_ctc_reset(active);
    (void)zep__isr_unregister(active);
    active = 0xff;
}

/* Bit 3 of the bank latch selects OS execution: 2000h-DFFFh is bank 7 then. */
static const char *where(uint16_t pc, uint8_t latch)
{
    if (pc < 0x0100)
        return "page zero";
    if (pc >= 0xf000)
        return "BIOS";
    if (pc >= 0xec00)
        return "BDOS facade";
    if (pc >= 0xe400)
        return "CCP area / C stack";
    if (pc >= 0xe000)
        return "common reservation (this test, or the tick stub)";
    if (pc < 0x2000)
        return "program, low 8K";
    return (latch & 0x08) ? "bank 7: ZSDOS or a BIOS driver" : "program";
}

static void report(void)
{
    uint8_t i, slot, shown;

    if (memcmp((const void *)PC_MAGIC, "PCT1", 4) != 0) {
        printf("No retained PCTRACE ring.\n");
        return;
    }
    printf("Retained ring: %lu interrupts, main was %s, CTC%u, entries to main %u\n",
           *PC_COUNT, mark_name(*PC_MARK), *PC_CHANNEL, *PC_RUNS);
    printf("Lowest interrupted SP: %04X%s\n", *PC_MINSP,
           (*PC_MINSP && *PC_MINSP < 0xe400) ?
           "  -- BELOW E400h: the stack reached the reservation" : "");

    shown = *PC_WRAPPED ? PC_SLOTS : *PC_INDEX;
    if (!shown) {
        printf("  ring empty: no interrupt was ever recorded\n");
        return;
    }
    printf("  most recent first: PC, SP, latch, channel\n");
    slot = *PC_INDEX;
    for (i = 0; i < shown; i++) {
        volatile uint8_t *e;
        uint16_t pc, sp;
        uint8_t latch, channel;

        slot = slot ? (uint8_t)(slot - 1) : (uint8_t)(PC_SLOTS - 1);
        e = PC_RING + (uint16_t)slot * PC_ENTRY;
        pc = (uint16_t)e[0] | ((uint16_t)e[1] << 8);
        sp = (uint16_t)e[2] | ((uint16_t)e[3] << 8);
        latch = e[4];
        channel = e[5];
        printf("  %2u: PC %04X SP %04X latch %02X CTC%u  %s\n",
               i, pc, sp, latch, channel, where(pc, latch));
    }
}

int main(int argc, char **argv)
{
    uint8_t channel = 3, second, seconds = 60, quiet = 0;
    uint16_t spin;
    uint32_t seen = 0;

    if (argc > 1 && (argv[1][0] == 'R' || argv[1][0] == 'r')) {
        report();
        return 0;
    }

    printf("PCTRACE - interrupt PC recorder\n");
    if (memcmp((const void *)PC_MAGIC, "PCT1", 4) == 0) {
        if (*PC_FIRED)
            printf("\n*** WATCHDOG: the foreground stopped; warm booted to keep the ring ***\n");
        else
            printf("\n*** CONTROL CAME BACK TO 0100h WITHOUT A RELOAD ***\n");
        report();
        printf("\nStarting a fresh run.\n\n");
    }
    if (argc > 1) {
        int n = atoi(argv[1]);
        if (n < 0 || n > 3)
            return 1;
        channel = (uint8_t)n;
    }
    if (argc > 2) {
        int n = atoi(argv[2]);
        if (n > 0 && n < 256)
            seconds = (uint8_t)n;
    }
    if (argc > 3 && (argv[3][0] == 'Q' || argv[3][0] == 'q'))
        quiet = 1;
    if (!zep_sysinfo()) {
        printf("PCTRACE requires the Zephyr BIOS.\n");
        return 1;
    }

    *PC_RUNS = (uint8_t)(*PC_RUNS + 1);
    *PC_INDEX = 0;
    *PC_WRAPPED = 0;
    *PC_COUNT = 0;
    *PC_CHANNEL = channel;
    *PC_MARK = MARK_SETUP;
    *PC_HEART = 0;
    *PC_STALL = 0;
    *PC_FIRED = 0;
    *PC_MINSP = 0;
    *PC_WATCHDOG = 0;           /* armed once the measured loop starts */
    memset((void *)PC_RING, 0, PC_SLOTS * PC_ENTRY);
    zep_pc_probe_install();
    memcpy((void *)PC_MAGIC, "PCT1", 4);

    if (atexit(stop_timer) != 0)
        return 1;
    if (zep__isr_register(channel, PC_CALLBACK) != ZEP_OK) {
        printf("Registration refused.\n");
        return 1;
    }
    active = channel;
    if (channel == 0) {
        zep__di();
        zep__out(0x21, 1);          /* the SIO0/A mask the tick service uses */
        zep__out(0x21, 0);
        zep__ei();
    }
    zep_ctc_write(channel, 0xa7, 217);      /* /256, 217: 180.0115 Hz */
    zep__ei();

    printf("CTC%u (port %02Xh) recording for %u seconds; interrupts %s\n",
           channel, zep_ctc_port(channel), seconds, zep__iff() ? "on" : "off");
    printf("If control returns to 0100h, run PCTRACE again (or PCTRACE R) to read the ring.\n");
    printf("Watchdog: %u interrupts (about %u s) without foreground progress warm boots.\n",
           (unsigned)(BASE_HZ * 5), 5);
    *PC_WATCHDOG = BASE_HZ * 5;

    for (second = 1; second <= seconds; second++) {
        uint32_t target, now;
        uint8_t timed_out = 0;

        *PC_MARK = MARK_SPIN;
        target = interrupts() + BASE_HZ;
        for (spin = 0; spin < SPIN_CAP; spin++) {
            *PC_HEART = (uint8_t)(*PC_HEART + 1);   /* the watchdog's heartbeat */
            now = interrupts();
            if (now >= target)
                break;
        }
        if (spin >= SPIN_CAP)
            timed_out = 1;
        now = interrupts();

        *PC_HEART = (uint8_t)(*PC_HEART + 1);
        if (!quiet) {
            *PC_MARK = MARK_PRINT;
            printf("  %3u: %6lu interrupts (+%lu)%s\n", second, now,
                   now - seen, timed_out ? "  slow: fewer than 180 arrived" : "");
        }
        seen = now;
    }

    *PC_WATCHDOG = 0;           /* no watchdog while shutting down */
    *PC_MARK = MARK_STOP;
    stop_timer();
    *PC_MARK = MARK_DONE;
    seen = interrupts();
    printf("Completed %u seconds, %lu interrupts, no fault.\n", seconds, seen);
    printf("Lowest interrupted SP %04X (E400h or above is clear of the reservation).\n",
           *PC_MINSP);
    printf("Average %lu per second against %u programmed",
           seen / (seconds ? seconds : 1), BASE_HZ);
    printf(quiet ? " (quiet run: no console traffic).\n"
                 : " (ticks are lost while the console prints).\n");
    memset((void *)PC_MAGIC, 0, 4);         /* a clean run leaves no ring */
    return 0;
}
