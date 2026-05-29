#define _DEFAULT_SOURCE

#include "virtual_text_cursor.h"

#include <stddef.h>
#include <string.h>
#include <time.h>

static uint8_t clamp_u8_to_nonzero_limit(uint8_t value, uint8_t limit)
{
    if (limit == 0) {
        return 0;
    }
    return value >= limit ? (uint8_t)(limit - 1) : value;
}

static uint8_t clamp_int_to_nonzero_limit(int value, uint8_t limit)
{
    if (limit == 0 || value <= 0) {
        return 0;
    }
    return value >= limit ? (uint8_t)(limit - 1) : (uint8_t)value;
}

static void virtual_text_cursor_mark_cell_dirty_locked(VirtualTextCursor *cursor)
{
    cursor->old_col = cursor->col;
    cursor->old_row = cursor->row;
    cursor->dirty = true;
}

static void virtual_text_cursor_mark_move_dirty_locked(VirtualTextCursor *cursor, uint8_t old_col, uint8_t old_row)
{
    cursor->old_col = old_col;
    cursor->old_row = old_row;
    cursor->dirty = true;
}

void virtual_text_cursor_init(VirtualTextCursor *cursor)
{
    memset(cursor, 0, sizeof(*cursor));
    cursor->max_cols = VIRTUAL_TEXT_CURSOR_DEFAULT_COLS;
    cursor->max_rows = VIRTUAL_TEXT_CURSOR_DEFAULT_ROWS;
    cursor->cell_width = VIRTUAL_TEXT_CURSOR_DEFAULT_CELL_WIDTH;
    cursor->cell_height = VIRTUAL_TEXT_CURSOR_DEFAULT_CELL_HEIGHT;
    cursor->style = CURSOR_STYLE_BLOCK;
    cursor->color_rgba = 0xFFFF00FFu;
    cursor->blink_interval_ms = VIRTUAL_TEXT_CURSOR_DEFAULT_BLINK_MS;
    cursor->blink_phase_visible = true;
    pthread_mutex_init(&cursor->mutex, NULL);
}

void virtual_text_cursor_destroy(VirtualTextCursor *cursor)
{
    pthread_mutex_destroy(&cursor->mutex);
}

bool virtual_text_cursor_handle_command(
    VirtualTextCursor *cursor,
    const uint8_t *payload,
    uint8_t length,
    uint64_t now_ms)
{
    if (cursor == NULL || payload == NULL) {
        return false;
    }

    bool accepted = true;

    pthread_mutex_lock(&cursor->mutex);
    cursor->cursor_commands_seen++;

    if (length == 0) {
        accepted = false;
    } else {
        switch ((CursorCommand)payload[0]) {
        case CURSOR_ENABLE:
            if (length != 2) {
                accepted = false;
                break;
            }
            cursor->enabled = payload[1] != 0;
            if (!cursor->enabled) {
                cursor->visible = false;
            }
            cursor->blink_phase_visible = true;
            cursor->last_blink_ms = now_ms;
            virtual_text_cursor_mark_cell_dirty_locked(cursor);
            break;

        case CURSOR_SHOW:
            if (length != 1) {
                accepted = false;
                break;
            }
            cursor->visible = true;
            cursor->blink_phase_visible = true;
            cursor->last_blink_ms = now_ms;
            cursor->cursor_show_count++;
            virtual_text_cursor_mark_cell_dirty_locked(cursor);
            break;

        case CURSOR_HIDE:
            if (length != 1) {
                accepted = false;
                break;
            }
            cursor->visible = false;
            cursor->cursor_hide_count++;
            virtual_text_cursor_mark_cell_dirty_locked(cursor);
            break;

        case CURSOR_SET_POSITION:
            if (length != 3) {
                accepted = false;
                break;
            } else {
                uint8_t old_col = cursor->col;
                uint8_t old_row = cursor->row;
                cursor->col = clamp_u8_to_nonzero_limit(payload[1], cursor->max_cols);
                cursor->row = clamp_u8_to_nonzero_limit(payload[2], cursor->max_rows);
                cursor->cursor_move_count++;
                virtual_text_cursor_mark_move_dirty_locked(cursor, old_col, old_row);
            }
            break;

        case CURSOR_MOVE_RELATIVE:
            if (length != 3) {
                accepted = false;
                break;
            } else {
                uint8_t old_col = cursor->col;
                uint8_t old_row = cursor->row;
                int new_col = (int)cursor->col + (int)(int8_t)payload[1];
                int new_row = (int)cursor->row + (int)(int8_t)payload[2];
                cursor->col = clamp_int_to_nonzero_limit(new_col, cursor->max_cols);
                cursor->row = clamp_int_to_nonzero_limit(new_row, cursor->max_rows);
                cursor->cursor_move_count++;
                virtual_text_cursor_mark_move_dirty_locked(cursor, old_col, old_row);
            }
            break;

        case CURSOR_SET_STYLE:
            if (length != 2 || payload[1] > CURSOR_STYLE_LEFT_BAR) {
                accepted = false;
                break;
            }
            cursor->style = (CursorStyle)payload[1];
            virtual_text_cursor_mark_cell_dirty_locked(cursor);
            break;

        case CURSOR_SET_BLINK:
            if (length != 4) {
                accepted = false;
                break;
            } else {
                uint16_t interval_ms = (uint16_t)payload[2] | ((uint16_t)payload[3] << 8);
                cursor->blink_enabled = payload[1] != 0;
                cursor->blink_interval_ms = interval_ms == 0 ? VIRTUAL_TEXT_CURSOR_DEFAULT_BLINK_MS : interval_ms;
                cursor->last_blink_ms = now_ms;
                cursor->blink_phase_visible = true;
                virtual_text_cursor_mark_cell_dirty_locked(cursor);
            }
            break;

        case CURSOR_SET_COLOR:
            if (length != 4) {
                accepted = false;
                break;
            }
            cursor->color_rgba =
                ((uint32_t)payload[1] << 24) |
                ((uint32_t)payload[2] << 16) |
                ((uint32_t)payload[3] << 8) |
                0xFFu;
            virtual_text_cursor_mark_cell_dirty_locked(cursor);
            break;

        case CURSOR_SET_GEOMETRY:
            if (length != 5 || payload[1] == 0 || payload[2] == 0 || payload[3] == 0 || payload[4] == 0) {
                accepted = false;
                break;
            } else {
                uint8_t old_col = cursor->col;
                uint8_t old_row = cursor->row;
                cursor->max_cols = payload[1];
                cursor->max_rows = payload[2];
                cursor->cell_width = payload[3];
                cursor->cell_height = payload[4];
                cursor->col = clamp_u8_to_nonzero_limit(cursor->col, cursor->max_cols);
                cursor->row = clamp_u8_to_nonzero_limit(cursor->row, cursor->max_rows);
                virtual_text_cursor_mark_move_dirty_locked(cursor, old_col, old_row);
            }
            break;

        default:
            accepted = false;
            break;
        }
    }

    if (!accepted) {
        cursor->cursor_commands_bad++;
    }

    pthread_mutex_unlock(&cursor->mutex);
    return accepted;
}

