/* zep_timer.c -- CTC tick service, raw CTC, common memory, callbacks. */
#include <string.h>
#include <zephyr/timer.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

/* The board wires the CTC's channel-select bits in reverse -- schematic and PCB
 * both take IC1 CS0 (pin 18) from A1 and CS1 (pin 19) from A0 -- so the channels
 * are not at consecutive ports:
 *
 *     channel 0 1 2 3  ->  port 40h 42h 41h 43h
 *
 * Registration (BDOS 200/201) still uses the channel number, and so does every
 * function here; only the port write is remapped.  See
 * ../../CPM2.2/docs/ctc-and-real-time-programming.md. */
static const uint8_t ctc_port[4] = { 0x40, 0x42, 0x41, 0x43 };
#define CTC_PORT(ch)       (ctc_port[(ch) & 3])
#define CTC_TIMER_256_TC   0xa7    /* interrupt, timer, /256, auto trigger, TC, reset */
#define CTC_BASE_TC        217     /* 10 MHz / 256 / 217 = 180.0115 Hz */
#define CTC_RESET          0x03
#define SIO0A_CTRL         0x21

#define STATE(ch) ((uint8_t *)(ZEP__TICK_STATE + (uint16_t)(ch) * ZEP__TS_SIZE))

static uint16_t common_next = ZEP_COMMON_BASE;

static void timer_cleanup(void)
{
    uint8_t ch;
    for (ch = 0; ch < 4; ch++)
        if (zep__ctc_owner[ch] == ZEP__OWNER_TIMER)
            (void)zep_timer_stop(ch);
}

uint8_t zep_timer_start(uint8_t channel, uint8_t rate_hz)
{
    uint8_t *s;

    if (channel > 3 || rate_hz == 0 || rate_hz > 180)
        return ZEP_EINVAL;
    if (zep__ctc_owner[channel] != ZEP__OWNER_NONE)
        return ZEP_EBUSY;

    /* Interrupt registration is a Zephyr BDOS function.  Another BDOS returns
     * whatever was in HL, which can look like success, so ask first. */
    if (zep_sysinfo() == 0)
        return ZEP_EUNAVAILABLE;

    zep__stubs_install();
    s = STATE(channel);
    memset(s, 0, ZEP__TS_SIZE);
    s[ZEP__TS_RATE] = rate_hz;

    if (zep__isr_register(channel, ZEP__STUB_TICK) != ZEP_OK)
        return ZEP_EUNAVAILABLE;
    zep__ctc_owner[channel] = ZEP__OWNER_TIMER;
    zep__on_exit(ZEP__MOD_TIMER, timer_cleanup);

    /* CTC0's output is SIO0/A's clock.  Starting it makes that channel shift
     * whatever its unconnected RS-232 input floats to, and the BIOS leaves
     * SIO0/A's WR1 holding 08h -- "interrupt on first received character" --
     * because its chip-wide enable write lands there on a Z80 SIO.  Those
     * interrupts vector to the console handler, which only ever reads channel
     * B, so nothing clears them.  Mask the channel before the clock starts. */
    if (channel == 0) {
        zep__di();
        zep__out(SIO0A_CTRL, 1);
        zep__out(SIO0A_CTRL, 0);
        zep__ei();
    }

    zep__out(CTC_PORT(channel), CTC_TIMER_256_TC);
    zep__out(CTC_PORT(channel), CTC_BASE_TC);

    /* A timer is useless with the CPU's interrupt enable off, and a program has
     * no reason to expect to have to think about it.  CP/M runs with interrupts
     * enabled; this only makes sure of it. */
    zep__ei();
    return ZEP_OK;
}

uint8_t zep_timer_stop(uint8_t channel)
{
    if (channel > 3 || zep__ctc_owner[channel] != ZEP__OWNER_TIMER)
        return ZEP_ENOTOPEN;
    /* Stop the real channel first.  The BIOS resets `0x40 + channel` when it
     * unregisters, which is the wrong channel for 1 and 2 on this board; that
     * write is harmless here because this timer's channel is already stopped. */
    zep__out(CTC_PORT(channel), CTC_RESET);
    (void)zep__isr_unregister(channel);
    zep__ctc_owner[channel] = ZEP__OWNER_NONE;
    return ZEP_OK;
}

