#ifndef KEYBOARD_TRANSPORT_H
#define KEYBOARD_TRANSPORT_H

/**
 * @file keyboard_transport.h
 * Nonblocking raw keyboard enqueue path plus the gated serial writer.
 */

#include "protocol.h"
#include "serial_port.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KEYBOARD_QUEUE_SIZE 1024
#define KEYBOARD_INPUT_MAX_BYTES 16

typedef enum {
    TRANSPORT_INTERACTIVE,
    TRANSPORT_VDP_BUSY,
} TransportMode;

typedef struct {
    uint8_t length;
    uint8_t bytes[KEYBOARD_INPUT_MAX_BYTES];
} QueuedInput;

typedef struct {
    uint64_t terminal_events_seen;
    uint64_t terminal_packets_queued;
    uint64_t terminal_bytes_queued;
    uint64_t terminal_packets_sent;
    uint64_t terminal_packets_dropped;
    uint64_t unsupported_key_count;
    uint64_t keyboard_events_seen;
    uint64_t keyboard_packets_queued;
    uint64_t keyboard_packets_sent;
    uint64_t keyboard_packets_failed;
    uint64_t keyboard_queue_dropped;
    size_t keyboard_queue_high_water;
    uint64_t keyboard_held_due_to_vdp;
    uint64_t keyboard_held_due_to_storage;
    uint64_t vdp_busy_enter_count;
    uint64_t storage_busy_enter_count;
    uint64_t frame_mark_count;
    uint64_t vdp_busy_timeout_count;
    TransportMode mode;
    bool storage_active;
} KeyboardTransportStats;

typedef struct KeyboardTransport KeyboardTransport;

KeyboardTransport *keyboard_transport_create(SerialPort *serial_port);
void keyboard_transport_destroy(KeyboardTransport *transport);

bool keyboard_transport_start(KeyboardTransport *transport);
void keyboard_transport_stop(KeyboardTransport *transport);

bool keyboard_transport_enqueue(
    KeyboardTransport *transport,
    const uint8_t *bytes,
    uint8_t length);

void keyboard_transport_note_keyboard_event(KeyboardTransport *transport);
void keyboard_transport_note_unsupported_key(KeyboardTransport *transport);
void keyboard_transport_note_incoming_packet(KeyboardTransport *transport, const Packet *packet);
void keyboard_transport_set_storage_active(KeyboardTransport *transport, bool active);
void keyboard_transport_get_stats(KeyboardTransport *transport, KeyboardTransportStats *stats);

#endif
