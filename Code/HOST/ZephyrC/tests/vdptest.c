/* VDPTEST.COM -- step-by-step check of the VDP path.
 *
 * Prints before and after each step, so a run that stops says where.  The
 * pattern it draws is four horizontal bands, one per palette group.
 */
#include <stdio.h>
#include <zephyr/bdos.h>
#include <zephyr/vdp.h>
#include <zephyr/input.h>

static uint8_t line[256];

int main(void)
{
    uint8_t r, row, i;

    printf("VDPTEST start\n");
    printf("sysinfo: %s\n", zep_sysinfo() ? "Zephyr BIOS" : "none");

    r = zep_vdp_acquire();
    printf("acquire: %u\n", r);
    if (r != ZEP_OK)
        return 1;

    zep_vdp_mode(ZEP_VDP_G6, ZEP_VDP_LINES_212 | ZEP_VDP_INTERLACE);
    zep_vdp_reg(2, 0x1f);
    for (i = 0; i < 16; i++)
        zep_vdp_palette(i, (uint8_t)(i & 7), (uint8_t)((i >> 1) & 7), (uint8_t)(7 - (i & 7)));
    zep_vdp_display(1);

    for (row = 0; row < 212; row++) {
        uint8_t c = (uint8_t)(row >> 4) & 0x0f;
        for (i = 0; i < 255; i++)
            line[i] = (uint8_t)(c << 4) | c;
        line[255] = (uint8_t)(c << 4) | c;
        zep_vdp_vram_seek((uint32_t)row << 8, 1);
        zep_vdp_vram_write(line, sizeof(line));
    }
    printf("drawn; any key\n");     /* buffered: the console cannot draw yet */
    while (zep_kbd_raw_getc() < 0)
        if (!zep_kbd_raw_ok())
            break;         /* no HID keyboard here: do not wait for ever */
    zep_vdp_release();
    printf("VDPTEST done\n");
    return 0;
}
