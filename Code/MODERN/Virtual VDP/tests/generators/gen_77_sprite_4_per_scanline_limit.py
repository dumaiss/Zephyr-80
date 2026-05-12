"""Generate a five-sprites-on-one-scanline limit test."""

from vdrip_packets import (
    COLOR_TABLE,
    NAME_TABLE,
    PATTERN_TABLE,
    SPRITE_ATTRIBUTE_TABLE,
    SPRITE_PATTERN_TABLE,
    graphics1_registers,
    output_path,
    reset,
    sprite_attributes,
    sprite_cross_pattern,
    vdp_write_bytes,
    write_packet_file,
)


def build_packets():
    packets = [reset()]

    # Graphics I background with 5 sprites on one scanline.
    # pattern table: 0x0000
    # color table: 0x2000
    # name table: 0x3800
    # sprite pattern table: 0x1800
    # sprite attribute table: 0x3B00
    packets += graphics1_registers(backdrop=0x04)

    packets += vdp_write_bytes(PATTERN_TABLE, bytes([0x00] * (256 * 8)))
    packets += vdp_write_bytes(COLOR_TABLE, bytes([(0x0F << 4) | 0x04] * 32))
    packets += vdp_write_bytes(NAME_TABLE, bytes([0] * (32 * 24)))
    packets += vdp_write_bytes(SPRITE_PATTERN_TABLE, sprite_cross_pattern())

    attrs = sprite_attributes(
        [
            (80, 32, 0, 0x08),
            (80, 56, 0, 0x0A),
            (80, 80, 0, 0x0B),
            (80, 104, 0, 0x0C),
            (80, 128, 0, 0x0F),
        ]
    )
    packets += vdp_write_bytes(SPRITE_ATTRIBUTE_TABLE, attrs)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("77_sprite_4_per_scanline_limit.bin"), build_packets())
