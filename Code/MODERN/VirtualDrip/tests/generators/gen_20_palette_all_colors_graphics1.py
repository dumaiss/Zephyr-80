"""Generate a Graphics I color-index visibility test."""

from vdrip_packets import (
    COLOR_TABLE,
    NAME_TABLE,
    PATTERN_TABLE,
    graphics1_registers,
    output_path,
    reset,
    vdp_write_bytes,
    write_packet_file,
)


def build_packets():
    packets = [reset()]

    # Graphics I table addresses:
    # pattern table: 0x0000
    # color table: 0x2000
    # name table: 0x3800
    packets += graphics1_registers(backdrop=0x01)

    patterns = bytearray()
    for tile in range(256):
        if tile < 16:
            patterns.extend([0xFF] * 8)
        else:
            patterns.extend([(0xAA if (row + tile) & 1 else 0x55) for row in range(8)])
    packets += vdp_write_bytes(PATTERN_TABLE, patterns)

    colors = bytearray()
    for group in range(32):
        foreground = group % 16
        background = (group + 1) % 16
        colors.append((foreground << 4) | background)
    packets += vdp_write_bytes(COLOR_TABLE, colors)

    names = bytearray()
    for row in range(24):
        for col in range(32):
            names.append((row // 3) * 2 + (col // 4))
    packets += vdp_write_bytes(NAME_TABLE, names)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("20_palette_all_colors_graphics1.bin"), build_packets())
