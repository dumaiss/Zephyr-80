#define _DEFAULT_SOURCE

/*
 * Virtual Drip orchestration:
 *   1. Parse runtime options and create the selected VideoDevice backend.
 *   2. Allocate a framebuffer owned by main and shared with the display backend.
 *   3. Choose one packet source: file replay, serial reader, or no input.
 *   4. Packet callbacks dispatch into the VideoDevice; dirty updates cause a
 *      framebuffer render and VNC dirty notification.
 *   5. LibVNCServer serves the framebuffer and reports keyboard events upward.
 *   6. Keyboard events are queued from the VNC callback and serialized by a
 *      dedicated writer thread when the VDP transport gate is interactive.
 *   7. Shutdown stops event loops and releases resources in reverse order.
 */

#include "app_config.h"
#include "app_runtime.h"
#include "display_libvncserver.h"
#include "input_keyboard.h"
#include "keyboard_transport.h"
#include "packet_dispatch.h"
#include "serial_port.h"
#include "serial_reader.h"
#include "video_device.h"
#include "video_device_tms9928.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t framebuffer_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Backend selection stays centralized until additional concrete backends exist. */
static VideoDevice *create_video_backend(const char *backend_name)
{
    if (strcmp(backend_name, "tms9928") == 0) {
        return video_device_tms9928_create();
    }

    fprintf(stderr, "Unsupported video backend: %s. Available: tms9928\n", backend_name);
    return NULL;
}

int main(int argc, char **argv)
{
    AppConfig config;
    if (!parse_args(argc, argv, &config)) {
        print_usage(argv[0]);
        return 1;
    }

    app_runtime_install_signal_handlers();

    VideoDevice *video_device = create_video_backend(config.video_backend);
    if (video_device == NULL) {
        return 1;
    }

    uint32_t *framebuffer = calloc(
        (size_t)video_device->info.width * (size_t)video_device->info.height,
        sizeof(*framebuffer));
    if (framebuffer == NULL) {
        fprintf(stderr, "Failed to allocate %dx%d framebuffer\n", video_device->info.width, video_device->info.height);
        video_device_destroy(video_device);
        return 1;
    }

    PacketDispatch dispatch;
    packet_dispatch_init(
        &dispatch,
        video_device,
        framebuffer,
        video_device->info.width,
        video_device->info.height,
        &framebuffer_mutex);
    packet_dispatch_render(&dispatch);

    /* Keyboard can be initialized before serial; no-serial modes just log/drop sends. */
    SerialPort *serial_port = NULL;
    SerialReader *serial_reader = NULL;
    KeyboardTransport *keyboard_transport = NULL;
    InputKeyboardContext keyboard;
    input_keyboard_init(&keyboard, NULL, config.keyboard_enabled, config.log_keys);

    int input_status = 0;
    if (config.input_mode == INPUT_FILE_REPLAY) {
        /* File replay runs to completion before entering the VNC event loop. */
        input_status = packet_dispatch_replay_file(&dispatch, config.file_path);
        if (input_status < 0) {
            packet_dispatch_destroy(&dispatch);
            free(framebuffer);
            video_device_destroy(video_device);
            return 1;
        }
    } else if (config.input_mode == INPUT_SERIAL) {
        serial_port = serial_port_open(config.serial_path, config.baud_rate);
        if (serial_port == NULL) {
            packet_dispatch_destroy(&dispatch);
            free(framebuffer);
            video_device_destroy(video_device);
            return 1;
        }

        keyboard_transport = keyboard_transport_create(serial_port);
        if (keyboard_transport == NULL || !keyboard_transport_start(keyboard_transport)) {
            keyboard_transport_destroy(keyboard_transport);
            serial_port_close(serial_port);
            packet_dispatch_destroy(&dispatch);
            free(framebuffer);
            video_device_destroy(video_device);
            return 1;
        }
        packet_dispatch_set_keyboard_transport(&dispatch, keyboard_transport);
        input_keyboard_init(&keyboard, keyboard_transport, config.keyboard_enabled, config.log_keys);

        /* Signal to the Z80 that the proxy is ready to receive VDP traffic. */
        {
            bool ready_sent = serial_port_send_packet(serial_port, PACKET_PROXY_READY, NULL, 0);
            fprintf(stderr, "Proxy ready packet %s\n", ready_sent ? "sent" : "queued");
        }

        SerialReaderConfig reader_config = {
            .port = serial_port,
            .handler = packet_dispatch_handle_packet,
            .handler_userdata = &dispatch,
            .should_stop = app_runtime_should_stop,
            .should_stop_userdata = NULL,
        };
        /* Serial callbacks run on the reader thread and enter PacketDispatch. */
        serial_reader = serial_reader_start(&reader_config);
        if (serial_reader == NULL) {
            keyboard_transport_destroy(keyboard_transport);
            serial_port_close(serial_port);
            packet_dispatch_destroy(&dispatch);
            free(framebuffer);
            video_device_destroy(video_device);
            return 1;
        }
    }

    int server_status = 0;
    DisplayLibVncServer *display = NULL;
    if (!config.no_vnc) {
        display = display_libvncserver_create(
            argc,
            argv,
            video_device->info.width,
            video_device->info.height,
            framebuffer,
            config.vnc_port,
            "Virtual Drip",
            true,
            input_keyboard_display_key_callback,
            &keyboard);
        if (display == NULL) {
            app_runtime_request_stop();
            serial_reader_join(serial_reader);
            keyboard_transport_destroy(keyboard_transport);
            serial_port_close(serial_port);
            packet_dispatch_destroy(&dispatch);
            free(framebuffer);
            video_device_destroy(video_device);
            return 1;
        }

        packet_dispatch_set_frame_changed_callback(&dispatch, display_libvncserver_mark_full_dirty, display);
        display_libvncserver_mark_full_dirty(display);
        printf("LibVNCServer display listening on port %d (%dx%d, 32-bit framebuffer)\n",
            config.vnc_port,
            video_device->info.width,
            video_device->info.height);
        if (config.input_mode == INPUT_FILE_REPLAY) {
            printf("Serving replayed framebuffer; connect to localhost:%d\n", config.vnc_port);
        } else if (config.input_mode == INPUT_SERIAL) {
            printf("Serving live serial framebuffer; connect to localhost:%d\n", config.vnc_port);
        }
        /* LibVNCServer owns VNC clients and invokes the keyboard callback. */
        while (display_libvncserver_is_active(display)) {
            if (app_runtime_should_stop(NULL)) {
                server_status = 0;
                break;
            }
            packet_dispatch_tick(&dispatch);
            (void)display_libvncserver_process_events(display, 10000);
        }
        if (!app_runtime_should_stop(NULL) && !display_libvncserver_is_active(display)) {
            server_status = 1;
        }
    } else if (serial_reader != NULL || config.input_mode == INPUT_NONE) {
        printf("Running headless; press Ctrl+C to stop\n");
        app_runtime_run_headless_loop();
    }

    app_runtime_request_stop();
    serial_reader_join(serial_reader);
    display_libvncserver_destroy(display);
    keyboard_transport_destroy(keyboard_transport);
    serial_port_close(serial_port);
    packet_dispatch_destroy(&dispatch);
    free(framebuffer);
    video_device_destroy(video_device);
    return server_status != 0 ? server_status : input_status;
}
