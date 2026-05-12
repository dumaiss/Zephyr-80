#include "input_keyboard.h"

#include "display_libvncserver.h"
#include "protocol.h"
#include "protocol_debug.h"

#include <stdio.h>

/*
 * LibVNCServer supplies X11-style keysyms. This module maps the subset Virtual
 * Drip currently exposes into KEY_EVENT packets and leaves host-side text
 * editing, escape-sequence policy, and keyboard layout semantics to Zephyr.
 */

/** Mapping result for one display keysym. */
typedef struct {
    /* false when the keysym is neither supported nor a tracked modifier. */
    bool mapped;
    /* Printable/control ASCII value for KEY_EVENT byte 1, or 0. */
    uint8_t ascii;
    /* Non-ASCII key code for KEY_EVENT byte 2, or KEY_SPECIAL_NONE. */
    KeySpecialCode special;
} KeyMapping;

/* Modifier keysyms are tracked even though they do not carry ASCII/special codes. */
typedef enum {
    DISPLAY_KEY_SHIFT_L = 0xFFE1,
    DISPLAY_KEY_SHIFT_R = 0xFFE2,
    DISPLAY_KEY_CTRL_L = 0xFFE3,
    DISPLAY_KEY_CTRL_R = 0xFFE4,
    DISPLAY_KEY_META_L = 0xFFE7,
    DISPLAY_KEY_META_R = 0xFFE8,
    DISPLAY_KEY_ALT_L = 0xFFE9,
    DISPLAY_KEY_ALT_R = 0xFFEA,
    DISPLAY_KEY_SUPER_L = 0xFFEB,
    DISPLAY_KEY_SUPER_R = 0xFFEC,
    DISPLAY_KEY_MODE_SWITCH = 0xFF7E,
    DISPLAY_KEY_ISO_LEVEL3_SHIFT = 0xFE03,
} DisplayModifierKeySymbol;

static uint8_t modifier_bit_for_keysym(uint32_t keysym)
{
    switch (keysym) {
    case DISPLAY_KEY_SHIFT_L:
    case DISPLAY_KEY_SHIFT_R:
        return KEY_MODIFIER_SHIFT;
    case DISPLAY_KEY_CTRL_L:
    case DISPLAY_KEY_CTRL_R:
        return KEY_MODIFIER_CTRL;
    case DISPLAY_KEY_ALT_L:
    case DISPLAY_KEY_ALT_R:
    case DISPLAY_KEY_MODE_SWITCH:
    case DISPLAY_KEY_ISO_LEVEL3_SHIFT:
        return KEY_MODIFIER_ALT;
    case DISPLAY_KEY_META_L:
    case DISPLAY_KEY_META_R:
    case DISPLAY_KEY_SUPER_L:
    case DISPLAY_KEY_SUPER_R:
        return KEY_MODIFIER_META;
    default:
        return 0;
    }
}

static void update_modifier_state(InputKeyboardContext *ctx, bool down, uint8_t modifier_bit)
{
    if (modifier_bit == 0) {
        return;
    }

    if (down) {
        ctx->modifiers |= modifier_bit;
    } else {
        ctx->modifiers &= (uint8_t)~modifier_bit;
    }
}

static KeyMapping map_display_keysym(uint32_t keysym)
{
    KeyMapping mapping = {
        .mapped = true,
        .ascii = 0,
        .special = KEY_SPECIAL_NONE,
    };

    /* Printable keysyms are already ASCII in the common RFB/X11 range. */
    if (keysym >= 0x20 && keysym <= 0x7E) {
        mapping.ascii = (uint8_t)keysym;
        return mapping;
    }

    switch (keysym) {
    case DISPLAY_KEY_RETURN:
        mapping.ascii = 0x0D;
        return mapping;
    case DISPLAY_KEY_BACKSPACE:
        mapping.ascii = 0x08;
        return mapping;
    case DISPLAY_KEY_TAB:
        mapping.ascii = 0x09;
        return mapping;
    case DISPLAY_KEY_ESCAPE:
        mapping.ascii = 0x1B;
        return mapping;
    case DISPLAY_KEY_LEFT:
        mapping.special = KEY_SPECIAL_LEFT;
        return mapping;
    case DISPLAY_KEY_RIGHT:
        mapping.special = KEY_SPECIAL_RIGHT;
        return mapping;
    case DISPLAY_KEY_UP:
        mapping.special = KEY_SPECIAL_UP;
        return mapping;
    case DISPLAY_KEY_DOWN:
        mapping.special = KEY_SPECIAL_DOWN;
        return mapping;
    case DISPLAY_KEY_HOME:
        mapping.special = KEY_SPECIAL_HOME;
        return mapping;
    case DISPLAY_KEY_END:
        mapping.special = KEY_SPECIAL_END;
        return mapping;
    case DISPLAY_KEY_PAGE_UP:
        mapping.special = KEY_SPECIAL_PAGE_UP;
        return mapping;
    case DISPLAY_KEY_PAGE_DOWN:
        mapping.special = KEY_SPECIAL_PAGE_DOWN;
        return mapping;
    case DISPLAY_KEY_DELETE:
        mapping.special = KEY_SPECIAL_DELETE;
        return mapping;
    case DISPLAY_KEY_INSERT:
        mapping.special = KEY_SPECIAL_INSERT;
        return mapping;
    default:
        if (keysym >= DISPLAY_KEY_F1 && keysym <= DISPLAY_KEY_F12) {
            mapping.special = (KeySpecialCode)(KEY_SPECIAL_F1 + (keysym - DISPLAY_KEY_F1));
            return mapping;
        }
        mapping.mapped = false;
        return mapping;
    }
}

