#include "input_keyboard.h"

#include "display_libvncserver.h"
#include "keyboard_transport.h"
#include "protocol_debug.h"

#include <stdio.h>
#include <string.h>

/*
 * LibVNCServer supplies X11-style keysyms. This module maps a deliberately
 * small subset to terminal input bytes. It never writes serial directly; the
 * display callback only enqueues raw bytes for KeyboardTransport's writer
 * thread.
 *
 * Ctrl+Shift+letter is intentionally identical to Ctrl+letter in terminal
 * byte streams. Shift does not affect Ctrl-letter output.
 *
 * Right Alt (AltGr) is not treated as the Alt meta modifier; it produces
 * extended characters via host keyboard layout. Left Alt produces the ESC
 * prefix used for meta sequences.
 */

typedef struct {
    bool mapped;
    uint8_t bytes[KEYBOARD_INPUT_MAX_BYTES];
    uint8_t length;
} TerminalMapping;

/* Modifier keysyms are tracked but do not generate terminal input bytes. */
typedef enum {
    DISPLAY_KEY_SHIFT_L          = 0xFFE1,
    DISPLAY_KEY_SHIFT_R          = 0xFFE2,
    DISPLAY_KEY_CTRL_L           = 0xFFE3,
    DISPLAY_KEY_CTRL_R           = 0xFFE4,
    DISPLAY_KEY_META_L           = 0xFFE7,
    DISPLAY_KEY_META_R           = 0xFFE8,
    DISPLAY_KEY_ALT_L            = 0xFFE9,
    DISPLAY_KEY_ALT_R            = 0xFFEA,
    DISPLAY_KEY_SUPER_L          = 0xFFEB,
    DISPLAY_KEY_SUPER_R          = 0xFFEC,
    DISPLAY_KEY_MODE_SWITCH      = 0xFF7E,
    DISPLAY_KEY_ISO_LEVEL3_SHIFT = 0xFE03,
} DisplayModifierKeySymbol;

#define KEY_MODIFIER_SHIFT  (1u << 0)
#define KEY_MODIFIER_CTRL   (1u << 1)
#define KEY_MODIFIER_ALT    (1u << 2)
#define KEY_MODIFIER_META   (1u << 3)
/* AltGr/Right-Alt: tracked so it is not counted as unsupported, but never
 * used for ESC-prefix meta sequences. */
#define KEY_MODIFIER_ALTGR  (1u << 4)

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
        return KEY_MODIFIER_ALT;
    case DISPLAY_KEY_ALT_R:
    case DISPLAY_KEY_MODE_SWITCH:
    case DISPLAY_KEY_ISO_LEVEL3_SHIFT:
        return KEY_MODIFIER_ALTGR;
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

/* Build a TerminalMapping from a byte array of known length. */
static TerminalMapping tmap(const uint8_t *b, uint8_t n)
{
    TerminalMapping m;
    m.mapped = true;
    m.length = n;
    memcpy(m.bytes, b, n);
    return m;
}

#define T1(b0)             tmap((const uint8_t[]){b0}, 1)
#define T2(b0,b1)          tmap((const uint8_t[]){b0,b1}, 2)
#define T3(b0,b1,b2)       tmap((const uint8_t[]){b0,b1,b2}, 3)
#define T4(b0,b1,b2,b3)    tmap((const uint8_t[]){b0,b1,b2,b3}, 4)
#define T5(b0,b1,b2,b3,b4) tmap((const uint8_t[]){b0,b1,b2,b3,b4}, 5)

/* Prepend 0x1B to a mapping for Alt/meta prefix. */
static TerminalMapping prepend_escape(TerminalMapping m)
{
    memmove(m.bytes + 1, m.bytes, m.length);
    m.bytes[0] = 0x1B;
    m.length++;
    return m;
}

