"""Generate a Graphics II three-band pattern/color table test."""

from vdrip_packets import (
    G2_COLOR_TABLE,
    G2_NAME_TABLE,
    G2_PATTERN_TABLE,
    graphics2_registers,
    output_path,
    reset,
    vdp_write_bytes,
    write_packet_file,
)


def band_pattern(band: int, tile: int) -> bytes:
    if band == 0:
        return bytes([0xF0 if row % 2 == 0 else 0x0F for row in range(8)])
    if band == 1:
        return bytes([0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81])
    return bytes([0x18, 0x18, 0x3C, 0x3C, 0x7E, 0x7E, 0xFF, tile & 0xFF])


def build_packets():
    packets = [reset()]

    # Graphics II table addresses:
    # pattern table thirds: 0x0000, 0x0800, 0x1000
    # color table thirds: 0x2000, 0x2800, 0x3000
    # name table: 0x3800
    packets += graphics2_registers(backdrop=0x01)

    names = bytearray((row * 32 + col) & 0xFF for row in range(24) for col in range(32))
    packets += vdp_write_bytes(G2_NAME_TABLE, names)

    for band in range(3):
        patterns = bytearray()
        colors = bytearray()
        for tile in range(256):
            patterns.extend(band_pattern(band, tile))
            fg = [0x02, 0x06, 0x0F][band]
            bg = [0x04, 0x09, 0x0D][band]
            colors.extend([((fg << 4) | bg)] * 8)
        packets += vdp_write_bytes(G2_PATTERN_TABLE + (band * 0x0800), patterns)
        packets += vdp_write_bytes(G2_COLOR_TABLE + (band * 0x0800), colors)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("50_g2_three_bands.bin"), build_packets())
