#ifndef STORAGE_PROTOCOL_H
#define STORAGE_PROTOCOL_H

/**
 * @file storage_protocol.h
 * Virtual Drip storage packet handling for the serial proxy.
 */

#include "keyboard_transport.h"
#include "protocol.h"
#include "serial_port.h"
#include "storage_backend.h"

#include <stdbool.h>
#include <stdint.h>

bool storage_protocol_is_request_type(uint8_t type);
bool storage_protocol_handle_packet(
    const Packet *packet,
    SerialPort *serial_port,
    KeyboardTransport *keyboard_transport,
    StorageBackend *storage_backend,
    bool log_storage);

#endif
