#ifndef APP_CONFIG_H
#define APP_CONFIG_H

/**
 * @file app_config.h
 * Command-line configuration for Virtual Drip runtime mode selection.
 *
 * Parsing selects one packet input mode, display options, keyboard behavior,
 * and the video backend name. It does not open files, serial ports, or VNC.
 */

#include <stdbool.h>

#define DEFAULT_VNC_PORT 5900
#define DEFAULT_VIDEO_BACKEND "tms9928"
#define DEFAULT_DISK_A_PATH "zephyr_a.img"

/** Packet input source selected at startup. */
typedef enum {
    /** No packet source; useful for a blank live VNC server or headless idle. */
    INPUT_NONE,
    /** Decode a binary packet file, then keep serving the rendered framebuffer. */
    INPUT_FILE_REPLAY,
    /** Read live packet bytes from a serial device. */
    INPUT_SERIAL,
} InputMode;

/** Parsed application options; string pointers borrow argv storage. */
typedef struct {
    /** Selected packet input mode. */
    InputMode input_mode;
    /** Packet file path when input_mode is INPUT_FILE_REPLAY. */
    const char *file_path;
    /** Serial device path when input_mode is INPUT_SERIAL. */
    const char *serial_path;
    /** Serial baud rate; currently limited by serial_port.c's termios table. */
    int baud_rate;
    /** Local flat 8 MiB disk image backing CP/M drive A in serial mode. */
    const char *disk_a_path;
    /** TCP port for LibVNCServer. */
    int vnc_port;
    /** Disable VNC output and run headless. */
    bool no_vnc;
    /** Enable LibVNCServer keyboard capture and serial terminal input output. */
    bool keyboard_enabled;
    /** Print key mapping and raw input bytes for debugging. */
    bool log_keys;
    /** Print one line for each storage request/reply. */
    bool log_storage;
    /** Print decoded non-storage packets for live protocol debugging. */
    bool log_packets;
    /** Bridge packetized console TX/RX through a Linux PTY in serial mode. */
    bool console_pty;
    /** Proxy->Z80 keyboard input is raw terminal bytes. */
    bool raw_terminal_input;
    /** Video backend selector. Currently only "tms9928" is accepted. */
    const char *video_backend;
} AppConfig;

/** Print command-line usage to stderr. */
void print_usage(const char *program_name);

/** Parse argv into config. Returns false and prints an error for invalid input. */
bool parse_args(int argc, char **argv, AppConfig *config);

#endif
