; Virtual Drip wire protocol constants for Z80-side code.
;
; Packets are encoded as:
;   A5h 5Ah LEN_LO LEN_HI TYPE PAYLOAD...
;
; LEN is a 16-bit little-endian count of TYPE + PAYLOAD bytes.  The minimum
; declared length is 1, the proxy supports up to 1024 payload bytes, and there
; is no CRC or checksum. Cursor commands are proxy/display overlay commands;
; they do not write emulated VDP memory or registers.
;
; Current protocol split:
;   - proxy-to-Z80 keyboard input is raw after packetized readiness
;   - Z80-to-proxy display/control packets use this framing
;   - one common receive sink owns framed readiness and storage replies
;
; PACKET_KEY_EVENT is the legacy name for type 05h. The active BIOS console
; source calls the same value PACKET_TERMINAL_INPUT and keeps it inactive for
; normal keyboard input.

PACKET_SYNC0            = 0xa5
PACKET_SYNC1            = 0x5a

PACKET_VDP_CTRL_WRITE   = 0x01
PACKET_VDP_DATA_WRITE   = 0x02
PACKET_VDP_STATUS_READ  = 0x03
PACKET_VDP_DATA_READ    = 0x04
PACKET_KEY_EVENT        = 0x05
PACKET_TERMINAL_INPUT   = PACKET_KEY_EVENT
PACKET_RESET            = 0x06
PACKET_PING             = 0x07
PACKET_FRAME_MARK       = 0x08
PACKET_CURSOR_COMMAND   = 0x09
PACKET_PROXY_READY      = 0x0a
PACKET_VDP_DATA_BLOCK   = 0x0b
PACKET_VDP_SCROLL       = 0x0c
PACKET_STORAGE_READ_REQ = 0x0d
PACKET_STORAGE_READ_REPLY = 0x0e
PACKET_STORAGE_WRITE_REQ = 0x0f
PACKET_STORAGE_WRITE_REPLY = 0x10
PACKET_TERMINAL_TX      = 0x11
PACKET_TERMINAL_RX      = 0x12
PACKET_VDP_PALETTE_WRITE = 0x13
PACKET_VDP_INDIRECT_WRITE = 0x14
PACKET_PROTOCOL_ERROR   = 0x19
PACKET_COMMAND_STREAM   = 0x1a

OP_REG_BLOCK            = 0x10
OP_VRAM_ADDR_WRITE      = 0x11
OP_TEXT_RUN             = 0x30
OP_CELL_FILL            = 0x31
OP_CELL_COPY            = 0x32
OP_INSERT_LINES         = 0x33
OP_DELETE_LINES         = 0x34
OP_ERASE_EOL            = 0x35
OP_CLEAR_SCREEN         = 0x36
OP_SCROLL_REGION        = 0x37
OP_SCROLL_UP            = 0x38
OP_SET_CURSOR           = 0x40
OP_SET_ATTR             = 0x41
OP_SET_SCREEN_BASE      = 0x43
OP_SET_GLYPH_BASE       = 0x44
OP_SET_ATLAS_CONFIG     = 0x46
OP_SET_DISP_OFFSET      = 0x47
OP_PRESENT              = 0xfe
