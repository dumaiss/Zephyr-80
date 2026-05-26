#include "video_device.h"

/*
 * These wrappers keep defensive NULL/optional-op handling in one place. Callers
 * can use the same control flow for all backends while concrete implementations
 * stay small.
 */

void video_device_update_clear(VideoDeviceUpdate *update)
{
    if (update == NULL) {
        return;
    }

    update->framebuffer_dirty = false;
    update->dirty_x = 0;
    update->dirty_y = 0;
    update->dirty_w = 0;
    update->dirty_h = 0;
}

void video_device_update_mark_full(VideoDevice *device, VideoDeviceUpdate *update)
{
    if (device == NULL || update == NULL) {
        return;
    }

    update->framebuffer_dirty = true;
    update->dirty_x = 0;
    update->dirty_y = 0;
    update->dirty_w = device->info.width;
    update->dirty_h = device->info.height;
}

bool video_device_reset(VideoDevice *device)
{
    if (device == NULL || device->ops == NULL || device->ops->reset == NULL) {
        return false;
    }

    return device->ops->reset(device);
}

bool video_device_handle_packet(VideoDevice *device, const Packet *packet, VideoDeviceUpdate *update)
{
    video_device_update_clear(update);
    if (device == NULL || device->ops == NULL || device->ops->handle_packet == NULL) {
        return false;
    }

    return device->ops->handle_packet(device, packet, update);
}

bool video_device_render_framebuffer(VideoDevice *device, uint32_t *framebuffer, int width, int height)
{
    if (device == NULL || device->ops == NULL || device->ops->render_framebuffer == NULL) {
        return false;
    }

    return device->ops->render_framebuffer(device, framebuffer, width, height);
}

void video_device_tick_frame(VideoDevice *device, VideoDeviceUpdate *update)
{
    video_device_update_clear(update);
    if (device == NULL || device->ops == NULL || device->ops->tick_frame == NULL) {
        return;
    }

    device->ops->tick_frame(device, update);
}

void video_device_destroy(VideoDevice *device)
{
    if (device == NULL) {
        return;
    }

    if (device->ops != NULL && device->ops->destroy != NULL) {
        device->ops->destroy(device);
    }
}
