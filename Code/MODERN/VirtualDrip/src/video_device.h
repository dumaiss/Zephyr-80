#ifndef VIDEO_DEVICE_H
#define VIDEO_DEVICE_H

/**
 * @file video_device.h
 * Stable interface between Virtual Drip core and video-chip backends.
 *
 * A VideoDevice is a chip/card personality behind a small C interface. The
 * transport, replay, display, and keyboard code talk to VideoDevice; they do
 * not include vrEmuTms9918 headers or know about future chips. Backends receive
 * Virtual Drip packets, decide which ones they understand, update their own
 * state, and render into a host-owned framebuffer.
 *
 * Backends must not call LibVNCServer or serial APIs directly. Display updates
 * are reported through VideoDeviceUpdate so the core can render and mark VNC
 * dirty rectangles. This is the extension point for future V9958/RX660/etc.
 * backends without rewriting transport or display code.
 */

#include "protocol.h"

#include <stdbool.h>
#include <stdint.h>

typedef struct VideoDevice VideoDevice;

/** Static capabilities and dimensions advertised by a backend instance. */
typedef struct {
    const char *name;
    int width;
    int height;
    bool supports_status_read;
    bool supports_data_read;
} VideoDeviceInfo;

/**
 * Result of a backend operation.
 *
 * If framebuffer_dirty is true, the core should call render_framebuffer() and
 * then report the dirty rectangle to the display backend. Current backends may
 * conservatively mark the full screen dirty.
 */
typedef struct {
    bool framebuffer_dirty;
    int dirty_x;
    int dirty_y;
    int dirty_w;
    int dirty_h;
} VideoDeviceUpdate;

/**
 * Backend vtable.
 *
 * reset, handle_packet, render_framebuffer, and destroy are expected for normal
 * devices. tick_frame is optional for devices that need frame-time progression.
 * Missing operations are treated as no-ops or failures by wrapper functions.
 */
typedef struct {
    bool (*reset)(VideoDevice *device);
    bool (*handle_packet)(VideoDevice *device, const Packet *packet, VideoDeviceUpdate *update);
    bool (*render_framebuffer)(VideoDevice *device, uint32_t *framebuffer, int width, int height);
    void (*tick_frame)(VideoDevice *device, VideoDeviceUpdate *update);
    bool (*is_text_mode)(VideoDevice *device);
    void (*destroy)(VideoDevice *device);
} VideoDeviceOps;

/**
 * Public backend handle.
 *
 * ops points to static backend operations. impl is private backend-owned state.
 * The concrete create function owns allocation and video_device_destroy() owns
 * release through ops->destroy().
 */
struct VideoDevice {
    const VideoDeviceOps *ops;
    void *impl;
    VideoDeviceInfo info;
};

/** Clear an update structure to "no framebuffer changes". */
void video_device_update_clear(VideoDeviceUpdate *update);

/** Mark the whole backend framebuffer as dirty. */
void video_device_update_mark_full(VideoDevice *device, VideoDeviceUpdate *update);

/** Reset backend state to power-on/default state. */
bool video_device_reset(VideoDevice *device);

/** Dispatch one protocol packet to the backend. */
bool video_device_handle_packet(VideoDevice *device, const Packet *packet, VideoDeviceUpdate *update);

/**
 * Render current backend state into a caller-owned framebuffer.
 *
 * Rendering should be idempotent: calling it repeatedly without intervening
 * backend state changes should produce the same pixels.
 */
bool video_device_render_framebuffer(VideoDevice *device, uint32_t *framebuffer, int width, int height);

/** Advance one frame for backends that need time-based updates. */
void video_device_tick_frame(VideoDevice *device, VideoDeviceUpdate *update);

/** Return true when the current backend display mode is text. */
bool video_device_is_text_mode(VideoDevice *device);

/** Destroy a backend instance created by a concrete factory. */
void video_device_destroy(VideoDevice *device);

#endif
