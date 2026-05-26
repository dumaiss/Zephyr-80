#ifndef DISPLAY_LIBVNCSERVER_H
#define DISPLAY_LIBVNCSERVER_H

/**
 * @file display_libvncserver.h
 * LibVNCServer-backed display boundary.
 *
 * This is the only module that should touch LibVNCServer. LibVNCServer owns
 * sockets, RFB handshake, client protocol parsing, framebuffer update encoding,
 * and keyboard event dispatch. Virtual Drip provides an already-rendered
 * 32-bit framebuffer and reports dirty rectangles.
 */

#include <stdbool.h>
#include <stdint.h>

/** Opaque owner of an rfbScreenInfoPtr. It borrows, but does not own, framebuffer memory. */
typedef struct DisplayLibVncServer DisplayLibVncServer;

/** LibVNCServer/X11 keysyms used by the keyboard mapper. */
typedef enum {
    DISPLAY_KEY_BACKSPACE = 0xFF08,
    DISPLAY_KEY_TAB = 0xFF09,
    DISPLAY_KEY_RETURN = 0xFF0D,
    DISPLAY_KEY_ESCAPE = 0xFF1B,
    DISPLAY_KEY_HOME = 0xFF50,
    DISPLAY_KEY_LEFT = 0xFF51,
    DISPLAY_KEY_UP = 0xFF52,
    DISPLAY_KEY_RIGHT = 0xFF53,
    DISPLAY_KEY_DOWN = 0xFF54,
    DISPLAY_KEY_PAGE_UP = 0xFF55,
    DISPLAY_KEY_PAGE_DOWN = 0xFF56,
    DISPLAY_KEY_END = 0xFF57,
    DISPLAY_KEY_INSERT = 0xFF63,
    DISPLAY_KEY_F1 = 0xFFBE,
    DISPLAY_KEY_F12 = 0xFFC9,
    DISPLAY_KEY_DELETE = 0xFFFF,
} DisplayKeySymbol;

/** Upward keyboard event callback: down/up state plus raw keysym. */
typedef void (*DisplayKeyEventCallback)(bool down, uint32_t keysym, void *userdata);

/** Event-loop stop callback used by the application runtime. */
typedef bool (*DisplayShouldStop)(void *userdata);

/**
 * Create and start a LibVNCServer screen.
 *
 * framebuffer must remain valid until display_libvncserver_destroy(). The
 * expected pixel format is 32 bits per pixel with red at bits 16..23, green at
 * bits 8..15, and blue at bits 0..7.
 */
DisplayLibVncServer *display_libvncserver_create(
    int argc,
    char **argv,
    int width,
    int height,
    uint32_t *framebuffer,
    int port,
    const char *name,
    bool always_shared,
    DisplayKeyEventCallback key_event_callback,
    void *key_event_userdata);

/** Process pending LibVNCServer events once. */
bool display_libvncserver_process_events(DisplayLibVncServer *display, long timeout_usec);

/** Run rfbProcessEvents until the server stops or should_stop returns true. */
int display_libvncserver_run_loop(
    DisplayLibVncServer *display,
    DisplayShouldStop should_stop,
    void *should_stop_userdata,
    long timeout_usec);

/** Mark an already-rendered framebuffer rectangle as dirty for VNC clients. */
void display_libvncserver_mark_dirty(DisplayLibVncServer *display, int x1, int y1, int x2, int y2);

/** Convenience callback-compatible helper that marks the whole framebuffer dirty. */
void display_libvncserver_mark_full_dirty(void *userdata);

/** Return whether LibVNCServer still considers the screen active. */
bool display_libvncserver_is_active(const DisplayLibVncServer *display);

/** Stop LibVNCServer, clean up the screen, and free the display wrapper. */
void display_libvncserver_destroy(DisplayLibVncServer *display);

#endif
