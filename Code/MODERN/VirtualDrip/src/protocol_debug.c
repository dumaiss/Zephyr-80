#include "protocol_debug.h"

#include <stdio.h>

/* Keep verbose packet logging out of parser/dispatch core logic. */

void print_payload_hex(const uint8_t *payload, uint8_t length)
{
    if (length == 0) {
        printf("none");
        return;
    }

    for (uint8_t index = 0; index < length; ++index) {
        printf("%s%02X", index == 0 ? "" : " ", payload[index]);
    }
}

void print_packet_detail(const Packet *packet)
{
    switch (packet->type) {
    case PACKET_VDP_CTRL_WRITE:
    case PACKET_VDP_DATA_WRITE:
    case PACKET_VDP_DATA_BLOCK:
        if (packet->length == 1) {
            printf(" value=0x%02X", packet->payload[0]);
        } else if (packet->length > 1) {
            printf(" bytes=%u", packet->length);
        }
        break;
    case PACKET_TERMINAL_INPUT:
    case PACKET_TERMINAL_TX:
    case PACKET_TERMINAL_RX:
        printf(" terminal_bytes=");
        print_payload_hex(packet->payload, packet->length);
        break;
    default:
        break;
    }
}

void print_packet(size_t packet_index, size_t offset, const Packet *packet)
{
    printf(
        "#%zu offset=%zu type=0x%02X %-16s len=%u crc=0x%02X payload=",
        packet_index,
        offset,
        packet->type,
        packet_type_name(packet->type),
        packet->length,
        packet->crc);
    print_payload_hex(packet->payload, packet->length);
    print_packet_detail(packet);
    printf("\n");
}

void print_packet_bytes(const uint8_t *bytes, size_t length)
{
    for (size_t index = 0; index < length; ++index) {
        printf("%s%02X", index == 0 ? "" : " ", bytes[index]);
    }
}