bool virtual_text_cursor_update_blink(VirtualTextCursor *cursor, uint64_t now_ms)
{
    bool changed = false;

    pthread_mutex_lock(&cursor->mutex);
    if (cursor->enabled && cursor->visible && cursor->blink_enabled) {
        uint64_t interval_ms = cursor->blink_interval_ms == 0
            ? VIRTUAL_TEXT_CURSOR_DEFAULT_BLINK_MS
            : cursor->blink_interval_ms;
        if (cursor->last_blink_ms == 0) {
            cursor->last_blink_ms = now_ms;
        } else if (now_ms - cursor->last_blink_ms >= interval_ms) {
            cursor->blink_phase_visible = !cursor->blink_phase_visible;
            cursor->last_blink_ms = now_ms;
            cursor->dirty = true;
            cursor->cursor_blink_toggle_count++;
            changed = true;
        }
    }
    pthread_mutex_unlock(&cursor->mutex);

    return changed;
}

void virtual_text_cursor_render_overlay(
    VirtualTextCursor *cursor,
    uint32_t *framebuffer,
    int framebuffer_width,
    int framebuffer_height,
    bool is_text_mode)
{
    if (cursor == NULL || framebuffer == NULL || framebuffer_width <= 0 || framebuffer_height <= 0) {
        return;
    }

    bool enabled;
    bool visible;
    bool blink_enabled;
    bool blink_phase_visible;
    uint8_t col;
    uint8_t row;
    uint8_t cell_width;
    uint8_t cell_height;
    CursorStyle style;
    uint32_t color_rgba;

    pthread_mutex_lock(&cursor->mutex);
    enabled = cursor->enabled;
    visible = cursor->visible;
    blink_enabled = cursor->blink_enabled;
    blink_phase_visible = cursor->blink_phase_visible;
    col = cursor->col;
    row = cursor->row;
    cell_width = cursor->cell_width;
    cell_height = cursor->cell_height;
    style = cursor->style;
    color_rgba = cursor->color_rgba;
    cursor->dirty = false;
    pthread_mutex_unlock(&cursor->mutex);

    if (!is_text_mode ||
        !enabled ||
        !visible ||
        (blink_enabled && !blink_phase_visible) ||
        cell_width == 0 ||
        cell_height == 0) {
        return;
    }

    /*
     * TMS9918 text mode is 40 * 6 = 240 active text pixels inside the
     * 256-pixel framebuffer, centered with an 8-pixel left border.
     */
    int x1 = VIRTUAL_TEXT_CURSOR_DEFAULT_ORIGIN_X + ((int)col * (int)cell_width);
    int y1 = VIRTUAL_TEXT_CURSOR_DEFAULT_ORIGIN_Y + ((int)row * (int)cell_height);
    int x2 = x1 + (int)cell_width;
    int y2 = y1 + (int)cell_height;

    switch (style) {
    case CURSOR_STYLE_UNDERLINE: {
        int line_height = cell_height >= 8 ? 2 : 1;
        y1 = y2 - line_height;
        break;
    }
    case CURSOR_STYLE_LEFT_BAR: {
        int bar_width = cell_width >= 6 ? 2 : 1;
        x2 = x1 + bar_width;
        break;
    }
    case CURSOR_STYLE_BLOCK:
    default:
        break;
    }

    if (x1 < 0) {
        x1 = 0;
    }
    if (y1 < 0) {
        y1 = 0;
    }
    if (x2 > framebuffer_width) {
        x2 = framebuffer_width;
    }
    if (y2 > framebuffer_height) {
        y2 = framebuffer_height;
    }
    if (x1 >= x2 || y1 >= y2) {
        return;
    }

    uint32_t rgb = (color_rgba >> 8) & 0x00FFFFFFu;
    for (int y = y1; y < y2; ++y) {
        size_t offset = (size_t)y * (size_t)framebuffer_width;
        for (int x = x1; x < x2; ++x) {
            framebuffer[offset + (size_t)x] = rgb;
        }
    }
}

uint64_t virtual_text_cursor_now_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return ((uint64_t)now.tv_sec * 1000u) + ((uint64_t)now.tv_nsec / 1000000u);
}
