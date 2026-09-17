/* zep_vdp.c -- LunchCrema V9958. */
#include <zephyr/vdp.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

#define VDP_DATA      0xa0
#define VDP_CMD       0xa1
#define VDP_PALETTE   0xa2
#define VDP_INDIRECT  0xa3

#define REG_COUNT     47            /* R#0-R#46 */

static uint8_t shadow[REG_COUNT];
static uint8_t held;
static zep_vdp_mode_t current_mode = ZEP_VDP_G1;

/* A register write is two OUTs to the command port, and a VDP interrupt handler
 * reads status, which resets the port's byte pairing.  Keep every pair masked. */
static void reg_raw(uint8_t r, uint8_t v)
{
    zep__di();
    zep__out(VDP_CMD, v);
    zep__out(VDP_CMD, 0x80 | r);
    zep__ei();
}

void zep_vdp_reg(uint8_t r, uint8_t v)
{
    if (r < REG_COUNT)
        shadow[r] = v;
    reg_raw(r, v);
}

uint8_t zep_vdp_reg_get(uint8_t r)
{
    return r < REG_COUNT ? shadow[r] : 0;
}

uint8_t zep_vdp_status(uint8_t s)
{
    uint8_t v;

    zep__di();
    zep__out(VDP_CMD, s);
    zep__out(VDP_CMD, 0x80 | 15);
    v = zep__in(VDP_CMD);
    zep__out(VDP_CMD, 0);
    zep__out(VDP_CMD, 0x80 | 15);
    zep__ei();
    shadow[15] = 0;
    return v;
}

static void vdp_cleanup(void)
{
    zep_vdp_release();
}

/* Baseline state.  The BIOS console leaves native WAIT and the LunchCrema porch
 * on; R#25 keeps WTE set and the configuration latch is not touched. */
static const uint8_t baseline[][2] = {
    { 1, 0x00 },        /* display off, GRAPHIC 1 */
    { 0, 0x00 },
    { 2, 0x00 }, { 3, 0x00 }, { 4, 0x00 }, { 5, 0x00 }, { 6, 0x00 },
    { 7, 0x00 },        /* black border */
    { 8, 0x08 },        /* VR: 64Kx4 DRAMs */
    { 9, 0x00 },
    { 10, 0x00 }, { 11, 0x00 },
    { 14, 0x00 },
    { 23, 0x00 },       /* no vertical scroll */
    { 25, 0x04 },       /* WTE: native WAIT */
    { 26, 0x00 }, { 27, 0x00 },
};

uint8_t zep_vdp_acquire(void)
{
    uint8_t i;

    if (held)
        return ZEP_EBUSY;
    held = 1;
    for (i = 0; i < sizeof(baseline) / sizeof(baseline[0]); i++)
        zep_vdp_reg(baseline[i][0], baseline[i][1]);
    current_mode = ZEP_VDP_G1;
    (void)zep_vdp_status(0);            /* clear any stale interrupt request */
    zep__on_exit(ZEP__MOD_VDP, vdp_cleanup);
    return ZEP_OK;
}

void zep_vdp_release(void)
{
    zep_regs_t r = { 0, 0, 0, 0, 0, 0, 0 };

    if (!held)
        return;
    held = 0;
    (void)zep_bdos_ext(215, &r);        /* VIDEO_SEND A=00h: console reinit */
}

void zep_vdp_palette(uint8_t index, uint8_t red, uint8_t green, uint8_t blue)
{
    zep__di();
    zep__out(VDP_CMD, index & 0x0f);
    zep__out(VDP_CMD, 0x80 | 16);
    zep__out(VDP_PALETTE, ((red & 7) << 4) | (blue & 7));
    zep__out(VDP_PALETTE, green & 7);
    zep__ei();
}

/* Mode bits M5 M4 M3 in R#0 bits 3-1, M2 M1 in R#1 bits 3-4. */
static const uint8_t mode_bits[][2] = {
    /* R#0   R#1 */
    { 0x00, 0x10 },     /* T1: M1 */
    { 0x04, 0x10 },     /* T2: M4 M1 */
    { 0x00, 0x08 },     /* MC: M2 */
    { 0x00, 0x00 },     /* G1 */
    { 0x02, 0x00 },     /* G2: M3 */
    { 0x04, 0x00 },     /* G3: M4 */
    { 0x06, 0x00 },     /* G4: M4 M3 */
    { 0x08, 0x00 },     /* G5: M5 */
    { 0x0a, 0x00 },     /* G6: M5 M3 */
    { 0x0e, 0x00 },     /* G7: M5 M4 M3 */
};

