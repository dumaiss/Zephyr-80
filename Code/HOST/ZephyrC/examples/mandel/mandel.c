/* MANDEL.COM -- the direct-V9958 Mandelbrot, ported to ZephyrC.
 *
 * A port of ../../../HelloWorld/src/mandelbrot_v9958_real.asm: the same GRAPHIC
 * 6 interlaced screen, Q2.6 fixed-point arithmetic, palette and colour cycle,
 * so the two images can be compared pixel for pixel.  On top of that it
 * exercises the rest of ZephyrC:
 *
 *   bdos.h    zep_sysinfo
 *   vdp.h     acquire, registers, mode, palette, VRAM writes, release
 *   input.h   raw HID keys: ESC aborts between rows, any key ends the display
 *   timer.h   render time from a CTC tick counter
 *   sound.h   a short chime when the image is complete
 *
 * Usage:  MANDEL [n]    n = CTC channel for the timer (default 0)
 */
#include <stdio.h>
#include <stdlib.h>
#include <zephyr/bdos.h>
#include <zephyr/vdp.h>
#include <zephyr/input.h>
#include <zephyr/timer.h>
#include <zephyr/sound.h>

#define SAMPLE_ROWS  106
#define MAX_ITER     32
#define CX_START     -128        /* X: -2.0 .. +1.984375 in Q2.6 */
#define CY_START     -106        /* Y: -1.65625 .. +1.625 */
#define CY_STEP      2
#define KEY_ESC      0x1b
#define TICK_RATE    100

/* Escape-time colours; entry 0 is non-black so immediate escapes differ from
 * points inside the set. */
static const uint8_t iteration_colors[32] = {
    0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08, 0x07,
    0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x02, 0x03,
};

/* R, G, B components 0-7. */
static const uint8_t palette[16][3] = {
    { 0, 0, 0 }, { 1, 0, 0 }, { 3, 0, 0 }, { 5, 0, 0 },
    { 7, 1, 0 }, { 7, 3, 0 }, { 7, 5, 0 }, { 7, 7, 0 },
    { 3, 7, 0 }, { 0, 7, 0 }, { 0, 7, 3 }, { 0, 7, 7 },
    { 0, 4, 7 }, { 0, 1, 7 }, { 4, 1, 7 }, { 7, 7, 7 },
};

static uint8_t scanline[256];
static int16_t cx, cy;

static uint8_t q26_valid(int16_t v)
{
    return v >= -128 && v <= 127;
}

/* Signed Q2.6 multiply of two values in -128..127, truncating toward zero,
 * exactly as the assembly original does. */
static int16_t mul_q26(int16_t a, int16_t b)
{
    uint8_t ua = (uint8_t)a, ub = (uint8_t)b, negative = 0;
    int16_t r;

    if (ua & 0x80) {
        ua = (uint8_t)-ua;
        negative = 1;
    }
    if (ub & 0x80) {
        ub = (uint8_t)-ub;
        negative ^= 1;
    }
    r = (int16_t)(((uint16_t)ua * ub) >> 6);
    return negative ? -r : r;
}

static uint8_t mandelbrot_point(void)
{
    int16_t zx = 0, zy = 0, zx2, zy2, next_zx;
    uint8_t iteration = 0;

    for (;;) {
        if (!q26_valid(zx) || !q26_valid(zy))
            break;
        zx2 = mul_q26(zx, zx);
        zy2 = mul_q26(zy, zy);
        if ((uint16_t)(zx2 + zy2) >= 0x100)      /* |z|^2 >= 4.0 */
            break;
        if (iteration >= MAX_ITER)
            return 0;
        next_zx = zx2 - zy2 + cx;
        zy = (int16_t)(mul_q26(zx, zy) * 2) + cy;
        zx = next_zx;
        iteration++;
    }
    return iteration_colors[iteration & 0x1f];
}

static void render_row(void)
{
    uint16_t col;
    uint8_t c;

    cx = CX_START;
    for (col = 0; col < 256; col++) {
        c = mandelbrot_point();
        scanline[col] = (uint8_t)(c << 4) | c;   /* one sample, two G6 pixels */
        cx++;
    }
}

/* Raw HID while the VDP is held; console input only if the IO Controller has no
 * keyboard to give, in which case nothing is drawing over us anyway. */
static int read_key(void)
{
    int c = zep_kbd_raw_getc();
    return (c < 0 && !zep_kbd_raw_ok()) ? zep_kbd_getc() : c;
}

static void send_row(uint8_t source_row)
{
    zep_vdp_vram_seek((uint32_t)source_row << 8, 1);
    zep_vdp_vram_write(scanline, sizeof(scanline));
}

static void setup_screen(void)
{
    uint8_t i;

    zep_vdp_mode(ZEP_VDP_G6, ZEP_VDP_LINES_212 | ZEP_VDP_INTERLACE);
    zep_vdp_reg(2, 0x1f);          /* all 256 bitmap lines, page 0 */
    zep_vdp_reg(7, 0x00);          /* black border */
    for (i = 0; i < 16; i++)
        zep_vdp_palette(i, palette[i][0], palette[i][1], palette[i][2]);
    zep_vdp_display(1);
}

