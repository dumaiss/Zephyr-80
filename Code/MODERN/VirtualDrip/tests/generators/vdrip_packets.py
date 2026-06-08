"""Helpers for generating Virtual Drip packet streams.

Packet constants mirror src/protocol.h:
  [SYNC0=0xA5][SYNC1=0x5A][LEN][TYPE][PAYLOAD...][CRC8]

LEN counts the complete packet body after the sync bytes: LEN, TYPE, PAYLOAD, and CRC8.
CRC8 covers LEN, TYPE, and PAYLOAD only.

These helpers generate VDP-visible state changes, not screenshots. The output
files can be fed to the proxy through file replay or streamed through
tools/serial_replay.py.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable


PACKET_SYNC0 = 0xA5
PACKET_SYNC1 = 0x5A

PACKET_VDP_CTRL_WRITE = 0x01
PACKET_VDP_DATA_WRITE = 0x02
PACKET_VDP_STATUS_READ = 0x03
PACKET_VDP_DATA_READ = 0x04
PACKET_TERMINAL_INPUT = 0x05
PACKET_KEYBOARD_INPUT = PACKET_TERMINAL_INPUT
PACKET_RESET = 0x06
PACKET_PING = 0x07
PACKET_FRAME_MARK = 0x08
PACKET_CURSOR_COMMAND = 0x09
PACKET_PROXY_READY = 0x0A
PACKET_VDP_DATA_BLOCK = 0x0B
PACKET_VDP_SCROLL = 0x0C
PACKET_STORAGE_READ_REQ = 0x0D
PACKET_STORAGE_READ_REPLY = 0x0E
PACKET_STORAGE_WRITE_REQ = 0x0F
PACKET_STORAGE_WRITE_REPLY = 0x10
PACKET_TERMINAL_TX = 0x11
PACKET_TERMINAL_RX = 0x12

CURSOR_ENABLE = 0x01
CURSOR_SHOW = 0x02
CURSOR_HIDE = 0x03
CURSOR_SET_POSITION = 0x04
CURSOR_MOVE_RELATIVE = 0x05
CURSOR_SET_STYLE = 0x06
CURSOR_SET_BLINK = 0x07
CURSOR_SET_COLOR = 0x08
CURSOR_SET_GEOMETRY = 0x09

CURSOR_STYLE_BLOCK = 0x00
CURSOR_STYLE_UNDERLINE = 0x01
CURSOR_STYLE_LEFT_BAR = 0x02

PATTERN_TABLE = 0x0000
SPRITE_PATTERN_TABLE = 0x1800
COLOR_TABLE = 0x2000
NAME_TABLE = 0x3800
SPRITE_ATTRIBUTE_TABLE = 0x3B00

TEXT_NAME_TABLE = 0x0800
TEXT_PATTERN_TABLE = 0x0000

G2_PATTERN_TABLE = 0x0000
G2_COLOR_TABLE = 0x2000
G2_NAME_TABLE = 0x3800


def crc8(data: bytes | bytearray | Iterable[int]) -> int:
    """Return protocol CRC8 using polynomial 0x07 and initial value 0x00."""

    crc = 0
    for value in data:
        crc ^= value & 0xFF
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def packet(packet_type: int, payload: bytes | bytearray | Iterable[int] = b"") -> bytes:
    """Wrap one packet as SYNC, LEN, TYPE, PAYLOAD, CRC8."""

    body_payload = bytes(payload)
    if len(body_payload) > 252:
        raise ValueError("Virtual Drip packets support at most 252 payload bytes")

    wire_length = len(body_payload) + 3
    body = bytes([wire_length, packet_type & 0xFF]) + body_payload
    return bytes([PACKET_SYNC0, PACKET_SYNC1]) + body + bytes([crc8(body)])


def vdp_ctrl(value: int) -> bytes:
    """Create a VDP control-port write packet."""

    return packet(PACKET_VDP_CTRL_WRITE, bytes([value & 0xFF]))


def vdp_data(value: int) -> bytes:
    """Create a VDP data-port write packet."""

    return packet(PACKET_VDP_DATA_WRITE, bytes([value & 0xFF]))


def vdp_set_register(reg: int, value: int) -> list[bytes]:
    """Create the two control writes used by the TMS9918 register protocol."""

    return [
        vdp_ctrl(value),
        vdp_ctrl(0x80 | (reg & 0x07)),
    ]


def vdp_set_write_address(address: int) -> list[bytes]:
    """Create control writes that set the TMS9918 VRAM write address."""

    address &= 0x3FFF
    return [
        vdp_ctrl(address & 0xFF),
        vdp_ctrl(0x40 | ((address >> 8) & 0x3F)),
    ]


def vdp_write_bytes(address: int, data: bytes | bytearray | Iterable[int]) -> list[bytes]:
    """Write a byte sequence to VRAM through normal data-port packets."""

    packets = vdp_set_write_address(address)
    packets.extend(vdp_data(value) for value in bytes(data))
    return packets


def reset() -> bytes:
    """Create a Virtual Drip RESET control packet."""

    return packet(PACKET_RESET)


def ping() -> bytes:
    """Create a Virtual Drip PING control packet."""

    return packet(PACKET_PING)


def frame_mark() -> bytes:
    """Create a FRAME_MARK pacing packet for animation replay tools."""

    return packet(PACKET_FRAME_MARK)


def cursor_command(subcommand: int, *args: int) -> bytes:
    """Create a text cursor overlay command packet."""

    payload = bytes([subcommand & 0xFF] + [arg & 0xFF for arg in args])
    return packet(PACKET_CURSOR_COMMAND, payload)


def write_packet_file(path: str | Path, packets: Iterable[bytes]) -> None:
    """Write encoded packets to a binary fixture file."""

    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(b"".join(packets))


def output_path(filename: str) -> Path:
    """Return the standard tests/packets output path for a generated fixture."""

    return Path(__file__).resolve().parents[1] / "packets" / filename


def graphics1_registers(backdrop: int = 0x04) -> list[bytes]:
    """Graphics I, display on, 16 KiB VRAM, sprites enabled.

    Table addresses:
      pattern table: 0x0000
      sprite pattern table: 0x1800
      color table: 0x2000
      name table: 0x3800
      sprite attribute table: 0x3B00
    """

    packets: list[bytes] = []
    packets += vdp_set_register(0, 0x00)
    packets += vdp_set_register(1, 0xC0)
    packets += vdp_set_register(2, NAME_TABLE >> 10)
    packets += vdp_set_register(3, COLOR_TABLE >> 6)
    packets += vdp_set_register(4, PATTERN_TABLE >> 11)
    packets += vdp_set_register(5, SPRITE_ATTRIBUTE_TABLE >> 7)
    packets += vdp_set_register(6, SPRITE_PATTERN_TABLE >> 11)
    packets += vdp_set_register(7, ((0x0F << 4) | (backdrop & 0x0F)))
    return packets


def graphics2_registers(backdrop: int = 0x04) -> list[bytes]:
    """Graphics II with full pattern/color table masks enabled.

    Table addresses:
      pattern table thirds: 0x0000, 0x0800, 0x1000
      color table thirds: 0x2000, 0x2800, 0x3000
      name table: 0x3800
    """

    packets: list[bytes] = []
    packets += vdp_set_register(0, 0x02)
    packets += vdp_set_register(1, 0xC0)
    packets += vdp_set_register(2, G2_NAME_TABLE >> 10)
    packets += vdp_set_register(3, 0xFF)
    packets += vdp_set_register(4, 0x03)
    packets += vdp_set_register(5, SPRITE_ATTRIBUTE_TABLE >> 7)
    packets += vdp_set_register(6, SPRITE_PATTERN_TABLE >> 11)
    packets += vdp_set_register(7, ((0x0F << 4) | (backdrop & 0x0F)))
    return packets


def text_mode_registers(backdrop: int = 0x04) -> list[bytes]:
    """Text mode, 40x24 characters.

    Table addresses:
      pattern table: 0x0000
      name table: 0x0800
    """

    packets: list[bytes] = []
    packets += vdp_set_register(0, 0x00)
    packets += vdp_set_register(1, 0xD0)
    packets += vdp_set_register(2, TEXT_NAME_TABLE >> 10)
    packets += vdp_set_register(3, COLOR_TABLE >> 6)
    packets += vdp_set_register(4, TEXT_PATTERN_TABLE >> 11)
    packets += vdp_set_register(5, SPRITE_ATTRIBUTE_TABLE >> 7)
    packets += vdp_set_register(6, SPRITE_PATTERN_TABLE >> 11)
    packets += vdp_set_register(7, ((0x0F << 4) | (backdrop & 0x0F)))
    return packets


def multicolor_registers(backdrop: int = 0x04) -> list[bytes]:
    """Multicolor mode.

    Table addresses:
      pattern/color block table: 0x0000
      name table: 0x3800
    """

    packets: list[bytes] = []
    packets += vdp_set_register(0, 0x00)
    packets += vdp_set_register(1, 0xC8)
    packets += vdp_set_register(2, NAME_TABLE >> 10)
    packets += vdp_set_register(3, COLOR_TABLE >> 6)
    packets += vdp_set_register(4, PATTERN_TABLE >> 11)
    packets += vdp_set_register(5, SPRITE_ATTRIBUTE_TABLE >> 7)
    packets += vdp_set_register(6, SPRITE_PATTERN_TABLE >> 11)
    packets += vdp_set_register(7, ((0x0F << 4) | (backdrop & 0x0F)))
    return packets


def box_pattern(seed: int) -> bytes:
    """Return a readable 8x8 tile pattern from a small seed."""

    seed &= 0x07
    patterns = [
        [0xFF, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0xFF],
        [0xFF, 0x99, 0x99, 0xFF, 0xFF, 0x99, 0x99, 0xFF],
        [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55],
        [0x18, 0x3C, 0x7E, 0xFF, 0xFF, 0x7E, 0x3C, 0x18],
        [0xF0, 0xF0, 0xF0, 0xF0, 0x0F, 0x0F, 0x0F, 0x0F],
        [0xC3, 0x66, 0x3C, 0x18, 0x18, 0x3C, 0x66, 0xC3],
        [0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE, 0xFF],
        [0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88],
    ]
    return bytes(patterns[seed])


def sprite_cross_pattern() -> bytes:
    """Return an 8x8 sprite pattern with transparent background bits."""

    return bytes([0x18, 0x3C, 0x7E, 0xDB, 0xFF, 0x24, 0x66, 0xC3])


def sprite_diamond_pattern() -> bytes:
    """Return an 8x8 diamond sprite pattern."""

    return bytes([0x18, 0x3C, 0x7E, 0xFF, 0x7E, 0x3C, 0x18, 0x00])


def sprite_attributes(entries: Iterable[tuple[int, int, int, int]]) -> bytes:
    """Encode sprite attribute entries and append the TMS9918 terminator."""

    data = bytearray()
    for y, x, pattern_index, color in entries:
        data.extend([y & 0xFF, x & 0xFF, pattern_index & 0xFF, color & 0x0F])
    data.extend([0xD0, 0x00, 0x00, 0x00])
    return bytes(data)
