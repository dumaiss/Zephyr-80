#include "packet_parser.h"

#include <stdio.h>
#include <string.h>

/*
 * This decoder is intentionally policy-free. It does not know whether bytes
 * came from a serial fd, a file, or a test harness, and it does not know about
 * the selected video backend. That keeps malformed-stream recovery identical
 * across all packet sources.
 */

void packet_parser_init(PacketParser *parser, PacketHandler handler, void *userdata)
{
    memset(parser, 0, sizeof(*parser));
    parser->state = PACKET_PARSER_WAIT_SYNC;
    parser->handler = handler;
    parser->userdata = userdata;
}

void packet_parser_feed(PacketParser *parser, uint8_t value)
{
    size_t current_offset = parser->offset++;

    switch (parser->state) {
    case PACKET_PARSER_WAIT_SYNC:
        /* Ignore noise until a framing byte appears. */
        if (value == PACKET_SYNC) {
            parser->packet_offset = current_offset;
            parser->state = PACKET_PARSER_READ_LENGTH;
        }
        break;
    case PACKET_PARSER_READ_LENGTH:
        parser->packet.length = value;
        parser->payload_index = 0;
        parser->state = PACKET_PARSER_READ_TYPE;
        break;
    case PACKET_PARSER_READ_TYPE:
        parser->packet.type = value;
        parser->state = parser->packet.length == 0 ? PACKET_PARSER_READ_CRC : PACKET_PARSER_READ_PAYLOAD;
        break;
    case PACKET_PARSER_READ_PAYLOAD:
        parser->packet.payload[parser->payload_index++] = value;
        if (parser->payload_index == parser->packet.length) {
            parser->state = PACKET_PARSER_READ_CRC;
        }
        break;
    case PACKET_PARSER_READ_CRC: {
        parser->packet.crc = value;
        uint8_t expected_crc = packet_crc8(&parser->packet);
        if (parser->packet.crc != expected_crc) {
            fprintf(stderr,
                "Packet CRC mismatch at offset %zu: expected 0x%02X, got 0x%02X\n",
                parser->packet_offset,
                expected_crc,
                parser->packet.crc);
            ++parser->crc_errors;
        } else {
            ++parser->packet_count;
            if (parser->handler != NULL) {
                parser->handler(&parser->packet, parser->packet_offset, parser->userdata);
            }
        }
        /* CRC errors are dropped; the next byte must start a fresh packet. */
        parser->state = PACKET_PARSER_WAIT_SYNC;
        break;
    }
    }
}

bool packet_parser_has_partial_packet(const PacketParser *parser)
{
    return parser->state != PACKET_PARSER_WAIT_SYNC;
}

size_t packet_parser_packet_count(const PacketParser *parser)
{
    return parser->packet_count;
}

size_t packet_parser_crc_errors(const PacketParser *parser)
{
    return parser->crc_errors;
}