/* What the fade actually did, printed after the VDP is released: whether it was
 * paced by ticks or by its own floor, and how many ticks it spent.  A chime
 * nobody hears is either not reaching the chip or passing in microseconds, and
 * these two numbers say which. */
static uint8_t chime_floor_steps;
static uint16_t chime_ticks_used;

/* Roughly 60 ms at 10 MHz -- a floor, not a clock.  volatile because an empty
 * loop is otherwise optimised away, which is how TONETEST lost its delays. */
static void chime_floor(void)
{
    volatile uint16_t i;

    for (i = 0; i < 8000; i++)
        ;
}

/* A C major chord on PSG0, faded out over about a second of timer ticks. */
static void chime(uint8_t timer_ok, uint8_t timer_channel)
{
    static const uint16_t notes[3] = { 523, 659, 784 };
    uint8_t n, level, wait;
    uint16_t spin;

    zep_sound_init();

    /* Rendering banks up ticks -- the queue counts produced against consumed in
     * a byte, so up to 255 of them are already waiting -- and the fade below
     * spends eight per step.  Without draining them first every step is
     * satisfied instantly and the whole chime passes in microseconds, which is
     * heard as no chime at all.  Drain first, then wait only on ticks that
     * arrive during the chime itself. */
    if (timer_ok)
        while (zep_timer_take_tick(timer_channel))
            ;

    for (n = 0; n < 3; n++) {
        (void)zep_sound_tone(n, zep_sound_period_for_hz(notes[n]));
        zep_sound_volume(n, 2);
    }
    for (level = 3; level <= 15; level++) {
        /* Wait on ticks when they arrive, but never wait forever: a timer that
         * is registered yet silent must not stretch the fade. */
        for (wait = 8, spin = 0; wait && spin < 4000U; spin++)
            if (timer_ok && zep_timer_take_tick(timer_channel)) {
                wait--;
                chime_ticks_used++;
            }
        /* The spin cap is an escape, not a duration: 4000 iterations of a call
         * that returns nothing is a few milliseconds, so a fade that falls back
         * on it 13 times is over before it can be heard.  Pace those steps. */
        if (wait) {
            chime_floor_steps++;
            chime_floor();
        }
        for (n = 0; n < 3; n++)
            zep_sound_volume(n, level);
    }
    zep_sound_mute_all();
}

/* Is the channel actually interrupting, before the VDP is touched?  MANDEL only
 * reads the count once, at the end, so a channel that stops part way through and
 * one that never started look identical.  Spins for a second or so; volatile
 * because an empty loop is otherwise optimised away. */
static void probe_ticks(uint8_t channel)
{
    volatile uint16_t i, j;
    uint32_t before = zep_timer_count(channel);

    for (i = 0; i < 400; i++)
        for (j = 0; j < 1000; j++)
            ;
    printf("probe: CTC%u raw count %lu -> %lu before the render\n",
           channel, before, zep_timer_count(channel));
}

int main(int argc, char **argv)
{
    const zep_sysinfo_t *si = zep_sysinfo();
    uint8_t timer_channel = 0, timer_ok, aborted = 0, row;
    uint32_t base_ticks;
    int key;

    printf("MANDEL - ZephyrC V9958 demo\n");
    if (si)
        printf("Zephyr BIOS, IOC transport level %u\n", si->ioc_level);
    else
        printf("Not a Zephyr BIOS: BIOS services will be unavailable\n");

    if (argc > 1)
        timer_channel = (uint8_t)atoi(argv[1]) & 3;
    timer_ok = zep_timer_start(timer_channel, TICK_RATE) == ZEP_OK;
    if (!timer_ok)
        printf("CTC%u timer unavailable; no render time\n", timer_channel);
    if (timer_ok && argc > 2)
        probe_ticks(timer_channel);

    if (zep_vdp_acquire() != ZEP_OK) {
        printf("V9958 is busy\n");
        return 1;
    }
    setup_screen();

    cy = CY_START;
    for (row = 0; row < SAMPLE_ROWS; row++) {
        key = read_key();
        if (key == KEY_ESC) {
            aborted = 1;
            break;
        }
        render_row();
        send_row((uint8_t)(row * 2));
        send_row((uint8_t)(row * 2 + 1));
        cy += CY_STEP;
    }
    base_ticks = timer_ok ? zep_timer_count(timer_channel) : 0;

    if (!aborted) {
        chime(timer_ok, timer_channel);
        while (read_key() < 0)
            ;
    }

    zep_vdp_release();             /* the console is back: printing is safe */
    if (aborted)
        printf("Aborted.\n");
    else
        printf("chime: %u of 13 steps paced by the floor, %u ticks consumed\n",
               chime_floor_steps, chime_ticks_used);
    if (timer_ok) {
        printf("CTC%u: %lu interrupts", timer_channel, base_ticks);
        if (base_ticks)
            printf(", render time %lu.%02lu s",
                   base_ticks / 180, (base_ticks % 180) * 100 / 180);
        else
            printf(" -- the channel is registered but never fired");
        printf("\n");
    }
    return 0;
}
