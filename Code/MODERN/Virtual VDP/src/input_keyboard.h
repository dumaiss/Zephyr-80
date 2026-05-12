#ifndef INPUT_KEYBOARD_H
#define INPUT_KEYBOARD_H

/**
 * @file input_keyboard.h
 * Map display key events into structured Virtual Drip KEY_EVENT packets.
 *
 * This module is intentionally not a terminal emulator. It does not translate
 * keys into VT escape sequences as the primary interface; it emits structured
 * key up/down events with ASCII, special-key, and modifier fields.
 */

#include "serial_port.h"

#include <stdbool.h>
#include <stdint.h>

/**
 * Keyboard mapper state.
 *
 * serial_port is borrowed and may be NULL in file replay/no-serial modes. When
 * enabled is false events are ignored. modifiers tracks currently held Shift,
 * Ctrl, Alt, and Meta/Super keysyms as seen from LibVNCServer.
 */
typedef struct {
    SerialPort *serial_port;
    bool enabled;
    bool log_keys;
    uint8_t modifiers;
} InputKeyboardContext;

/** Initialize mapper state with a borrowed optional serial port. */
void input_keyboard_init(InputKeyboardContext *ctx, SerialPort *serial_port, bool enabled, bool log_keys);

/**
 * Handle one display keysym event.
 *
 * If serial_port is NULL, mapping/logging still occurs but no packet is sent.
 */
void input_keyboard_handle_display_key(InputKeyboardContext *ctx, bool down, uint32_t keysym);

/** Callback adapter matching the display backend's keyboard callback type. */
void input_keyboard_display_key_callback(bool down, uint32_t keysym, void *userdata);

#endif
