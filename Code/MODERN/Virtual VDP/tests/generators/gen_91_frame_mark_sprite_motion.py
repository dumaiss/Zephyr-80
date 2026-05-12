"""Generate a FRAME_MARK-paced sprite motion stream."""

from vdrip_packets import (
    COLOR_TABLE,
    NAME_TABLE,
    PATTERN_TABLE,
    SPRITE_ATTRIBUTE_TABLE,
    SPRITE_PATTERN_TABLE,
    box_pattern,
    frame_mark,
    graphics1_registers,
    output_path,
    reset,
    sprite_attributes,
    sprite_diamond_pattern,
    vdp_write_bytes,
    write_packet_file,
)


def build_packets():
    packets = [reset()]

    # Graphics I animation.
    # pattern table: 0x0000
    # color table: 0x2000
    # name table: 0x3800
    # sprite pattern table: 0x1800
    # sprite attribute table: 0x3B00
    packets += graphics1_registers(backdrop=0x04)

    patterns = bytearray()
    for tile in range(256):
        patterns.extend(box_pattern(tile & 1))
    packets += vdp_write_bytes(PATTERN_TABLE, patterns)
    packets += vdp_write_bytes(COLOR_TABLE, bytes([(0x0F << 4) | 0x04] * 32))
    names = bytearray((row + col) & 1 for row in range(24) for col in range(32))
    packets += vdp_write_bytes(NAME_TABLE, names)
    packets += vdp_write_bytes(SPRITE_PATTERN_TABLE, sprite_diamond_pattern())

    for frame in range(36):
        x = 16 + frame * 6
        y = 32 + ((frame % 12) * 4)
        attrs = sprite_attributes([(y, x, 0, 0x0F)])
        packets += vdp_write_bytes(SPRITE_ATTRIBUTE_TABLE, attrs)
        packets.append(frame_mark())
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("91_frame_mark_sprite_motion.bin"), build_packets())
