#include "input_keyboard.h"

#include "display_libvncserver.h"
#include "protocol.h"
#include "protocol_debug.h"

#include <stdio.h>

/*
 * LibVNCServer supplies X11-style keysyms. This module maps a deliberately
 * small subset to terminal input bytes. It never writes serial directly; the
 * display callback only enqueues packets for KeyboardTransport's writer thread.
 */

typedef struct {
    bool mapped;
    uint8_t bytes[4];
    uint8_t length;
} TerminalMapping;

/* Modifier keysyms are tracked but do not generate terminal input bytes. */
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

#define KEY_MODIFIER_SHIFT (1u << 0)
#define KEY_MODIFIER_CTRL  (1u << 1)
#define KEY_MODIFIER_ALT   (1u << 2)
#define KEY_MODIFIER_META  (1u << 3)

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

static TerminalMapping terminal_mapping_bytes(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t b3, uint8_t length)
{
    TerminalMapping mapping = {
        .mapped = true,
        .bytes = { b0, b1, b2, b3 },
        .length = length,
    };
    return mapping;
}

static TerminalMapping map_display_keysym_to_terminal(uint32_t keysym)
{
    TerminalMapping unmapped = { 0 };

    if (keysym >= 0x20 && keysym <= 0x7E) {
        return terminal_mapping_bytes((uint8_t)keysym, 0, 0, 0, 1);
    }

    switch (keysym) {
    case DISPLAY_KEY_RETURN:
        return terminal_mapping_bytes(0x0D, 0, 0, 0, 1);
    case DISPLAY_KEY_BACKSPACE:
        return terminal_mapping_bytes(0x08, 0, 0, 0, 1);
    case DISPLAY_KEY_TAB:
        return terminal_mapping_bytes(0x09, 0, 0, 0, 1);
    case DISPLAY_KEY_ESCAPE:
        return terminal_mapping_bytes(0x1B, 0, 0, 0, 1);
    case DISPLAY_KEY_UP:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x41, 0, 3);
    case DISPLAY_KEY_DOWN:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x42, 0, 3);
    case DISPLAY_KEY_RIGHT:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x43, 0, 3);
    case DISPLAY_KEY_LEFT:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x44, 0, 3);
    case DISPLAY_KEY_HOME:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x48, 0, 3);
    case DISPLAY_KEY_END:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x46, 0, 3);
    case DISPLAY_KEY_DELETE:
        return terminal_mapping_bytes(0x1B, 0x5B, 0x33, 0x7E, 4);
    default:
        return unmapped;
    }
}

static void log_terminal_payload(const char *prefix, const uint8_t *payload, uint8_t length)
{
    printf("%s", prefix);
    print_payload_hex(payload, length);
    printf("\n");
}

void input_keyboard_init(
    InputKeyboardContext *ctx,
    KeyboardTransport *keyboard_transport,
    bool enabled,
    bool log_keys)
{
    ctx->keyboard_transport = keyboard_transport;
    ctx->enabled = enabled;
    ctx->log_keys = log_keys;
    ctx->modifiers = 0;
}

void input_keyboard_handle_display_key(InputKeyboardContext *ctx, bool down, uint32_t keysym)
{
    uint8_t modifier_bit = modifier_bit_for_keysym(keysym);
    update_modifier_state(ctx, down, modifier_bit);

    if (!ctx->enabled) {
        if (ctx->log_keys) {
            printf("Keyboard event ignored: capture disabled keysym=0x%08X %s\n", keysym, down ? "down" : "up");
        }
        return;
    }

    if (!down) {
        if (ctx->log_keys) {
            printf("Keyboard key-up ignored: keysym=0x%08X\n", keysym);
        }
        return;
    }

    keyboard_transport_note_keyboard_event(ctx->keyboard_transport);

    TerminalMapping mapping = map_display_keysym_to_terminal(keysym);
    if (!mapping.mapped || mapping.length == 0) {
        if (modifier_bit == 0) {
            keyboard_transport_note_unsupported_key(ctx->keyboard_transport);
            if (ctx->log_keys) {
                printf("Keyboard terminal input ignored: unsupported keysym=0x%08X\n", keysym);
            }
        }
        return;
    }

    if (ctx->keyboard_transport == NULL) {
        if (ctx->log_keys) {
            log_terminal_payload("Keyboard terminal packet not queued: no transport bytes=", mapping.bytes, mapping.length);
        }
        return;
    }

    bool queued = keyboard_transport_enqueue(
        ctx->keyboard_transport,
        PACKET_TERMINAL_INPUT,
        mapping.bytes,
        mapping.length);

    if (ctx->log_keys) {
        log_terminal_payload(
            queued ? "Keyboard terminal packet queued: " : "Keyboard terminal packet queue dropped: ",
            mapping.bytes,
            mapping.length);
    }
}

void input_keyboard_display_key_callback(bool down, uint32_t keysym, void *userdata)
{
    InputKeyboardContext *ctx = (InputKeyboardContext *)userdata;
    input_keyboard_handle_display_key(ctx, down, keysym);
}
