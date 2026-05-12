#include "protocol.h"

/*
 * Protocol helpers are deliberately small and dependency-free so every packet
 * source and sink can share the same CRC/type interpretation. The framing SYNC
 * byte is handled by stream encoders/decoders, not by packet_crc8().
 */

uint8_t crc8_update(uint8_t crc, uint8_t value)
{
    crc ^= value;
    for (int bit = 0; bit < 8; ++bit) {
        crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
    }

    return crc;
}

uint8_t packet_crc8(const Packet *packet)
{
    uint8_t crc = 0;

    crc = crc8_update(crc, packet->length);
    crc = crc8_update(crc, packet->type);
    for (uint8_t index = 0; index < packet->length; ++index) {
        crc = crc8_update(crc, packet->payload[index]);
    }

    return crc;
}

const char *packet_type_name(uint8_t type)
{
    switch (type) {
    case PACKET_VDP_CTRL_WRITE:
        return "VDP_CTRL_WRITE";
    case PACKET_VDP_DATA_WRITE:
        return "VDP_DATA_WRITE";
    case PACKET_VDP_STATUS_READ:
        return "VDP_STATUS_READ";
    case PACKET_VDP_DATA_READ:
        return "VDP_DATA_READ";
    case PACKET_KEY_EVENT:
        return "KEY_EVENT";
    case PACKET_RESET:
        return "RESET";
    case PACKET_PING:
        return "PING";
    case PACKET_FRAME_MARK:
        return "FRAME_MARK";
    default:
        return "UNKNOWN";
    }
}