static TerminalMapping map_display_keysym_to_terminal(uint32_t keysym, uint8_t modifiers)
{
    const TerminalMapping unmapped = { 0 };
    bool ctrl = (modifiers & KEY_MODIFIER_CTRL) != 0;
    bool alt  = (modifiers & KEY_MODIFIER_ALT) != 0;

    TerminalMapping base = unmapped;

    if (ctrl) {
        /* Ctrl+letter -> control byte 0x01..0x1A.
         * Ctrl+Shift+letter is indistinguishable from Ctrl+letter in a
         * terminal byte stream; both produce the same control byte. */
        if (keysym >= 'A' && keysym <= 'Z') {
            base = T1((uint8_t)(keysym - 'A' + 1));
        } else if (keysym >= 'a' && keysym <= 'z') {
            base = T1((uint8_t)(keysym - 'a' + 1));
        } else {
            switch (keysym) {
            case ' ':  base = T1(0x00); break;
            case '[':  base = T1(0x1B); break;
            case '\\': base = T1(0x1C); break;
            case ']':  base = T1(0x1D); break;
            case '^':  base = T1(0x1E); break;
            case '_':  base = T1(0x1F); break;
            case '?':  base = T1(0x7F); break;
            default:   break;
            }
        }
    }

    /* Printable ASCII (Ctrl not active, or no Ctrl mapping found above). */
    if (!base.mapped && keysym >= 0x20 && keysym <= 0x7E) {
        base = T1((uint8_t)keysym);
    }

    if (!base.mapped) {
        switch (keysym) {
        /* Basic editing */
        case DISPLAY_KEY_RETURN:    base = T1(0x0D); break;
        case DISPLAY_KEY_BACKSPACE: base = T1(0x08); break;
        case DISPLAY_KEY_TAB:       base = T1(0x09); break;
        case DISPLAY_KEY_ESCAPE:    base = T1(0x1B); break;

        /* Arrow keys: ESC [ A/B/C/D */
        case DISPLAY_KEY_UP:    base = T3(0x1B, 0x5B, 0x41); break;
        case DISPLAY_KEY_DOWN:  base = T3(0x1B, 0x5B, 0x42); break;
        case DISPLAY_KEY_RIGHT: base = T3(0x1B, 0x5B, 0x43); break;
        case DISPLAY_KEY_LEFT:  base = T3(0x1B, 0x5B, 0x44); break;

        /* Navigation/editing: ANSI/xterm sequences */
        case DISPLAY_KEY_HOME:      base = T3(0x1B, 0x5B, 0x48);             break;
        case DISPLAY_KEY_END:       base = T3(0x1B, 0x5B, 0x46);             break;
        case DISPLAY_KEY_INSERT:    base = T4(0x1B, 0x5B, 0x32, 0x7E);       break;
        case DISPLAY_KEY_DELETE:    base = T4(0x1B, 0x5B, 0x33, 0x7E);       break;
        case DISPLAY_KEY_PAGE_UP:   base = T4(0x1B, 0x5B, 0x35, 0x7E);       break;
        case DISPLAY_KEY_PAGE_DOWN: base = T4(0x1B, 0x5B, 0x36, 0x7E);       break;

        /* F1-F4: VT100/DEC PF-key style ESC O P/Q/R/S */
        case DISPLAY_KEY_F1: base = T3(0x1B, 0x4F, 0x50); break;
        case DISPLAY_KEY_F2: base = T3(0x1B, 0x4F, 0x51); break;
        case DISPLAY_KEY_F3: base = T3(0x1B, 0x4F, 0x52); break;
        case DISPLAY_KEY_F4: base = T3(0x1B, 0x4F, 0x53); break;

        /* F5-F12: ANSI/xterm ESC [ N ~ */
        case DISPLAY_KEY_F5:  base = T5(0x1B, 0x5B, 0x31, 0x35, 0x7E); break;
        case DISPLAY_KEY_F6:  base = T5(0x1B, 0x5B, 0x31, 0x37, 0x7E); break;
        case DISPLAY_KEY_F7:  base = T5(0x1B, 0x5B, 0x31, 0x38, 0x7E); break;
        case DISPLAY_KEY_F8:  base = T5(0x1B, 0x5B, 0x31, 0x39, 0x7E); break;
        case DISPLAY_KEY_F9:  base = T5(0x1B, 0x5B, 0x32, 0x30, 0x7E); break;
        case DISPLAY_KEY_F10: base = T5(0x1B, 0x5B, 0x32, 0x31, 0x7E); break;
        case DISPLAY_KEY_F11: base = T5(0x1B, 0x5B, 0x32, 0x33, 0x7E); break;
        case DISPLAY_KEY_F12: base = T5(0x1B, 0x5B, 0x32, 0x34, 0x7E); break;

        /* Numpad: numeric/operator output only; no cursor/navigation sequences. */
        case DISPLAY_KEY_KP_0:        base = T1(0x30); break;
        case DISPLAY_KEY_KP_1:        base = T1(0x31); break;
        case DISPLAY_KEY_KP_2:        base = T1(0x32); break;
        case DISPLAY_KEY_KP_3:        base = T1(0x33); break;
        case DISPLAY_KEY_KP_4:        base = T1(0x34); break;
        case DISPLAY_KEY_KP_5:        base = T1(0x35); break;
        case DISPLAY_KEY_KP_6:        base = T1(0x36); break;
        case DISPLAY_KEY_KP_7:        base = T1(0x37); break;
        case DISPLAY_KEY_KP_8:        base = T1(0x38); break;
        case DISPLAY_KEY_KP_9:        base = T1(0x39); break;
        case DISPLAY_KEY_KP_DECIMAL:  base = T1(0x2E); break;
        case DISPLAY_KEY_KP_ADD:      base = T1(0x2B); break;
        case DISPLAY_KEY_KP_SUBTRACT: base = T1(0x2D); break;
        case DISPLAY_KEY_KP_MULTIPLY: base = T1(0x2A); break;
        case DISPLAY_KEY_KP_DIVIDE:   base = T1(0x2F); break;
        case DISPLAY_KEY_KP_ENTER:    base = T1(0x0D); break;

        default:
            return unmapped;
        }
    }

    /* Alt (Left Alt only) prefixes the entire sequence with ESC. */
    return alt ? prepend_escape(base) : base;
}