/* The callback writes `produced`; only this writes `consumed`.  Single-byte
 * stores are indivisible on a Z80, so no interrupt has to be disabled. */
uint8_t zep_timer_take_tick(uint8_t channel)
{
    uint8_t *s;

    if (channel > 3)
        return 0;
    s = STATE(channel);
    if (s[ZEP__TS_PRODUCED] == s[ZEP__TS_CONSUMED])
        return 0;
    s[ZEP__TS_CONSUMED]++;
    return 1;
}

uint8_t zep_timer_pending(uint8_t channel)
{
    uint8_t *s;

    if (channel > 3)
        return 0;
    s = STATE(channel);
    return (uint8_t)(s[ZEP__TS_PRODUCED] - s[ZEP__TS_CONSUMED]);
}

/* Multi-byte counters are read twice: a value that survives one interrupt is
 * whole.  Cheaper and safer than masking interrupts around the read. */
uint16_t zep_timer_overflows(uint8_t channel)
{
    uint16_t a, b;
    uint8_t *s;

    if (channel > 3)
        return 0;
    s = STATE(channel);
    do {
        a = s[ZEP__TS_OVERFLOW] | ((uint16_t)s[ZEP__TS_OVERFLOW + 1] << 8);
        b = s[ZEP__TS_OVERFLOW] | ((uint16_t)s[ZEP__TS_OVERFLOW + 1] << 8);
    } while (a != b);
    return a;
}

uint32_t zep_timer_count(uint8_t channel)
{
    uint32_t a, b;
    uint8_t *s;

    if (channel > 3)
        return 0;
    s = STATE(channel);
    do {
        memcpy(&a, s + ZEP__TS_COUNT, 4);
        memcpy(&b, s + ZEP__TS_COUNT, 4);
    } while (a != b);
    return a;
}

void zep_ctc_write(uint8_t channel, uint8_t control, uint8_t time_constant)
{
    if (channel > 3 || !(control & 0x01))
        return;
    zep__out(CTC_PORT(channel), control);
    if (control & 0x04)
        zep__out(CTC_PORT(channel), time_constant);
}

uint8_t zep_ctc_port(uint8_t channel)
{
    return CTC_PORT(channel);
}

uint8_t zep_ctc_read(uint8_t channel)
{
    return channel > 3 ? 0 : zep__in(CTC_PORT(channel));
}

void zep_ctc_reset(uint8_t channel)
{
    if (channel <= 3)
        zep__out(CTC_PORT(channel), CTC_RESET);
}

void *zep_common_alloc(uint16_t n)
{
    uint16_t p;

    if (n == 0 || n > (uint16_t)(ZEP_COMMON_END - common_next))
        return 0;
    p = common_next;
    common_next += n;
    return (void *)p;
}

uint8_t zep_common_install(void *dst, const void *code, uint16_t n)
{
    uint16_t d = (uint16_t)dst;

    if (d < ZEP_COMMON_BASE || n > (uint16_t)(ZEP_COMMON_END - d))
        return ZEP_EINVAL;
    memcpy(dst, code, n);
    return ZEP_OK;
}

uint8_t zep_isr_register(uint8_t source, void *entry)
{
    uint16_t e = (uint16_t)entry;

    if (source > ZEP_ISR_VDP || e < ZEP_COMMON_BASE || e >= ZEP__STUB_BASE)
        return ZEP_EINVAL;
    if (source <= ZEP_ISR_CTC3 && zep__ctc_owner[source] != ZEP__OWNER_NONE)
        return ZEP_EBUSY;
    return zep__isr_register(source, e);
}

uint8_t zep_isr_unregister(uint8_t source)
{
    if (source > ZEP_ISR_VDP)
        return ZEP_EINVAL;
    return zep__isr_unregister(source);
}
