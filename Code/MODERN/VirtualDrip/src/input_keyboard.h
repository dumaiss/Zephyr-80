#ifndef INPUT_KEYBOARD_H
#define INPUT_KEYBOARD_H

/**
 * @file input_keyboard.h
 * Map display key events into Virtual Drip terminal input packets.
 *
 * This is a minimal terminal-input mapper, not a VT100 emulator. Key-down
 * events become raw input bytes; key-up events do not generate packets.
 */

#include "keyboard_transport.h"

#include <stdbool.h>
#include <stdint.h>

/**
 * Keyboard mapper state.
 *
 * keyboard_transport is borrowed and may be NULL in file replay/no-serial
 * modes. When enabled is false events are ignored. modifiers tracks currently
 * held Shift, Ctrl, Alt, and Meta/Super keysyms as seen from LibVNCServer.
 * Modifiers are tracked only so standalone modifier keys are not counted as
 * unsupported terminal input.
 */
typedef struct {
    KeyboardTransport *keyboard_transport;
    bool enabled;
    bool log_keys;
    uint8_t modifiers;
} InputKeyboardContext;

/** Initialize mapper state with a borrowed optional keyboard transport. */
void input_keyboard_init(
    InputKeyboardContext *ctx,
    KeyboardTransport *keyboard_transport,
    bool enabled,
    bool log_keys);

/**
 * Handle one display keysym event.
 *
 * If keyboard_transport is NULL, mapping/logging still occurs but no packet is queued.
 */
void input_keyboard_handle_display_key(InputKeyboardContext *ctx, bool down, uint32_t keysym);

/** Callback adapter matching the display backend's keyboard callback type. */
void input_keyboard_display_key_callback(bool down, uint32_t keysym, void *userdata);

#endif