void input_keyboard_init(InputKeyboardContext *ctx, SerialPort *serial_port, bool enabled, bool log_keys)
{
    ctx->serial_port = serial_port;
    ctx->enabled = enabled;
    ctx->log_keys = log_keys;
    ctx->modifiers = 0;
}

void input_keyboard_handle_display_key(InputKeyboardContext *ctx, bool down, uint32_t keysym)
{
    if (!ctx->enabled) {
        if (ctx->log_keys) {
            printf("Keyboard event ignored: capture disabled keysym=0x%08X %s\n", keysym, down ? "down" : "up");
        }
        return;
    }

    uint8_t modifier_bit = modifier_bit_for_keysym(keysym);
    update_modifier_state(ctx, down, modifier_bit);

    KeyMapping mapping = map_display_keysym(keysym);
    if (!mapping.mapped) {
        if (ctx->log_keys && modifier_bit == 0) {
            printf("Keyboard event ignored: unmapped keysym=0x%08X %s\n", keysym, down ? "down" : "up");
        }
        if (modifier_bit == 0) {
            return;
        }
    }

    uint8_t flags = down ? KEY_EVENT_FLAG_DOWN : KEY_EVENT_FLAG_UP;
    if (mapping.mapped && mapping.ascii != 0) {
        flags |= KEY_EVENT_FLAG_HAS_ASCII;
    }
    if (mapping.mapped && mapping.special != KEY_SPECIAL_NONE) {
        flags |= KEY_EVENT_FLAG_HAS_SPECIAL;
    }

    uint8_t payload[] = {
        flags,
        mapping.mapped ? mapping.ascii : 0,
        mapping.mapped ? (uint8_t)mapping.special : 0,
        ctx->modifiers,
    };

    if (ctx->log_keys) {
        printf(
            "Keyboard event: %s keysym=0x%08X ascii=0x%02X special=%s(0x%02X) modifiers=0x%02X\n",
            down ? "down" : "up",
            keysym,
            payload[1],
            key_special_name((KeySpecialCode)payload[2]),
            payload[2],
            payload[3]);
    }

    if (ctx->serial_port == NULL) {
        if (ctx->log_keys) {
            printf("Keyboard packet not sent: no serial transmit port is open\n");
        }
        return;
    }

    /* SerialPort owns framing, CRC, and TX locking for the outbound packet. */
    bool sent = serial_port_send_packet(ctx->serial_port, PACKET_KEY_EVENT, payload, sizeof(payload));
    if (ctx->log_keys) {
        Packet packet;
        packet.length = sizeof(payload);
        packet.type = PACKET_KEY_EVENT;
        for (uint8_t index = 0; index < packet.length; ++index) {
            packet.payload[index] = payload[index];
        }
        packet.crc = packet_crc8(&packet);

        uint8_t bytes[4 + MAX_PACKET_PAYLOAD];
        bytes[0] = PACKET_SYNC;
        bytes[1] = packet.length;
        bytes[2] = packet.type;
        for (uint8_t index = 0; index < packet.length; ++index) {
            bytes[3 + index] = packet.payload[index];
        }
        bytes[3 + packet.length] = packet.crc;

        printf("Keyboard packet %s: ", sent ? "sent" : "send failed");
        print_packet_bytes(bytes, (size_t)packet.length + 4);
        printf("\n");
    }
}

void input_keyboard_display_key_callback(bool down, uint32_t keysym, void *userdata)
{
    InputKeyboardContext *ctx = (InputKeyboardContext *)userdata;
    input_keyboard_handle_display_key(ctx, down, keysym);
}