static void log_terminal_payload(const char *prefix, const uint8_t *payload, uint8_t length)
{
    printf("%s", prefix);
    print_payload_hex(payload, length);
    printf("\n");
}

static const char *keysym_to_name(uint32_t keysym)
{
    switch (keysym) {
    case DISPLAY_KEY_BACKSPACE:          return "BackSpace";
    case DISPLAY_KEY_TAB:                return "Tab";
    case DISPLAY_KEY_RETURN:             return "Return";
    case DISPLAY_KEY_ESCAPE:             return "Escape";
    case DISPLAY_KEY_HOME:               return "Home";
    case DISPLAY_KEY_LEFT:               return "Left";
    case DISPLAY_KEY_UP:                 return "Up";
    case DISPLAY_KEY_RIGHT:              return "Right";
    case DISPLAY_KEY_DOWN:               return "Down";
    case DISPLAY_KEY_PAGE_UP:            return "PageUp";
    case DISPLAY_KEY_PAGE_DOWN:          return "PageDown";
    case DISPLAY_KEY_END:                return "End";
    case DISPLAY_KEY_INSERT:             return "Insert";
    case DISPLAY_KEY_DELETE:             return "Delete";
    case DISPLAY_KEY_F1:                 return "F1";
    case DISPLAY_KEY_F2:                 return "F2";
    case DISPLAY_KEY_F3:                 return "F3";
    case DISPLAY_KEY_F4:                 return "F4";
    case DISPLAY_KEY_F5:                 return "F5";
    case DISPLAY_KEY_F6:                 return "F6";
    case DISPLAY_KEY_F7:                 return "F7";
    case DISPLAY_KEY_F8:                 return "F8";
    case DISPLAY_KEY_F9:                 return "F9";
    case DISPLAY_KEY_F10:                return "F10";
    case DISPLAY_KEY_F11:                return "F11";
    case DISPLAY_KEY_F12:                return "F12";
    case DISPLAY_KEY_KP_0:               return "KP_0";
    case DISPLAY_KEY_KP_1:               return "KP_1";
    case DISPLAY_KEY_KP_2:               return "KP_2";
    case DISPLAY_KEY_KP_3:               return "KP_3";
    case DISPLAY_KEY_KP_4:               return "KP_4";
    case DISPLAY_KEY_KP_5:               return "KP_5";
    case DISPLAY_KEY_KP_6:               return "KP_6";
    case DISPLAY_KEY_KP_7:               return "KP_7";
    case DISPLAY_KEY_KP_8:               return "KP_8";
    case DISPLAY_KEY_KP_9:               return "KP_9";
    case DISPLAY_KEY_KP_DECIMAL:         return "KP_Decimal";
    case DISPLAY_KEY_KP_ADD:             return "KP_Add";
    case DISPLAY_KEY_KP_SUBTRACT:        return "KP_Subtract";
    case DISPLAY_KEY_KP_MULTIPLY:        return "KP_Multiply";
    case DISPLAY_KEY_KP_DIVIDE:          return "KP_Divide";
    case DISPLAY_KEY_KP_ENTER:           return "KP_Enter";
    case DISPLAY_KEY_SHIFT_L:            return "Shift_L";
    case DISPLAY_KEY_SHIFT_R:            return "Shift_R";
    case DISPLAY_KEY_CTRL_L:             return "Control_L";
    case DISPLAY_KEY_CTRL_R:             return "Control_R";
    case DISPLAY_KEY_ALT_L:              return "Alt_L";
    case DISPLAY_KEY_ALT_R:              return "Alt_R";
    case DISPLAY_KEY_META_L:             return "Meta_L";
    case DISPLAY_KEY_META_R:             return "Meta_R";
    case DISPLAY_KEY_SUPER_L:            return "Super_L";
    case DISPLAY_KEY_SUPER_R:            return "Super_R";
    case DISPLAY_KEY_MODE_SWITCH:        return "Mode_switch";
    case DISPLAY_KEY_ISO_LEVEL3_SHIFT:   return "ISO_Level3_Shift";
    default:
        return NULL;
    }
}

