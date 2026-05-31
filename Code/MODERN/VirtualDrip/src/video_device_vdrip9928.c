#include "video_device_vdrip9928.h"

#include "vdrip_vdp.h"

#include <stdio.h>
#include <stdlib.h>

/*
 * vDrip9928 concrete video backend. It owns the VrEmuTms9918 instance and knows
 * how Virtual Drip VDP_CTRL_WRITE/VDP_DATA_WRITE packets map to the TMS9918
 * address and data ports. Identical to the TMS9928 backend except it links
 * against the vdrip_vdp fork (which adds Text 2 80-column mode).
 */

/** Private backend state owned by VideoDevice::impl. */
typedef struct {
    VrEmuTms9918 *tms9918;
    size_t control_writes;
    size_t data_writes;
} Vdrip9928Device;

/* Convert TMS9918 color indices into the 0x00RRGGBB framebuffer format. */
static uint32_t vdrip_color_to_rgb(uint8_t color_index)
{
    static const uint32_t palette[] = {
        0x000000,
        0x000000,
        0x21C842,
        0x5EDC78,
        0x5455ED,
        0x7D76FC,
        0xD4524D,
        0x42EBF5,
        0xFC5554,
        0xFF7978,
        0xD4C154,
        0xE6CE80,
        0x21B03B,
        0xC95BBA,
        0xCCCCCC,
        0xFFFFFF,
    };

    return palette[color_index & 0x0F];
}

static Vdrip9928Device *vdrip9928_impl(VideoDevice *device)
{
    return (Vdrip9928Device *)device->impl;
}

static bool vdrip9928_reset(VideoDevice *device)
{
    Vdrip9928Device *impl = vdrip9928_impl(device);

    if (impl->tms9918 != NULL) {
        vrEmuTms9918Destroy(impl->tms9918);
    }

    impl->tms9918 = vrEmuTms9918New();
    if (impl->tms9918 == NULL) {
        fprintf(stderr, "Failed to create vDrip9928 instance\n");
        return false;
    }

    impl->control_writes = 0;
    impl->data_writes = 0;
    return true;
}

static void vdrip9928_write_control(Vdrip9928Device *impl, uint8_t value)
{
    ++impl->control_writes;
    vrEmuTms9918WriteAddr(impl->tms9918, value);
    /* printf("  VDP CTRL write value=0x%02X (vDrip9928, count=%zu)\n", value, impl->control_writes); */
}

static void vdrip9928_write_data(Vdrip9928Device *impl, uint8_t value)
{
    ++impl->data_writes;
    vrEmuTms9918WriteData(impl->tms9918, value);
    /* printf("  VDP DATA write value=0x%02X (vDrip9928, count=%zu)\n", value, impl->data_writes); */
}

static bool vdrip9928_handle_packet(VideoDevice *device, const Packet *packet, VideoDeviceUpdate *update)
{
    Vdrip9928Device *impl = vdrip9928_impl(device);

    switch (packet->type) {
    case PACKET_VDP_CTRL_WRITE:
        if (packet->length != 1) {
            fprintf(stderr, "  VDP CTRL write ignored: expected 1 payload byte, got %u\n", packet->length);
            return false;
        }
        vdrip9928_write_control(impl, packet->payload[0]);
        video_device_update_mark_full(device, update);
        return true;
    case PACKET_VDP_DATA_WRITE:
        if (packet->length != 1) {
            fprintf(stderr, "  VDP DATA write ignored: expected 1 payload byte, got %u\n", packet->length);
            return false;
        }
        vdrip9928_write_data(impl, packet->payload[0]);
        video_device_update_mark_full(device, update);
        return true;
    case PACKET_VDP_DATA_BLOCK:
        if (packet->length == 0 || packet->length > MAX_PACKET_PAYLOAD) {
            fprintf(stderr, "  VDP DATA BLOCK ignored: invalid payload length %u\n", packet->length);
            return false;
        }
        for (uint8_t i = 0; i < packet->length; ++i) {
            vdrip9928_write_data(impl, packet->payload[i]);
        }
        /* Do not mark framebuffer dirty — FRAME_MARK triggers the render. */
        return true;
    case PACKET_VDP_SCROLL: {
        /* Hardware scroll: shift the Text 2 name table up by N rows
           and blank the bottom N rows.  One 7-byte packet replaces a
           full 2084-byte screen blast at ~115200 baud. */
        if (packet->length != 1) {
            fprintf(stderr, "  VDP SCROLL ignored: expected 1 byte, got %u\n", packet->length);
            return false;
        }
        uint8_t rows = packet->payload[0];
        if (rows == 0 || rows > 23) {
            fprintf(stderr, "  VDP SCROLL ignored: invalid rows %u\n", rows);
            return false;
        }
        /* Column-major traversal needs only one byte of temporary storage.
           WriteAddr is a two-step protocol: low byte, then (high | 0x40). */
        for (int x = 0; x < 80; ++x) {
            for (int y = 0; y < 24 - (int)rows; ++y) {
                uint16_t src = 0x3800 + (uint16_t)((y + rows) * 80 + x);
                uint16_t dst = 0x3800 + (uint16_t)(y * 80 + x);
                uint8_t ch = vrEmuTms9918VramValue(impl->tms9918, src);
                vrEmuTms9918WriteAddr(impl->tms9918, (uint8_t)(dst & 0xFF));
                vrEmuTms9918WriteAddr(impl->tms9918, (uint8_t)(((dst >> 8) & 0x3F) | 0x40));
                vrEmuTms9918WriteData(impl->tms9918, ch);
            }
            for (int y = 24 - (int)rows; y < 24; ++y) {
                uint16_t dst = 0x3800 + (uint16_t)(y * 80 + x);
                vrEmuTms9918WriteAddr(impl->tms9918, (uint8_t)(dst & 0xFF));
                vrEmuTms9918WriteAddr(impl->tms9918, (uint8_t)(((dst >> 8) & 0x3F) | 0x40));
                vrEmuTms9918WriteData(impl->tms9918, 0x20);
            }
        }
        video_device_update_mark_full(device, update);
        return true;
    }
    case PACKET_RESET:
        if (!vdrip9928_reset(device)) {
            return false;
        }
        /* printf("  VDP reset (%s)\n", device->info.name); */
        video_device_update_mark_full(device, update);
        return true;
    default:
        /* printf("  VDP no-op for %s\n", packet_type_name(packet->type)); */
        return true;
    }
}

