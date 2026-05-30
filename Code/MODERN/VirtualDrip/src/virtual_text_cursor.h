#ifndef VIRTUAL_TEXT_CURSOR_H
#define VIRTUAL_TEXT_CURSOR_H

/**
 * @file virtual_text_cursor.h
 * Virtual Drip text-mode cursor overlay.
 *
 * This state belongs to the proxy/display layer. It never writes to emulated
 * VRAM, TMS tables, or TMS registers; rendering paints a host-framebuffer
 * overlay after the video backend has rendered the current frame.
 */

#include "protocol.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#define VIRTUAL_TEXT_CURSOR_DEFAULT_COLS 80
#define VIRTUAL_TEXT_CURSOR_DEFAULT_ROWS 24
#define VIRTUAL_TEXT_CURSOR_DEFAULT_CELL_WIDTH 6
#define VIRTUAL_TEXT_CURSOR_DEFAULT_CELL_HEIGHT 8
#define VIRTUAL_TEXT_CURSOR_DEFAULT_ORIGIN_X 0
#define VIRTUAL_TEXT_CURSOR_DEFAULT_ORIGIN_Y 0
#define VIRTUAL_TEXT_CURSOR_DEFAULT_BLINK_MS 500

typedef struct {
    bool enabled;
    bool visible;
    bool blink_enabled;

    uint8_t col;
    uint8_t row;

    uint8_t max_cols;
    uint8_t max_rows;
    uint8_t cell_width;
    uint8_t cell_height;

    CursorStyle style;

    uint32_t color_rgba;

    uint64_t blink_interval_ms;
    uint64_t last_blink_ms;
    bool blink_phase_visible;

    bool dirty;
    uint8_t old_col;
    uint8_t old_row;

    uint64_t cursor_commands_seen;
    uint64_t cursor_commands_bad;
    uint64_t cursor_show_count;
    uint64_t cursor_hide_count;
    uint64_t cursor_move_count;
    uint64_t cursor_blink_toggle_count;

    pthread_mutex_t mutex;
} VirtualTextCursor;

void virtual_text_cursor_init(VirtualTextCursor *cursor);
void virtual_text_cursor_destroy(VirtualTextCursor *cursor);

/** Handle one PACKET_CURSOR_COMMAND payload. Returns true when accepted. */
bool virtual_text_cursor_handle_command(
    VirtualTextCursor *cursor,
    const uint8_t *payload,
    uint8_t length,
    uint64_t now_ms);

/** Toggle local blink phase if needed. Returns true when a redraw is needed. */
bool virtual_text_cursor_update_blink(VirtualTextCursor *cursor, uint64_t now_ms);

/**
 * Paint the cursor overlay into an RGB framebuffer.
 *
 * is_text_mode gates rendering without mutating cursor state. The framebuffer
 * format is Virtual Drip's existing 0x00RRGGBB host framebuffer.
 */
void virtual_text_cursor_render_overlay(
    VirtualTextCursor *cursor,
    uint32_t *framebuffer,
    int framebuffer_width,
    int framebuffer_height,
    bool is_text_mode);

uint64_t virtual_text_cursor_now_ms(void);

#endif
