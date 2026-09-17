/* vdp.h -- direct access to the LunchCrema V9958.
 *
 * While a program holds the VDP it must not print to the console: the BIOS
 * console would draw into the program's VRAM and registers.
 * See DOC/API.md section 5.
 */
#ifndef ZEPHYR_VDP_H
#define ZEPHYR_VDP_H

#include <zephyr/zephyr.h>

/* Take the VDP.  Writes a known baseline: display off, GRAPHIC 1, native WAIT
 * on (R#25), VR for the 64Kx4 DRAMs (R#8).  The porch stays as the BIOS left it. */
uint8_t  zep_vdp_acquire(void);
/* Give it back: the BIOS console reinitialises (VIDEO_SEND A=00h). */
void     zep_vdp_release(void);

void     zep_vdp_reg(uint8_t r, uint8_t v);
uint8_t  zep_vdp_reg_get(uint8_t r);          /* the value last written */
uint8_t  zep_vdp_status(uint8_t s);           /* S#s; S#0 is reselected after */
void     zep_vdp_palette(uint8_t index, uint8_t r, uint8_t g, uint8_t b); /* 0-7 */

typedef enum {
    ZEP_VDP_T1, ZEP_VDP_T2, ZEP_VDP_MC,
    ZEP_VDP_G1, ZEP_VDP_G2, ZEP_VDP_G3,
    ZEP_VDP_G4, ZEP_VDP_G5, ZEP_VDP_G6, ZEP_VDP_G7
} zep_vdp_mode_t;
#define ZEP_VDP_LINES_212   0x01
#define ZEP_VDP_INTERLACE   0x02
/* Sets the mode bits (R#0, R#1) and R#9 LN/IL; other registers are untouched. */
void     zep_vdp_mode(zep_vdp_mode_t m, uint8_t flags);
void     zep_vdp_display(uint8_t on);

/* VRAM, 17-bit addresses. */
void     zep_vdp_vram_seek(uint32_t addr, uint8_t for_write);
void     zep_vdp_vram_write(const uint8_t *src, uint16_t n);
void     zep_vdp_vram_read(uint8_t *dst, uint16_t n);
void     zep_vdp_vram_fill(uint32_t addr, uint8_t value, uint32_t n);

/* Command engine. */
typedef struct {
    uint16_t sx, sy, dx, dy, nx, ny;
    uint8_t  color, arg, cmd;             /* R#44, R#45, R#46 */
} zep_vdp_cmd_t;
void     zep_vdp_command(const zep_vdp_cmd_t *c);
uint8_t  zep_vdp_command_busy(void);

/* Sprites: mode 1 in G1-G2/MC, mode 2 in G3-G7. */
void     zep_vdp_sprite(uint8_t n, uint8_t x, uint8_t y, uint8_t pattern, uint8_t color);

/* Frames.  The interrupt path needs BIOS source 4, which does not exist yet:
 * zep_vdp_vsync_start returns ZEP_EUNAVAILABLE until it does. */
uint8_t  zep_vdp_vsync_start(void);
void     zep_vdp_vsync_stop(void);
uint8_t  zep_vdp_take_frame(void);
uint16_t zep_vdp_frames_missed(void);
uint8_t  zep_vdp_vblank_poll(void);           /* 1 once per frame; reads S#0 */

#endif
