#include "display_libvncserver.h"

#include <rfb/rfb.h>

#include <stdio.h>
#include <stdlib.h>

/*
 * Keep RFB/VNC protocol mechanics entirely inside LibVNCServer. This module
 * configures the screen, framebuffer pointer, dirty rectangles, and keyboard
 * callback, but never parses VNC client messages itself.
 */

struct DisplayLibVncServer {
    /* Owned LibVNCServer screen. LibVNCServer owns client sockets/protocol. */
    rfbScreenInfoPtr screen;
    /* Upward callback into the input layer; may be NULL. */
    DisplayKeyEventCallback key_event_callback;
    /* Caller-owned context for key_event_callback. */
    void *key_event_userdata;
    /* Borrowed framebuffer dimensions for full-screen dirty marking. */
    int width;
    int height;
};

static void keyboard_callback(rfbBool down, rfbKeySym keysym, rfbClientPtr client)
{
    if (client == NULL || client->screen == NULL || client->screen->screenData == NULL) {
        return;
    }

    /* screenData carries our wrapper so LibVNCServer callbacks can reach app code. */
    DisplayLibVncServer *display = (DisplayLibVncServer *)client->screen->screenData;
    if (display->key_event_callback != NULL) {
        display->key_event_callback(down != 0, (uint32_t)keysym, display->key_event_userdata);
    }
}

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
    void *key_event_userdata)
{
    DisplayLibVncServer *display = calloc(1, sizeof(*display));
    if (display == NULL) {
        fprintf(stderr, "Failed to allocate LibVNCServer display backend\n");
        return NULL;
    }

    rfbScreenInfoPtr screen = rfbGetScreen(&argc, argv, width, height, 8, 3, 4);
    if (screen == NULL) {
        fprintf(stderr, "Failed to create LibVNCServer screen\n");
        free(display);
        return NULL;
    }

    display->screen = screen;
    display->key_event_callback = key_event_callback;
    display->key_event_userdata = key_event_userdata;
    display->width = width;
    display->height = height;

    screen->desktopName = name;
    screen->frameBuffer = (char *)framebuffer;
    screen->port = port;
    screen->ipv6port = port;
    screen->alwaysShared = always_shared ? TRUE : FALSE;
    screen->kbdAddEvent = keyboard_callback;
    screen->screenData = display;
    screen->serverFormat.redShift = 16;
    screen->serverFormat.greenShift = 8;
    screen->serverFormat.blueShift = 0;
    screen->serverFormat.redMax = 255;
    screen->serverFormat.greenMax = 255;
    screen->serverFormat.blueMax = 255;

    rfbInitServer(screen);
    return display;
}

bool display_libvncserver_process_events(DisplayLibVncServer *display, long timeout_usec)
{
    if (display == NULL || display->screen == NULL) {
        return false;
    }

    return rfbProcessEvents(display->screen, timeout_usec) != 0;
}

int display_libvncserver_run_loop(
    DisplayLibVncServer *display,
    DisplayShouldStop should_stop,
    void *should_stop_userdata,
    long timeout_usec)
{
    while (display_libvncserver_is_active(display)) {
        if (should_stop != NULL && should_stop(should_stop_userdata)) {
            return 0;
        }
        (void)display_libvncserver_process_events(display, timeout_usec);
    }

    return 1;
}

void display_libvncserver_mark_dirty(DisplayLibVncServer *display, int x1, int y1, int x2, int y2)
{
    if (display == NULL || display->screen == NULL) {
        return;
    }

    rfbMarkRectAsModified(display->screen, x1, y1, x2, y2);
}

void display_libvncserver_mark_full_dirty(void *userdata)
{
    DisplayLibVncServer *display = (DisplayLibVncServer *)userdata;
    if (display == NULL) {
        return;
    }

    display_libvncserver_mark_dirty(display, 0, 0, display->width, display->height);
}

bool display_libvncserver_is_active(const DisplayLibVncServer *display)
{
    if (display == NULL || display->screen == NULL) {
        return false;
    }

    return rfbIsActive(display->screen) != 0;
}

void display_libvncserver_destroy(DisplayLibVncServer *display)
{
    if (display == NULL) {
        return;
    }

    if (display->screen != NULL) {
        display->screen->screenData = NULL;
        rfbShutdownServer(display->screen, TRUE);
        rfbScreenCleanup(display->screen);
        display->screen = NULL;
    }

    free(display);
}
