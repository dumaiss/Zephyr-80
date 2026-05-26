"""Generate a Graphics I name-table indexing and edge-grid stream."""

from vdrip_packets import (
    COLOR_TABLE,
    NAME_TABLE,
    PATTERN_TABLE,
    box_pattern,
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
        patterns.extend(box_pattern(tile))
    packets += vdp_write_bytes(PATTERN_TABLE, patterns)

    colors = bytearray(((index % 15 + 1) << 4) | ((index + 3) % 15 + 1) for index in range(32))
    packets += vdp_write_bytes(COLOR_TABLE, colors)

    names = bytearray()
    for row in range(24):
        for col in range(32):
            names.append((row * 32 + col) & 0xFF)
    packets += vdp_write_bytes(NAME_TABLE, names)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("40_g1_name_table_grid.bin"), build_packets())
