#include "app_config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * app_config owns only syntax and option validation. Resource creation happens
 * later in main so parsing stays side-effect-light and easy to test manually.
 */

void print_usage(const char *program_name)
{
    fprintf(stderr, "Usage: %s [packet-file] [options]\n", program_name);
    fprintf(stderr, "       %s --file packet-file [options]\n", program_name);
    fprintf(stderr, "       %s --serial device [baud] [options]\n", program_name);
    fprintf(stderr, "  no argument: start LibVNCServer VDP display server on port %d\n", DEFAULT_VNC_PORT);
    fprintf(stderr, "  packet-file: replay packets, then serve the resulting framebuffer\n");
    fprintf(stderr, "  --serial: read live packets from a serial device, default baud 115200\n");
    fprintf(stderr, "  --vnc-port: VNC TCP port, default %d\n", DEFAULT_VNC_PORT);
    fprintf(stderr, "  --no-vnc, --headless: disable VNC output\n");
    fprintf(stderr, "  --video-backend: video backend, default %s (available: tms9928)\n", DEFAULT_VIDEO_BACKEND);
    fprintf(stderr, "  --log-keys: log RFB key events, mappings, and serial terminal input packets\n");
    fprintf(stderr, "  --no-keyboard: disable VNC keyboard capture\n");
}

static bool parse_int_range(const char *text, int min_value, int max_value, int *result)
{
    char *end = NULL;
    long value = strtol(text, &end, 10);
    if (*text == '\0' || *end != '\0' || value < min_value || value > max_value) {
        return false;
    }

    *result = (int)value;
    return true;
}

bool parse_args(int argc, char **argv, AppConfig *config)
{
    config->input_mode = INPUT_NONE;
    config->file_path = NULL;
    config->serial_path = NULL;
    config->baud_rate = 115200;
    config->vnc_port = DEFAULT_VNC_PORT;
    config->no_vnc = false;
    config->keyboard_enabled = true;
    config->log_keys = false;
    config->video_backend = DEFAULT_VIDEO_BACKEND;

    for (int index = 1; index < argc; ++index) {
        const char *arg = argv[index];

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_usage(argv[0]);
            exit(0);
        }
        if (strcmp(arg, "--log-keys") == 0) {
            config->log_keys = true;
            continue;
        }
        if (strcmp(arg, "--no-keyboard") == 0) {
            config->keyboard_enabled = false;
            continue;
        }
        if (strcmp(arg, "--no-vnc") == 0 || strcmp(arg, "--headless") == 0) {
            config->no_vnc = true;
            continue;
        }
        if (strcmp(arg, "--vnc-port") == 0) {
            if (++index >= argc) {
                fprintf(stderr, "--vnc-port requires a port number\n");
                return false;
            }
            if (!parse_int_range(argv[index], 1, 65535, &config->vnc_port)) {
                fprintf(stderr, "Invalid VNC port: %s\n", argv[index]);
                return false;
            }
            continue;
        }
        if (strcmp(arg, "--video-backend") == 0) {
            if (++index >= argc) {
                fprintf(stderr, "--video-backend requires a backend name\n");
                return false;
            }
            config->video_backend = argv[index];
            continue;
        }
        if (strcmp(arg, "--file") == 0) {
            if (++index >= argc) {
                fprintf(stderr, "--file requires a packet file path\n");
                return false;
            }
            if (config->input_mode != INPUT_NONE) {
                fprintf(stderr, "Only one input source can be selected\n");
                return false;
            }
            config->input_mode = INPUT_FILE_REPLAY;
            config->file_path = argv[index];
            continue;
        }
        if (strcmp(arg, "--serial") == 0) {
            if (++index >= argc) {
                fprintf(stderr, "--serial requires a device path\n");
                return false;
            }
            if (config->input_mode != INPUT_NONE) {
                fprintf(stderr, "Only one input source can be selected\n");
                return false;
            }
            config->input_mode = INPUT_SERIAL;
            config->serial_path = argv[index];
            if (index + 1 < argc && strncmp(argv[index + 1], "--", 2) != 0) {
                ++index;
                if (!parse_int_range(argv[index], 1, 1000000, &config->baud_rate)) {
                    fprintf(stderr, "Invalid baud rate: %s\n", argv[index]);
                    return false;
                }
            }
            continue;
        }
        if (strncmp(arg, "--", 2) == 0) {
            fprintf(stderr, "Unknown option: %s\n", arg);
            return false;
        }
        if (config->input_mode != INPUT_NONE) {
            fprintf(stderr, "Only one input source can be selected\n");
            return false;
        }
        config->input_mode = INPUT_FILE_REPLAY;
        config->file_path = arg;
    }

    return true;
}
