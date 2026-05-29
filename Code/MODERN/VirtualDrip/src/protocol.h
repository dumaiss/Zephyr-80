#ifndef PROTOCOL_H
#define PROTOCOL_H

/**
 * @file protocol.h
 * Virtual Drip wire protocol definitions.
 *
 * Packets are encoded as:
 *   [SYNC0=0xA5][SYNC1=0x5A][LEN][TYPE][PAYLOAD...][CRC8]
 *
 * The two sync bytes are framing bytes and are not included in the CRC. LEN is
 * the byte count of the complete packet body after the sync bytes, including
 * LEN itself, TYPE, PAYLOAD, and CRC8. CRC8 covers LEN, TYPE, and PAYLOAD
 * using polynomial 0x07 with initial value 0x00.
 */

#include <stddef.h>
#include <stdint.h>

/** Packet stream framing bytes. Not included in the packet CRC. */
#define PACKET_SYNC0 0xA5
#define PACKET_SYNC1 0x5A
#define PACKET_SYNC_SIZE 2

/** Encoded bytes after SYNC that are not payload: LEN, TYPE, and CRC8. */
#define PACKET_WIRE_OVERHEAD 3

/** Minimum valid LEN byte: LEN, TYPE, and CRC8 with a zero-byte payload. */
#define PACKET_MIN_WIRE_LENGTH PACKET_WIRE_OVERHEAD

/** Maximum payload representable by the one-byte whole-body LEN field. */
#define MAX_PACKET_PAYLOAD (255 - PACKET_WIRE_OVERHEAD)

/**
 * Packet type values shared by file replay, serial input, and serial output.
 *
 * VDP_* packets flow from Zephyr or replay files into the video backend.
 * KEY_EVENT flows from the VNC/display side back to Zephyr over serial.
 * RESET and PING are Virtual Drip control packets, not TMS9928A port writes.
 * FRAME_MARK is a replay/pacing marker for animation tests; it is not a
 * hardware VBlank signal.
 */
typedef enum {
    PACKET_VDP_CTRL_WRITE = 0x01,
    PACKET_VDP_DATA_WRITE = 0x02,
    PACKET_VDP_STATUS_READ = 0x03,
    PACKET_VDP_DATA_READ = 0x04,
    PACKET_KEY_EVENT = 0x05,
    PACKET_RESET = 0x06,
    PACKET_PING = 0x07,
    PACKET_FRAME_MARK = 0x08,
    PACKET_CURSOR_COMMAND = 0x09,
} PacketType;

/** CURSOR_COMMAND payload byte 0 subcommands. */
typedef enum {
    CURSOR_ENABLE = 1,
    CURSOR_SHOW = 2,
    CURSOR_HIDE = 3,
    CURSOR_SET_POSITION = 4,
    CURSOR_MOVE_RELATIVE = 5,
    CURSOR_SET_STYLE = 6,
    CURSOR_SET_BLINK = 7,
    CURSOR_SET_COLOR = 8,
    CURSOR_SET_GEOMETRY = 9,
} CursorCommand;

/** Text cursor overlay styles. */
typedef enum {
    CURSOR_STYLE_BLOCK = 0,
    CURSOR_STYLE_UNDERLINE = 1,
    CURSOR_STYLE_LEFT_BAR = 2,
} CursorStyle;

/**
 * KEY_EVENT payload byte 0 flags.
 *
 * The minimal KEY_EVENT payload is four bytes:
 *   byte 0: these flags
 *   byte 1: ASCII value, or 0
 *   byte 2: KeySpecialCode value, or 0
 *   byte 3: KeyModifierFlags bitfield
 */
typedef enum {
    KEY_EVENT_FLAG_DOWN = 1 << 0,
    KEY_EVENT_FLAG_UP = 1 << 1,
    KEY_EVENT_FLAG_HAS_ASCII = 1 << 2,
    KEY_EVENT_FLAG_HAS_SPECIAL = 1 << 3,
} KeyEventFlags;

/** KEY_EVENT payload byte 3 modifier bits. */
typedef enum {
    KEY_MODIFIER_SHIFT = 1 << 0,
    KEY_MODIFIER_CTRL = 1 << 1,
    KEY_MODIFIER_ALT = 1 << 2,
    KEY_MODIFIER_META = 1 << 3,
} KeyModifierFlags;

/** Non-ASCII key codes carried in KEY_EVENT payload byte 2. */
typedef enum {
    KEY_SPECIAL_NONE = 0,
    KEY_SPECIAL_ENTER,
    KEY_SPECIAL_BACKSPACE,
    KEY_SPECIAL_TAB,
    KEY_SPECIAL_ESCAPE,
    KEY_SPECIAL_LEFT,
    KEY_SPECIAL_RIGHT,
    KEY_SPECIAL_UP,
    KEY_SPECIAL_DOWN,
    KEY_SPECIAL_HOME,
    KEY_SPECIAL_END,
    KEY_SPECIAL_PAGE_UP,
    KEY_SPECIAL_PAGE_DOWN,
    KEY_SPECIAL_DELETE,
    KEY_SPECIAL_INSERT,
    KEY_SPECIAL_F1,
    KEY_SPECIAL_F2,
    KEY_SPECIAL_F3,
    KEY_SPECIAL_F4,
    KEY_SPECIAL_F5,
    KEY_SPECIAL_F6,
    KEY_SPECIAL_F7,
    KEY_SPECIAL_F8,
    KEY_SPECIAL_F9,
    KEY_SPECIAL_F10,
    KEY_SPECIAL_F11,
    KEY_SPECIAL_F12,
} KeySpecialCode;

/**
 * Decoded packet representation.
 *
 * length is the decoded payload byte count. The wire LEN byte is derived as
 * length + PACKET_WIRE_OVERHEAD. The SYNC byte is intentionally not stored
 * here; this struct represents the CRC-covered body plus the received CRC.
 */
typedef struct {
    uint8_t length;
    uint8_t type;
    uint8_t payload[MAX_PACKET_PAYLOAD];
    uint8_t crc;
} Packet;

/**
 * Callback invoked for complete, CRC-valid packets.
 *
 * offset is the byte offset of the packet SYNC within the source stream.
 * userdata is caller-owned and passed through unchanged.
 */
typedef void (*PacketHandler)(const Packet *packet, size_t offset, void *userdata);

/** Update a CRC8 accumulator with one byte. */
uint8_t crc8_update(uint8_t crc, uint8_t value);

/** Compute CRC8 for LEN, TYPE, and PAYLOAD of a decoded packet. */
uint8_t packet_crc8(const Packet *packet);

/** Return the encoded LEN byte for a decoded packet. */
uint8_t packet_wire_length(const Packet *packet);

/** Return a stable debug name for a packet type value. */
const char *packet_type_name(uint8_t type);

#endif
