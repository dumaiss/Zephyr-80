#include "packet_dispatch.h"

#include "packet_replay.h"
#include "protocol_debug.h"

#include <stdio.h>

/*
 * PacketDispatch is the point where transport-neutral packets meet the selected
 * video backend. It does not know how the backend emulates a chip, and it does
 * not know how the display serves pixels; it just coordinates packet handling,
 * rendering, and dirty notification.
 */

void packet_dispatch_init(
    PacketDispatch *dispatch,
    VideoDevice *video_device,
    uint32_t *framebuffer,
    int framebuffer_width,
    int framebuffer_height,
    pthread_mutex_t *framebuffer_mutex)
{
    dispatch->video_device = video_device;
    dispatch->framebuffer = framebuffer;
    dispatch->framebuffer_width = framebuffer_width;
    dispatch->framebuffer_height = framebuffer_height;
    dispatch->framebuffer_mutex = framebuffer_mutex;
    dispatch->frame_changed = NULL;
    dispatch->frame_changed_userdata = NULL;
    dispatch->packet_count = 0;
}

void packet_dispatch_set_frame_changed_callback(
    PacketDispatch *dispatch,
    FrameChangedCallback callback,
    void *userdata)
{
    dispatch->frame_changed = callback;
    dispatch->frame_changed_userdata = userdata;
}

void packet_dispatch_render(PacketDispatch *dispatch)
{
    pthread_mutex_lock(dispatch->framebuffer_mutex);
    (void)video_device_render_framebuffer(
        dispatch->video_device,
        dispatch->framebuffer,
        dispatch->framebuffer_width,
        dispatch->framebuffer_height);
    pthread_mutex_unlock(dispatch->framebuffer_mutex);

    if (dispatch->frame_changed != NULL) {
        dispatch->frame_changed(dispatch->frame_changed_userdata);
    }
}

void packet_dispatch_handle_packet(const Packet *packet, size_t offset, void *userdata)
{
    PacketDispatch *dispatch = (PacketDispatch *)userdata;
    VideoDeviceUpdate update;

    print_packet(++dispatch->packet_count, offset, packet);
    (void)video_device_handle_packet(dispatch->video_device, packet, &update);
    if (update.framebuffer_dirty) {
        /* Current display integration uses whole-frame dirty callbacks. */
        packet_dispatch_render(dispatch);
    }
}

int packet_dispatch_replay_file(PacketDispatch *dispatch, const char *path)
{
    int status = packet_replay_file(path, packet_dispatch_handle_packet, dispatch);
    if (status < 0) {
        return -1;
    }

    printf("Decoded %zu packet%s", dispatch->packet_count, dispatch->packet_count == 1 ? "" : "s");
    if (status > 0) {
        printf(" (CRC errors skipped)");
    }
    printf("; video backend: %s\n", dispatch->video_device->info.name);
    return status;
}

size_t packet_dispatch_packet_count(const PacketDispatch *dispatch)
{
    return dispatch->packet_count;
}
