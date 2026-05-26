#ifndef PROTOCOL_DEBUG_H
#define PROTOCOL_DEBUG_H

/**
 * @file protocol_debug.h
 * Debug formatting helpers for decoded packets and keyboard codes.
 *
 * These functions are for human-readable logs only. They do not participate in
 * packet validation, dispatch, or protocol decisions.
 */

#include "protocol.h"

#include <stddef.h>
#include <stdint.h>

/** Print payload bytes as uppercase hex, or "none" for an empty payload. */
void print_payload_hex(const uint8_t *payload, uint8_t length);

/** Print packet-type-specific details such as data value or key fields. */
void print_packet_detail(const Packet *packet);

/** Print a complete decoded packet log line. */
void print_packet(size_t packet_index, size_t offset, const Packet *packet);

/** Print already-encoded packet bytes as uppercase hex. */
void print_packet_bytes(const uint8_t *bytes, size_t length);

/** Return a debug name for a KeySpecialCode value. */
const char *key_special_name(KeySpecialCode special);

#endif