static bool vdrip9928_render_framebuffer(VideoDevice *device, uint32_t *framebuffer, int width, int height)
{
    Vdrip9928Device *impl = vdrip9928_impl(device);
    uint8_t scanline[TMS9918_PIXELS_X];
    int render_width = width < TMS9918_PIXELS_X ? width : TMS9918_PIXELS_X;
    int render_height = height < TMS9918_PIXELS_Y ? height : TMS9918_PIXELS_Y;

    if (impl->tms9918 == NULL) {
        return false;
    }

    for (int y = 0; y < render_height; ++y) {
        vrEmuTms9918ScanLine(impl->tms9918, (uint8_t)y, scanline);
        for (int x = 0; x < render_width; ++x) {
            framebuffer[((size_t)y * (size_t)width) + (size_t)x] = vdrip_color_to_rgb(scanline[x]);
        }
    }

    return true;
}

static void vdrip9928_tick_frame(VideoDevice *device, VideoDeviceUpdate *update)
{
    (void)device;
    video_device_update_clear(update);
}

static bool vdrip9928_is_text_mode(VideoDevice *device)
{
    Vdrip9928Device *impl = vdrip9928_impl(device);

    if (impl == NULL || impl->tms9918 == NULL) {
        return false;
    }

    vrEmuTms9918Mode mode = vrEmuTms9918DisplayMode(impl->tms9918);
    return mode == TMS_MODE_TEXT || mode == TMS_MODE_TEXT_2;
}

static void vdrip9928_destroy(VideoDevice *device)
{
    Vdrip9928Device *impl = vdrip9928_impl(device);

    if (impl != NULL) {
        if (impl->tms9918 != NULL) {
            vrEmuTms9918Destroy(impl->tms9918);
        }
        free(impl);
    }

    free(device);
}

static const VideoDeviceOps vdrip9928_ops = {
    .reset = vdrip9928_reset,
    .handle_packet = vdrip9928_handle_packet,
    .render_framebuffer = vdrip9928_render_framebuffer,
    .tick_frame = vdrip9928_tick_frame,
    .is_text_mode = vdrip9928_is_text_mode,
    .destroy = vdrip9928_destroy,
};

VideoDevice *video_device_vdrip9928_create(void)
{
    VideoDevice *device = calloc(1, sizeof(*device));
    if (device == NULL) {
        fprintf(stderr, "Failed to allocate vDrip9928 video device\n");
        return NULL;
    }

    Vdrip9928Device *impl = calloc(1, sizeof(*impl));
    if (impl == NULL) {
        fprintf(stderr, "Failed to allocate vDrip9928 video backend\n");
        free(device);
        return NULL;
    }

    device->ops = &vdrip9928_ops;
    device->impl = impl;
    device->info.name = "vDrip9928 (TMS9918 + Text 2)";
    device->info.width = TMS9918_PIXELS_X;
    device->info.height = TMS9918_PIXELS_Y;
    device->info.supports_status_read = false;
    device->info.supports_data_read = false;

    if (!video_device_reset(device)) {
        video_device_destroy(device);
        return NULL;
    }

    return device;
}
