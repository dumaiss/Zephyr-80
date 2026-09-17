/* input.h -- USB keyboard and gamepads through the IO Controller.
 * See DOC/API.md section 9.
 */
#ifndef ZEPHYR_INPUT_H
#define ZEPHYR_INPUT_H

#include <zephyr/zephyr.h>

/* Keyboard, through BDOS so the console and the program never race for keys.
 * Terminal bytes; cursor keys arrive as VT100 sequences. */
int      zep_kbd_getc(void);          /* -1 when nothing is waiting */
uint8_t  zep_kbd_hit(void);

/* Keyboard straight from the IO Controller, bypassing the console.
 *
 * A program holding the VDP must use this, not zep_kbd_getc: the BIOS console's
 * V9958 driver writes to the VDP during CONST -- it flushes pending text, moves
 * its cursor sprite and presents -- which corrupts the screen and the address
 * latch of whoever is drawing.  Keys taken here do not reach CONST, which is
 * what you want while the program owns the screen.
 *
 * Same byte stream as zep_kbd_getc: terminal bytes, cursor keys as VT100. */
int      zep_kbd_raw_getc(void);      /* -1 when nothing is waiting */
/* 0 once the IO Controller has refused or failed a raw read: there is no HID
 * keyboard to read from, and a program waiting only on raw keys would wait for
 * ever.  Fall back to zep_kbd_getc, after giving the VDP back if it holds it. */
uint8_t  zep_kbd_raw_ok(void);

/* Key state needs CMD_HID_KEYSTATE in the IO Controller: ZEP_EUNAVAILABLE today. */
uint8_t  zep_kbd_state(uint8_t bitmap[32]);
uint8_t  zep_kbd_down(uint8_t hid_usage);

/* Gamepads, from the Coleco-format controller latches. */
#define ZEP_PAD_UP      0x01
#define ZEP_PAD_RIGHT   0x02
#define ZEP_PAD_DOWN    0x04
#define ZEP_PAD_LEFT    0x08
#define ZEP_PAD_FIRE    0x10

uint8_t  zep_pad_read(uint8_t pad);       /* pad 0-1; bits set while pressed */
uint8_t  zep_pad_raw(uint8_t pad);        /* the active-low latch byte */
uint8_t  zep_pad_connected(uint8_t pad);  /* 1 if the controller reports a pad */

typedef struct {
    uint8_t  connected;
    uint16_t buttons;
    uint8_t  hat;
    int8_t   lx, ly, rx, ry;
} zep_pad_t;
/* Needs CMD_HID_PADSTATE in the IO Controller: ZEP_EUNAVAILABLE today. */
uint8_t  zep_pad_state(uint8_t pad, zep_pad_t *out);

#endif
