"""Generate a Text mode 40x24 character-grid stream."""

from vdrip_packets import (
    TEXT_NAME_TABLE,
    TEXT_PATTERN_TABLE,
    output_path,
    reset,
    text_mode_registers,
    vdp_write_bytes,
    write_packet_file,
)


def glyph(code: int) -> bytes:
    if code == 32:
        return bytes([0x00] * 8)
    top_bottom = 0xFC if code & 1 else 0x78
    left_right = 0x84 if code & 2 else 0x48
    middle = 0xFC if code & 4 else 0x30
    return bytes([top_bottom, left_right, left_right, middle, left_right, left_right, top_bottom, 0x00])


def build_packets():
    packets = [reset()]

    # Text mode table addresses:
    # pattern table: 0x0000
    # name table: 0x0800
    packets += text_mode_registers(backdrop=0x04)

    patterns = bytearray()
    for code in range(256):
        patterns.extend(glyph(code))
    packets += vdp_write_bytes(TEXT_PATTERN_TABLE, patterns)

    names = bytearray()
    for row in range(24):
        for col in range(40):
            if row in (0, 23) or col in (0, 39):
                names.append(ord("#"))
            else:
                names.append(32 + ((row * 40 + col) % 95))
    packets += vdp_write_bytes(TEXT_NAME_TABLE, names)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("30_text_mode_ascii_grid.bin"), build_packets())
