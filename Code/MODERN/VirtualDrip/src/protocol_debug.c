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
        if (packet->length == 1) {
            printf(" value=0x%02X", packet->payload[0]);
        }
        break;
    case PACKET_KEY_EVENT:
        if (packet->length >= 4) {
            printf(" flags=0x%02X ascii=0x%02X special=0x%02X modifiers=0x%02X",
                packet->payload[0],
                packet->payload[1],
                packet->payload[2],
                packet->payload[3]);
        }
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

const char *key_special_name(KeySpecialCode special)
{
    switch (special) {
    case KEY_SPECIAL_NONE:
        return "NONE";
    case KEY_SPECIAL_ENTER:
        return "ENTER";
    case KEY_SPECIAL_BACKSPACE:
        return "BACKSPACE";
    case KEY_SPECIAL_TAB:
        return "TAB";
    case KEY_SPECIAL_ESCAPE:
        return "ESCAPE";
    case KEY_SPECIAL_LEFT:
        return "LEFT";
    case KEY_SPECIAL_RIGHT:
        return "RIGHT";
    case KEY_SPECIAL_UP:
        return "UP";
    case KEY_SPECIAL_DOWN:
        return "DOWN";
    case KEY_SPECIAL_HOME:
        return "HOME";
    case KEY_SPECIAL_END:
        return "END";
    case KEY_SPECIAL_PAGE_UP:
        return "PAGE_UP";
    case KEY_SPECIAL_PAGE_DOWN:
        return "PAGE_DOWN";
    case KEY_SPECIAL_DELETE:
        return "DELETE";
    case KEY_SPECIAL_INSERT:
        return "INSERT";
    case KEY_SPECIAL_F1:
        return "F1";
    case KEY_SPECIAL_F2:
        return "F2";
    case KEY_SPECIAL_F3:
        return "F3";
    case KEY_SPECIAL_F4:
        return "F4";
    case KEY_SPECIAL_F5:
        return "F5";
    case KEY_SPECIAL_F6:
        return "F6";
    case KEY_SPECIAL_F7:
        return "F7";
    case KEY_SPECIAL_F8:
        return "F8";
    case KEY_SPECIAL_F9:
        return "F9";
    case KEY_SPECIAL_F10:
        return "F10";
    case KEY_SPECIAL_F11:
        return "F11";
    case KEY_SPECIAL_F12:
        return "F12";
    default:
        return "UNKNOWN";
    }
}
