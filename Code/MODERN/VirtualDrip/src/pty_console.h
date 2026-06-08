#ifndef PTY_CONSOLE_H
#define PTY_CONSOLE_H

/**
 * @file pty_console.h
 * Packetized PTY console bridge for the optional PTY-backed console mode.
 *
 * The bridge does not emulate a terminal. It writes TERMINAL_TX payload bytes
 * unchanged to the PTY master and wraps raw PTY master input bytes in
 * TERMINAL_RX packets for the Z80.
 */

#include "protocol.h"
#include "serial_port.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef bool (*PtyConsoleShouldStop)(void *userdata);

typedef struct PtyConsole PtyConsole;

PtyConsole *pty_console_create(
    SerialPort *serial_port,
    bool log_packets,
    PtyConsoleShouldStop should_stop,
    void *should_stop_userdata);

bool pty_console_start(PtyConsole *console);
void pty_console_destroy(PtyConsole *console);

const char *pty_console_slave_path(const PtyConsole *console);

bool pty_console_handle_packet(PtyConsole *console, const Packet *packet);
void pty_console_set_storage_active(PtyConsole *console, bool active);

#endif
