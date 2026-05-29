#ifndef PACKET_PARSER_H
#define PACKET_PARSER_H

/**
 * @file packet_parser.h
 * Streaming byte-oriented Virtual Drip packet decoder.
 *
 * The parser accepts bytes from serial input, file replay, or tests. It finds
 * PACKET_SYNC0/PACKET_SYNC1, reads the whole-body LEN, TYPE, PAYLOAD, and CRC,
 * validates CRC, and emits only complete valid packets through PacketHandler.
 * It owns decoding state only; packet interpretation belongs to higher layers
 * such as packet dispatch and video backends.
 */

#include "protocol.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/** Current byte expected by the streaming parser state machine. */
typedef enum {
    /** Ignore input until PACKET_SYNC is seen. */
    PACKET_PARSER_WAIT_SYNC0,
    /** Read the second sync byte. */
    PACKET_PARSER_WAIT_SYNC1,
    /** Read LEN, the byte count after SYNC including LEN, TYPE, payload, CRC. */
    PACKET_PARSER_READ_LENGTH,
    /** Read TYPE. */
    PACKET_PARSER_READ_TYPE,
    /** Read the decoded payload byte count derived from LEN. */
    PACKET_PARSER_READ_PAYLOAD,
    /** Read CRC and either emit or drop the packet. */
    PACKET_PARSER_READ_CRC,
} PacketParserState;

/**
 * Stateful packet decoder.
 *
 * offset tracks all bytes fed to the parser. packet_offset records the SYNC
 * offset of the packet currently being assembled. CRC failures are counted and
 * dropped; the parser then returns to WAIT_SYNC0 to resynchronize on the next
 * valid framing sequence.
 */
typedef struct {
    /** Current point in the packet framing state machine. */
    PacketParserState state;
    /** Packet currently being assembled. Valid only after CRC succeeds. */
    Packet packet;
    /** Number of payload bytes already copied into packet.payload. */
    uint8_t payload_index;
    /** Absolute byte offset of the next byte to consume. */
    size_t offset;
    /** Absolute byte offset where the current packet's SYNC was seen. */
    size_t packet_offset;
    /** Count of valid packets emitted. */
    size_t packet_count;
    /** Count of CRC-invalid packets dropped. */
    size_t crc_errors;
    /** Callback for valid complete packets. May be NULL. */
    PacketHandler handler;
    /** Caller-owned context passed to handler. */
    void *userdata;
} PacketParser;

/** Initialize a parser and register the callback for valid packets. */
void packet_parser_init(PacketParser *parser, PacketHandler handler, void *userdata);

/** Feed one byte into the parser; may synchronously invoke the callback. */
void packet_parser_feed(PacketParser *parser, uint8_t value);

/** Return true when EOF would leave a truncated packet. */
bool packet_parser_has_partial_packet(const PacketParser *parser);

/** Number of valid packets emitted through the callback. */
size_t packet_parser_packet_count(const PacketParser *parser);

/** Number of CRC-invalid packets discarded. */
size_t packet_parser_crc_errors(const PacketParser *parser);

#endif
