/* IRQTEST: test the running BIOS's interrupt register/SP preservation.
 *
 * IRQTEST [channel] [tick|min] [pairs]   defaults: 3 tick 1000 (~14 seconds)
 * IRQTEST R                            report the previous retained snapshot
 *
 * Each pair tests the application and OS mappings. No console, IOC, VDP or
 * sound calls occur during the measurement. This isolates the interrupt path;
 * passing does not establish that interrupt/foreground I/O interactions work.
 * E000h-E2FFh belongs to this test, E300h-E3FFh to the production tick stub.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/bdos.h>
#include <zephyr/timer.h>
#include "zep_internal.h"
#include "irq_probe.h"

static const uint16_t expected[IRQ_REG_COUNT] = {
    0xa5d7, 0x00c3, 0x69a5, 0xa569, 0x1357, 0x2468,
    0x5a28, 0x6996, 0x8778, 0x4bb4, IRQ_TEST_SP
};
static const char *reg_names[IRQ_REG_COUNT] = {
    "AF", "BC", "DE", "HL", "IX", "IY", "AF'", "BC'", "DE'", "HL'", "SP"
};
static uint8_t active = 0xff;

static void stop_timer(void)
{
    if (active == 0xff)
        return;
    /* The BIOS still resets the wrong port for channels 1/2 when it
     * unregisters; reset the real channel first. */
    zep_ctc_reset(active);
    (void)zep__isr_unregister(active);
    active = 0xff;
}

static uint32_t count(uint8_t channel, uint8_t tick)
{
    uint32_t n;
    volatile uint32_t *raw = (volatile uint32_t *)(ZEP__TICK_STATE +
                              (uint16_t)channel * ZEP__TS_SIZE + ZEP__TS_COUNT);
    /* Short, atomic snapshot; no I/O or loops in the masked interval. */
    zep__di();
    n = tick ? *raw : *IRQ_MIN_COUNT;
    zep__ei();
    return n;
}

static uint8_t snapshot_ok(void)
{
    uint8_t i;
    for (i = 0; i < IRQ_REG_COUNT; i++)
        if (IRQ_OBSERVED[i] != expected[i])
            return 0;
    for (i = 0; i < IRQ_GUARD_SIZE; i++)
        if (IRQ_GUARD[i] != 0xa5)
            return 0;
    return memcmp(IRQ_CODE, zep_irq_probe_image, zep_irq_probe_size) == 0;
}

static void report(void)
{
    uint8_t i, stage;
    if (memcmp((const void *)IRQ_RECORD, "IRQ1", 4) != 0) {
        printf("No retained IRQTEST record.\n");
        return;
    }
    stage = IRQ_RECORD[IRQ_STAGE];
    printf("CTC%u, %s callback, %s mapping, completed pairs %u, stage %u\n",
           IRQ_RECORD[IRQ_CHANNEL], IRQ_RECORD[IRQ_CALLBACK] ? "tick" : "minimal",
           IRQ_RECORD[IRQ_MODE] ? "OS" : "application",
           *(volatile uint16_t *)(IRQ_RECORD + IRQ_PAIR), stage);
    printf("Stages: 0 setup, 1 running, 2 captured, 3 checked, 4 failed\n");
    if (stage < 2) {
        printf("No completed snapshot for this window; values may be from an earlier one.\n");
        return;
    }
    for (i = 0; i < IRQ_REG_COUNT; i++)
        printf("  %s expected %04X got %04X %s\n", reg_names[i], expected[i],
               IRQ_OBSERVED[i], IRQ_OBSERVED[i] == expected[i] ? "ok" : "FAIL");
    for (i = 0; i < IRQ_GUARD_SIZE; i++)
        if (IRQ_GUARD[i] != 0xa5) {
            printf("Stack guard changed at %04X: %02X\n",
                   0xe2d0 + i, IRQ_GUARD[i]);
            break;
        }
    if (memcmp(IRQ_CODE, zep_irq_probe_image, zep_irq_probe_size) != 0)
        printf("Common probe code changed.\n");
}

