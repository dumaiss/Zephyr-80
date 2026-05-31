#include "video_device_tms9928.h"

#include "vrEmuTms9918.h"

#include <stdio.h>
#include <stdlib.h>

/*
 * Current concrete video backend. It owns the vrEmuTms9918 instance and knows
 * how Virtual Drip VDP_CTRL_WRITE/VDP_DATA_WRITE packets map to the TMS9918
 * address and data ports. It deliberately knows nothing about serial, replay,
 * keyboard input, or LibVNCServer.
 */

/** Private backend state owned by VideoDevice::impl. */
typedef struct {
    VrEmuTms9918 *tms9918;
    size_t control_writes;
    size_t data_writes;
} Tms9928Device;

/* Convert TMS9918 color indices into the 0x00RRGGBB framebuffer format. */
static uint32_t tms_color_to_rgb(uint8_t color_index)
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

static Tms9928Device *tms9928_impl(VideoDevice *device)
{
    return (Tms9928Device *)device->impl;
}

static bool tms9928_reset(VideoDevice *device)
{
    Tms9928Device *impl = tms9928_impl(device);

    /* vrEmuTms9918 has no reset hook in this integration, so recreate it. */
    if (impl->tms9918 != NULL) {
        vrEmuTms9918Destroy(impl->tms9918);
    }

    impl->tms9918 = vrEmuTms9918New();
    if (impl->tms9918 == NULL) {
        fprintf(stderr, "Failed to create vrEmuTms9918 instance\n");
        return false;
    }

    impl->control_writes = 0;
    impl->data_writes = 0;
    return true;
}

static void tms9928_write_control(Tms9928Device *impl, uint8_t value)
{
    ++impl->control_writes;
    vrEmuTms9918WriteAddr(impl->tms9918, value);
    /* printf("  VDP CTRL write value=0x%02X (vrEmuTms9918, count=%zu)\n", value, impl->control_writes); */
}

static void tms9928_write_data(Tms9928Device *impl, uint8_t value)
{
    ++impl->data_writes;
    vrEmuTms9918WriteData(impl->tms9918, value);
    /* printf("  VDP DATA write value=0x%02X (vrEmuTms9918, count=%zu)\n", value, impl->data_writes); */
}

static bool tms9928_handle_packet(VideoDevice *device, const Packet *packet, VideoDeviceUpdate *update)
{
    Tms9928Device *impl = tms9928_impl(device);

    switch (packet->type) {
    case PACKET_VDP_CTRL_WRITE:
        if (packet->length != 1) {
            fprintf(stderr, "  VDP CTRL write ignored: expected 1 payload byte, got %u\n", packet->length);
            return false;
        }
        tms9928_write_control(impl, packet->payload[0]);
        /* Register/address writes can alter display interpretation. */
        video_device_update_mark_full(device, update);
        return true;
    case PACKET_VDP_DATA_WRITE:
        if (packet->length != 1) {
            fprintf(stderr, "  VDP DATA write ignored: expected 1 payload byte, got %u\n", packet->length);
            return false;
        }
        tms9928_write_data(impl, packet->payload[0]);
        /* VRAM writes may affect any rendered pixel, so mark conservatively. */
        video_device_update_mark_full(device, update);
        return true;
    case PACKET_VDP_DATA_BLOCK:
        if (packet->length == 0 || packet->length > MAX_PACKET_PAYLOAD) {
            fprintf(stderr, "  VDP DATA BLOCK ignored: invalid payload length %u\n", packet->length);
            return false;
        }
        for (uint8_t i = 0; i < packet->length; ++i) {
            tms9928_write_data(impl, packet->payload[i]);
        }
        /* Do not mark framebuffer dirty — FRAME_MARK triggers the render
           so multi-packet bursts (scroll, clear) produce a single update. */
        return true;
    case PACKET_RESET:
        if (!tms9928_reset(device)) {
            return false;
        }
        /* printf("  VDP reset (%s)\n", device->info.name); */
        video_device_update_mark_full(device, update);
        return true;
    default:
        /* PING, FRAME_MARK, TERMINAL_INPUT, and read requests are no-ops here today. */
        /* printf("  VDP no-op for %s\n", packet_type_name(packet->type)); */
        return true;
    }
}

static bool tms9928_render_framebuffer(VideoDevice *device, uint32_t *framebuffer, int width, int height)
{
    Tms9928Device *impl = tms9928_impl(device);
    uint8_t scanline[TMS9918_PIXELS_X];
    int render_width = width < TMS9918_PIXELS_X ? width : TMS9918_PIXELS_X;
    int render_height = height < TMS9918_PIXELS_Y ? height : TMS9918_PIXELS_Y;

    if (impl->tms9918 == NULL) {
        return false;
    }

    /* vrEmuTms9918 renders one scanline of TMS color indices at a time. */
    for (int y = 0; y < render_height; ++y) {
        vrEmuTms9918ScanLine(impl->tms9918, (uint8_t)y, scanline);
        for (int x = 0; x < render_width; ++x) {
            framebuffer[((size_t)y * (size_t)width) + (size_t)x] = tms_color_to_rgb(scanline[x]);
        }
    }

    return true;
}

static void tms9928_tick_frame(VideoDevice *device, VideoDeviceUpdate *update)
{
    (void)device;
    /* The emulator currently advances purely through port writes. */
    video_device_update_clear(update);
}

static bool tms9928_is_text_mode(VideoDevice *device)
{
    Tms9928Device *impl = tms9928_impl(device);

    if (impl == NULL || impl->tms9918 == NULL) {
        return false;
    }

    return vrEmuTms9918DisplayMode(impl->tms9918) == TMS_MODE_TEXT;
}

static void tms9928_destroy(VideoDevice *device)
{
    Tms9928Device *impl = tms9928_impl(device);

    if (impl != NULL) {
        if (impl->tms9918 != NULL) {
            vrEmuTms9918Destroy(impl->tms9918);
        }
        free(impl);
    }

    free(device);
}

static const VideoDeviceOps tms9928_ops = {
    .reset = tms9928_reset,
    .handle_packet = tms9928_handle_packet,
    .render_framebuffer = tms9928_render_framebuffer,
    .tick_frame = tms9928_tick_frame,
    .is_text_mode = tms9928_is_text_mode,
    .destroy = tms9928_destroy,
};

VideoDevice *video_device_tms9928_create(void)
{
    VideoDevice *device = calloc(1, sizeof(*device));
    if (device == NULL) {
        fprintf(stderr, "Failed to allocate TMS9928 video device\n");
        return NULL;
    }

    Tms9928Device *impl = calloc(1, sizeof(*impl));
    if (impl == NULL) {
        fprintf(stderr, "Failed to allocate TMS9928 video backend\n");
        free(device);
        return NULL;
    }

    device->ops = &tms9928_ops;
    device->impl = impl;
    device->info.name = "TMS9928A / vrEmuTms9918";
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
