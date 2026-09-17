/* zep_input.c -- keyboard through BDOS, gamepads through the controller latches. */
#include <cpm.h>
#include <zephyr/input.h>
#include <zephyr/bdos.h>
#include "zep_internal.h"

#define PAD0_PORT         0xfc     /* Coleco addresses; to be confirmed on hardware */
#define PAD1_PORT         0xff

#define CMD_HID_STATUS    0x0d
#define RSP_HID_STATUS    0x8d
#define HID_PAGE_GAMEPAD  0x06
#define HID_PAD_LEN       26
#define RX_PAD0_ADDR      15
#define RX_PAD1_ADDR      22

int zep_kbd_getc(void)
{
    uint8_t c = (uint8_t)bdos(6, 0xff);
    return c ? c : -1;
}

uint8_t zep_kbd_hit(void)
{
    return (uint8_t)bdos(11, 0) ? 1 : 0;
}

/* CMD_HID_INPUT is a non-blocking dequeue: request one byte saying how many are
 * wanted, reply carries how many are still queued, how many key sequences were
 * dropped, then the translated bytes. */
#define CMD_HID_INPUT     0x0e
#define RSP_HID_INPUT     0x8e
#define RX_HID_DATA       6
#define RX_HID_META       2

static uint8_t kbd_buf[24], kbd_len, kbd_pos;
static uint8_t kbd_raw_failed;

uint8_t zep_kbd_raw_ok(void)
{
    return kbd_raw_failed ? 0 : 1;
}

int zep_kbd_raw_getc(void)
{
    static uint8_t tx[32], rx[32];
    uint8_t i, n;

    if (kbd_pos < kbd_len)
        return kbd_buf[kbd_pos++];
    if (kbd_raw_failed)
        return -1;

    for (i = 0; i < 32; i++)
        tx[i] = 0;
    tx[0] = CMD_HID_INPUT;
    tx[3] = 1;
    tx[4] = sizeof(kbd_buf);
    if (zep_ioc_call(tx, rx) != 0) {
        kbd_raw_failed = 1;
        return -1;
    }
    if (rx[0] != RSP_HID_INPUT || rx[2] != 0 || rx[3] < RX_HID_META) {
        kbd_raw_failed = 1;
        return -1;
    }

    n = (uint8_t)(rx[3] - RX_HID_META);
    if (n > sizeof(kbd_buf))
        n = sizeof(kbd_buf);
    for (i = 0; i < n; i++)
        kbd_buf[i] = rx[RX_HID_DATA + i];
    kbd_len = n;
    kbd_pos = 0;
    if (!n)
        return -1;
    return kbd_buf[kbd_pos++];
}

uint8_t zep_kbd_state(uint8_t bitmap[32])
{
    (void)bitmap;
    return ZEP_EUNAVAILABLE;
}

uint8_t zep_kbd_down(uint8_t hid_usage)
{
    (void)hid_usage;
    return 0;
}

uint8_t zep_pad_raw(uint8_t pad)
{
    if (pad > 1)
        return 0xff;
    return zep__in(pad ? PAD1_PORT : PAD0_PORT);
}

/* The latch has no Coleco keypad/joystick select, so its keypad substitutes are
 * indistinguishable from d-pad combinations.  Only directions and fire decode. */
uint8_t zep_pad_read(uint8_t pad)
{
    uint8_t pressed = (uint8_t)~zep_pad_raw(pad);
    return (pressed & 0x0f) | ((pressed & 0x40) ? ZEP_PAD_FIRE : 0);
}

uint8_t zep_pad_connected(uint8_t pad)
{
    static uint8_t tx[32], rx[32];
    uint8_t i;

    if (pad > 1)
        return 0;
    for (i = 0; i < 32; i++)
        tx[i] = 0;
    tx[0] = CMD_HID_STATUS;
    tx[3] = 1;
    tx[4] = HID_PAGE_GAMEPAD;
    if (zep_ioc_call(tx, rx) != 0)
        return 0;
    if (rx[0] != RSP_HID_STATUS || rx[2] != 0 || rx[3] != HID_PAD_LEN || rx[4] != HID_PAGE_GAMEPAD)
        return 0;
    return rx[pad ? RX_PAD1_ADDR : RX_PAD0_ADDR] != 0;
}

uint8_t zep_pad_state(uint8_t pad, zep_pad_t *out)
{
    (void)pad;
    (void)out;
    return ZEP_EUNAVAILABLE;
}