/* Log key=<name> [ctrl=N shift=N alt=N] -> XX XX ... */
static void log_key_event(uint32_t keysym, uint8_t modifiers, bool recognized,
                          const uint8_t *bytes, uint8_t length)
{
    bool ctrl  = (modifiers & KEY_MODIFIER_CTRL) != 0;
    bool shift = (modifiers & KEY_MODIFIER_SHIFT) != 0;
    bool alt   = (modifiers & KEY_MODIFIER_ALT) != 0;

    if (keysym >= 0x20 && keysym <= 0x7E) {
        printf("key=%c", (char)keysym);
    } else {
        const char *name = keysym_to_name(keysym);
        if (name != NULL) {
            printf("key=%s", name);
        } else {
            printf("key=0x%08X", keysym);
        }
    }

    if (ctrl || shift || alt) {
        printf(" ctrl=%d shift=%d alt=%d", ctrl, shift, alt);
    }

    if (recognized && length > 0) {
        printf(" ->");
        for (uint8_t i = 0; i < length; i++) {
            printf(" %02X", bytes[i]);
        }
    } else {
        printf(" -> unsupported");
    }
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

    TerminalMapping mapping = map_display_keysym_to_terminal(keysym, ctx->modifiers);
    if (!mapping.mapped || mapping.length == 0) {
        if (modifier_bit == 0) {
            keyboard_transport_note_unsupported_key(ctx->keyboard_transport);
            if (ctx->log_keys) {
                log_key_event(keysym, ctx->modifiers, false, NULL, 0);
                printf("Keyboard terminal input ignored: unsupported keysym=0x%08X\n", keysym);
            }
        }
        return;
    }

    if (ctx->keyboard_transport == NULL) {
        if (ctx->log_keys) {
            log_key_event(keysym, ctx->modifiers, true, mapping.bytes, mapping.length);
            log_terminal_payload("Raw key bytes not queued: no transport bytes=", mapping.bytes, mapping.length);
        }
        return;
    }

    bool queued = keyboard_transport_enqueue(
        ctx->keyboard_transport,
        mapping.bytes,
        mapping.length);

    if (ctx->log_keys) {
        log_key_event(keysym, ctx->modifiers, true, mapping.bytes, mapping.length);
        log_terminal_payload(
            queued ? "Raw key bytes queued: " : "Raw key bytes queue dropped: ",
            mapping.bytes,
            mapping.length);
    }
}

void input_keyboard_display_key_callback(bool down, uint32_t keysym, void *userdata)
{
    InputKeyboardContext *ctx = (InputKeyboardContext *)userdata;
    input_keyboard_handle_display_key(ctx, down, keysym);
}