void zep_vdp_mode(zep_vdp_mode_t m, uint8_t flags)
{
    uint8_t r9;

    if ((uint8_t)m > ZEP_VDP_G7)
        return;
    current_mode = m;
    zep_vdp_reg(0, (shadow[0] & 0xf1) | mode_bits[m][0]);
    zep_vdp_reg(1, (shadow[1] & 0xe7) | mode_bits[m][1]);
    r9 = shadow[9] & 0x77;
    if (flags & ZEP_VDP_LINES_212)
        r9 |= 0x80;
    if (flags & ZEP_VDP_INTERLACE)
        r9 |= 0x08;
    zep_vdp_reg(9, r9);
}

void zep_vdp_display(uint8_t on)
{
    zep_vdp_reg(1, on ? (shadow[1] | 0x40) : (shadow[1] & 0xbf));
}

void zep_vdp_vram_seek(uint32_t addr, uint8_t for_write)
{
    uint8_t r14 = (uint8_t)(addr >> 14) & 0x07;

    shadow[14] = r14;
    zep__di();
    zep__out(VDP_CMD, r14);
    zep__out(VDP_CMD, 0x80 | 14);
    zep__out(VDP_CMD, (uint8_t)addr);
    zep__out(VDP_CMD, (((uint8_t)(addr >> 8)) & 0x3f) | (for_write ? 0x40 : 0x00));
    zep__ei();
}

void zep_vdp_vram_write(const uint8_t *src, uint16_t n)
{
    zep__otir(VDP_DATA, src, n);
}

void zep_vdp_vram_read(uint8_t *dst, uint16_t n)
{
    zep__inir(VDP_DATA, dst, n);
}

void zep_vdp_vram_fill(uint32_t addr, uint8_t value, uint32_t n)
{
    uint16_t chunk;

    zep_vdp_vram_seek(addr, 1);
    while (n) {
        chunk = n > 0xffffUL ? 0xffff : (uint16_t)n;
        zep__outn(VDP_DATA, value, chunk);
        n -= chunk;
    }
}

void zep_vdp_command(const zep_vdp_cmd_t *c)
{
    const uint16_t *w = &c->sx;
    uint8_t i;

    zep__di();
    zep__out(VDP_CMD, 32);              /* R#17 = 32, auto-increment */
    zep__out(VDP_CMD, 0x80 | 17);
    zep__ei();
    for (i = 0; i < 6; i++) {
        zep__out(VDP_INDIRECT, (uint8_t)w[i]);
        zep__out(VDP_INDIRECT, (uint8_t)(w[i] >> 8));
    }
    zep__out(VDP_INDIRECT, c->color);
    zep__out(VDP_INDIRECT, c->arg);
    zep__out(VDP_INDIRECT, c->cmd);         /* R#46 last: starts the command */
    shadow[44] = c->color;
    shadow[45] = c->arg;
    shadow[46] = c->cmd;
}

uint8_t zep_vdp_command_busy(void)
{
    return zep_vdp_status(2) & 0x01;
}

void zep_vdp_sprite(uint8_t n, uint8_t x, uint8_t y, uint8_t pattern, uint8_t color)
{
    uint32_t sat;
    uint8_t entry[4];
    uint8_t line[16];
    uint8_t i;

    if (n > 31)
        return;
    sat = ((uint32_t)(shadow[11] & 0x03) << 15) | ((uint32_t)shadow[5] << 7);
    entry[0] = y;
    entry[1] = x;
    entry[2] = pattern;

    if (current_mode >= ZEP_VDP_G3) {
        sat &= ~0x3ffUL;                    /* mode 2: R#5 low bits are 111 */
        entry[3] = 0;
        zep_vdp_vram_seek(sat + (uint32_t)n * 4, 1);
        zep_vdp_vram_write(entry, 4);
        for (i = 0; i < 16; i++)
            line[i] = color & 0x0f;
        zep_vdp_vram_seek(sat - 512 + (uint32_t)n * 16, 1);
        zep_vdp_vram_write(line, 16);
    } else {
        entry[3] = color & 0x0f;
        zep_vdp_vram_seek(sat + (uint32_t)n * 4, 1);
        zep_vdp_vram_write(entry, 4);
    }
}

/* Frame interrupts need BIOS source 4; registration fails until it exists. */
uint8_t zep_vdp_vsync_start(void)
{
    return ZEP_EUNAVAILABLE;
}

void zep_vdp_vsync_stop(void)
{
}

uint8_t zep_vdp_take_frame(void)
{
    return zep_vdp_vblank_poll();
}

uint16_t zep_vdp_frames_missed(void)
{
    return 0;
}

uint8_t zep_vdp_vblank_poll(void)
{
    return (zep_vdp_status(0) & 0x80) ? 1 : 0;
}
