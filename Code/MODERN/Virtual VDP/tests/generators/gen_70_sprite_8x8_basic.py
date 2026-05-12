"""Generate a basic 8x8 sprite rendering stream."""

from vdrip_packets import (
    COLOR_TABLE,
    NAME_TABLE,
    PATTERN_TABLE,
    SPRITE_ATTRIBUTE_TABLE,
    SPRITE_PATTERN_TABLE,
    box_pattern,
    graphics1_registers,
    output_path,
    reset,
    sprite_attributes,
    sprite_cross_pattern,
    sprite_diamond_pattern,
    vdp_write_bytes,
    write_packet_file,
)


def build_packets():
    packets = [reset()]

    # Graphics I background with 8x8 sprites.
    # pattern table: 0x0000
    # color table: 0x2000
    # name table: 0x3800
    # sprite pattern table: 0x1800
    # sprite attribute table: 0x3B00
    packets += graphics1_registers(backdrop=0x04)

    patterns = bytearray()
    for tile in range(256):
        patterns.extend(box_pattern(tile))
    packets += vdp_write_bytes(PATTERN_TABLE, patterns)
    packets += vdp_write_bytes(COLOR_TABLE, bytes([(0x0F << 4) | 0x04] * 32))

    names = bytearray((row + col) % 8 for row in range(24) for col in range(32))
    packets += vdp_write_bytes(NAME_TABLE, names)

    sprite_patterns = bytearray([0x00] * (4 * 8))
    sprite_patterns[0:8] = sprite_cross_pattern()
    sprite_patterns[8:16] = sprite_diamond_pattern()
    sprite_patterns[16:24] = bytes([0x3C, 0x42, 0xA5, 0x81, 0xA5, 0x99, 0x42, 0x3C])
    packets += vdp_write_bytes(SPRITE_PATTERN_TABLE, sprite_patterns)

    attrs = sprite_attributes(
        [
            (40, 40, 0, 0x08),
            (72, 96, 1, 0x0A),
            (112, 152, 2, 0x0F),
        ]
    )
    packets += vdp_write_bytes(SPRITE_ATTRIBUTE_TABLE, attrs)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("70_sprite_8x8_basic.bin"), build_packets())
