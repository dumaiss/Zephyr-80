/* zep_serial.c -- SIO0/A user port and SIO0/B console port. */
#include <zephyr/serial.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

#define SIO0A_CTRL        0x21
#define SIO0B_CTRL        0x23
#define CTC0              0x40

#define WR0_ERROR_RESET   0x30
#define WR1_RX_INT_ALL    0x18     /* what the BIOS console uses on SIO0/B */
#define WR3_RX_8BIT       0xc1
#define WR3_RX_8BIT_AUTO  0xe1     /* Auto Enables: /CTS gates TX, /DCD gates RX */
#define WR4_X16_8N1       0x44
#define WR5_RTS_OFF       0xe8     /* DTR, 8-bit TX, TX enable */
#define WR5_RTS_ON        0xea
#define CTC_COUNTER_TC    0x57     /* counter mode, rising edge, TC follows, reset */
#define CTC_RESET         0x03

#define SERCON_TEE_INPUT  0x03
#define TX_TIMEOUT_MS     2000

static const uint8_t ctrl_port[2] = { SIO0A_CTRL, SIO0B_CTRL };
static uint8_t port_open[2];
static uint8_t *sercon_flags;
static uint8_t sercon_saved;

/* Two-byte register writes run masked: the BIOS SIO interrupt resets the WR0
 * pointer on this chip and would split the pair. */
static void wr(uint8_t port, uint8_t reg, uint8_t value)
{
    zep__di();
    zep__out(port, reg);
    zep__out(port, value);
    zep__ei();
}

static void serial_cleanup(void)
{
    if (port_open[ZEP_SERIAL_CONSOLE])
        zep_serial_close(ZEP_SERIAL_CONSOLE);
    if (port_open[ZEP_SERIAL_USER])
        zep_serial_close(ZEP_SERIAL_USER);
}

static void drain(uint8_t ctrl)
{
    uint8_t guard = 16;
    zep__out(ctrl, WR0_ERROR_RESET);
    while (guard-- && (zep__in(ctrl) & 1))
        (void)zep__in(ctrl - 1);
}

static uint8_t open_console(uint32_t baud)
{
    const zep_sysinfo_t *s;

    if (baud != 0 && baud != 115200UL)
        return ZEP_EINVAL;

    /* Mirrored console output and the sercon input switch share this wire.
     * Without a Zephyr BIOS there is no sercon to quiet. */
    s = zep_sysinfo();
    sercon_flags = s ? (uint8_t *)s->sercon_flags : 0;
    if (sercon_flags) {
        sercon_saved = *sercon_flags;
        *sercon_flags &= (uint8_t)~SERCON_TEE_INPUT;
    }

    /* SIO0/B's receive interrupt off, and nothing else: SIO1 and the CTC keep
     * theirs, and the sercon sink stays registered for close. */
    wr(SIO0B_CTRL, 1, 0x00);
    drain(SIO0B_CTRL);
    wr(SIO0B_CTRL, 5, WR5_RTS_ON);
    return ZEP_OK;
}

static uint8_t open_user(uint32_t baud, uint8_t flags)
{
    uint16_t divisor;

    if (baud == 0 || 115200UL % baud != 0)
        return ZEP_EINVAL;
    divisor = (uint16_t)(115200UL / baud);
    if (divisor > 256)
        return ZEP_EINVAL;
    if (zep__ctc_owner[0] != ZEP__OWNER_NONE)
        return ZEP_EBUSY;
    zep__ctc_owner[0] = ZEP__OWNER_SERIAL;

    /* CTC0 counts the 1.8432 MHz input; TO0 is the SIO's x16 clock. */
    zep__out(CTC0, CTC_COUNTER_TC);
    zep__out(CTC0, (uint8_t)divisor);          /* 256 is written as 0 */

    wr(SIO0A_CTRL, 1, 0x00);                   /* polled: no SIO0/A interrupts */
    wr(SIO0A_CTRL, 4, WR4_X16_8N1);
    wr(SIO0A_CTRL, 3, (flags & ZEP_SERIAL_RTSCTS) ? WR3_RX_8BIT_AUTO : WR3_RX_8BIT);
    wr(SIO0A_CTRL, 5, WR5_RTS_ON);
    drain(SIO0A_CTRL);
    return ZEP_OK;
}