int main(int argc, char **argv)
{
    uint8_t channel = 3, tick = 1, mode, i, failed = 0;
    uint16_t pair, pairs = 1000;
    uint32_t before, after, serviced[2] = { 0, 0 };
    uint8_t *s;

    if (argc > 1 && (argv[1][0] == 'R' || argv[1][0] == 'r')) {
        report();
        return 0;
    }
    if (argc > 1) {
        int n = atoi(argv[1]);
        if (n < 0 || n > 3)
            return 1;
        channel = (uint8_t)n;
    }
    if (argc > 2) {
        if (strcmp(argv[2], "min") == 0 || strcmp(argv[2], "MIN") == 0)
            tick = 0;
        else if (strcmp(argv[2], "tick") != 0 && strcmp(argv[2], "TICK") != 0)
            return 1;
    }
    if (argc > 3) {
        int n = atoi(argv[3]);
        if (n < 1 || n > 5000)
            return 1;
        pairs = (uint16_t)n;
    }
    if (!zep_sysinfo()) {
        printf("IRQTEST requires the Zephyr BIOS.\n");
        return 1;
    }
    printf("IRQTEST CTC%u port %02Xh, %s callback, %u pairs\n",
           channel, zep_ctc_port(channel), tick ? "tick" : "minimal", pairs);
    printf("Testing registers/SP in application and OS mappings; output follows timer stop.\n");
    printf("After an unexpected warm boot, run IRQTEST R before another test.\n");

    memset((void *)IRQ_RECORD, 0, 0xa0);
    memcpy((void *)IRQ_RECORD, "IRQ1", 4);
    IRQ_RECORD[IRQ_CHANNEL] = channel;
    IRQ_RECORD[IRQ_CALLBACK] = tick;
    for (i = 0; i < IRQ_GUARD_SIZE; i++)
        IRQ_GUARD[i] = 0xa5;
    zep_irq_probe_install();
    zep__stubs_install();
    s = (uint8_t *)(ZEP__TICK_STATE + (uint16_t)channel * ZEP__TS_SIZE);
    memset(s, 0, ZEP__TS_SIZE);
    s[ZEP__TS_RATE] = 100;
    if (atexit(stop_timer) != 0)
        return 1;
    if (zep__isr_register(channel, tick ? ZEP__STUB_TICK : IRQ_MIN_CALLBACK) != ZEP_OK) {
        printf("Registration refused.\n");
        return 1;
    }
    active = channel;
    if (channel == 0) {
        zep__di();
        zep__out(0x21, 1); /* same SIO0/A mask as the existing tick service */
        zep__out(0x21, 0);
        zep__ei();
    }
    zep_ctc_write(channel, 0xa7, 217);
    zep__ei();

    for (pair = 0; pair < pairs && !failed; pair++) {
        for (mode = 0; mode < 2; mode++) {
            before = count(channel, tick);
            zep_irq_probe(mode);
            after = count(channel, tick);
            serviced[mode] += tick ? after - before : (uint16_t)(after - before);
            if (!snapshot_ok()) {
                IRQ_RECORD[IRQ_STAGE] = 4;
                failed = 1;
                break;
            }
            IRQ_RECORD[IRQ_STAGE] = 3;
        }
        if (!failed)
            *(volatile uint16_t *)(IRQ_RECORD + IRQ_PAIR) = pair + 1;
    }
    stop_timer();
    printf("Observed interrupts around probe windows: application %lu, OS %lu\n",
           serviced[0], serviced[1]);
    printf("%s\n", failed ? "FAIL: register, SP, guard or probe-code mismatch" :
           (!serviced[0] || !serviced[1]) ? "INCONCLUSIVE: no IRQ coverage for a mapping" :
           "PASS: captured registers, SP, guard and probe code match");
    report();
    return failed || !serviced[0] || !serviced[1];
}
