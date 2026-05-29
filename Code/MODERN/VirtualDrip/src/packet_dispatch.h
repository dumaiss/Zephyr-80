#ifndef PACKET_DISPATCH_H
#define PACKET_DISPATCH_H

/**
 * @file packet_dispatch.h
 * Bridge decoded packets into the selected VideoDevice and framebuffer.
 *
 * Packet sources call the PacketHandler here. Dispatch sends valid packets to
 * the video backend, renders into the caller-owned framebuffer when the backend
 * reports a dirty frame, and notifies display code through a callback.
 */

#include "protocol.h"
#include "video_device.h"
#include "keyboard_transport.h"
#include "virtual_text_cursor.h"

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

/** Display-layer callback invoked after the framebuffer is rerendered. */
typedef void (*FrameChangedCallback)(void *userdata);

/** Dispatch context; borrows the video device, framebuffer, and mutex. */
typedef struct {
    VideoDevice *video_device;
    uint32_t *framebuffer;
    int framebuffer_width;
    int framebuffer_height;
    pthread_mutex_t *framebuffer_mutex;
    FrameChangedCallback frame_changed;
    void *frame_changed_userdata;
    KeyboardTransport *keyboard_transport;
    VirtualTextCursor cursor;
    size_t packet_count;
} PacketDispatch;

/** Initialize dispatch with a backend and host-owned framebuffer. */
void packet_dispatch_init(
    PacketDispatch *dispatch,
    VideoDevice *video_device,
    uint32_t *framebuffer,
    int framebuffer_width,
    int framebuffer_height,
    pthread_mutex_t *framebuffer_mutex);

/** Register an optional callback for display dirty notification. */
void packet_dispatch_set_frame_changed_callback(
    PacketDispatch *dispatch,
    FrameChangedCallback callback,
    void *userdata);

/** Register optional keyboard transport gate updates for incoming serial packets. */
void packet_dispatch_set_keyboard_transport(PacketDispatch *dispatch, KeyboardTransport *keyboard_transport);

/** Render the backend's current state into the framebuffer under the mutex. */
void packet_dispatch_render(PacketDispatch *dispatch);

/** Process local cursor blink and redraw when the blink phase changes. */
void packet_dispatch_tick(PacketDispatch *dispatch);

/** Release dispatch-owned resources. */
void packet_dispatch_destroy(PacketDispatch *dispatch);

/** PacketHandler implementation used by file replay and serial input. */
void packet_dispatch_handle_packet(const Packet *packet, size_t offset, void *userdata);

/** Replay a file through this dispatch context. */
int packet_dispatch_replay_file(PacketDispatch *dispatch, const char *path);

/** Number of packets observed by this dispatch context. */
size_t packet_dispatch_packet_count(const PacketDispatch *dispatch);

#endif