uint8_t zep_serial_open(zep_port_t p, uint32_t baud, uint8_t flags)
{
    uint8_t r;

    if ((uint8_t)p > ZEP_SERIAL_CONSOLE)
        return ZEP_EINVAL;
    if (port_open[p])
        return ZEP_EBUSY;
    r = (p == ZEP_SERIAL_CONSOLE) ? open_console(baud) : open_user(baud, flags);
    if (r == ZEP_OK) {
        port_open[p] = 1;
        zep__on_exit(ZEP__MOD_SERIAL, serial_cleanup);
    }
    return r;
}

void zep_serial_close(zep_port_t p)
{
    if ((uint8_t)p > ZEP_SERIAL_CONSOLE || !port_open[p])
        return;
    port_open[p] = 0;

    if (p == ZEP_SERIAL_CONSOLE) {
        wr(SIO0B_CTRL, 5, WR5_RTS_OFF);
        drain(SIO0B_CTRL);
        wr(SIO0B_CTRL, 1, WR1_RX_INT_ALL);
        if (sercon_flags)
            *sercon_flags = sercon_saved;
    } else {
        wr(SIO0A_CTRL, 5, WR5_RTS_OFF);
        zep__out(CTC0, CTC_RESET);
        zep__ctc_owner[0] = ZEP__OWNER_NONE;
    }
}

int zep_serial_getc(zep_port_t p)
{
    if ((uint8_t)p > ZEP_SERIAL_CONSOLE || !port_open[p])
        return -1;
    return zep__sio_getc(ctrl_port[p], 0);
}

int zep_serial_getc_ms(zep_port_t p, uint16_t ms)
{
    if ((uint8_t)p > ZEP_SERIAL_CONSOLE || !port_open[p])
        return -1;
    return zep__sio_getc(ctrl_port[p], ms);
}

uint8_t zep_serial_putc(zep_port_t p, uint8_t c)
{
    if ((uint8_t)p > ZEP_SERIAL_CONSOLE)
        return ZEP_EINVAL;
    if (!port_open[p])
        return ZEP_ENOTOPEN;
    return zep__sio_putc(ctrl_port[p], c, TX_TIMEOUT_MS);
}

uint16_t zep_serial_read(zep_port_t p, uint8_t *buf, uint16_t n, uint16_t ms)
{
    uint16_t got = 0;
    int c;

    while (got < n) {
        c = zep_serial_getc_ms(p, ms);
        if (c < 0)
            break;
        buf[got++] = (uint8_t)c;
    }
    return got;
}

uint16_t zep_serial_write(zep_port_t p, const uint8_t *buf, uint16_t n)
{
    uint16_t sent = 0;

    while (sent < n && zep_serial_putc(p, buf[sent]) == ZEP_OK)
        sent++;
    return sent;
}

uint8_t zep_serial_status(zep_port_t p)
{
    uint8_t ctrl, rr0, rr1, s;

    if ((uint8_t)p > ZEP_SERIAL_CONSOLE)
        return 0;
    ctrl = ctrl_port[p];
    zep__di();
    rr0 = zep__in(ctrl);
    zep__out(ctrl, 1);
    rr1 = zep__in(ctrl);
    if (rr1 & 0x70)
        zep__out(ctrl, WR0_ERROR_RESET);
    zep__ei();
    s = rr0 & (ZEP_SERIAL_RX_READY | ZEP_SERIAL_TX_EMPTY | ZEP_SERIAL_CTS);
    if (rr1 & 0x20)
        s |= ZEP_SERIAL_OVERRUN;
    if (rr1 & 0x40)
        s |= ZEP_SERIAL_FRAMING;
    return s;
}

void zep_serial_rts(zep_port_t p, uint8_t asserted)
{
    if ((uint8_t)p > ZEP_SERIAL_CONSOLE || !port_open[p])
        return;
    wr(ctrl_port[p], 5, asserted ? WR5_RTS_ON : WR5_RTS_OFF);
}
