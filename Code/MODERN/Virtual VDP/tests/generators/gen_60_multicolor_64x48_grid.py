"""Generate a Multicolor mode 64x48 coarse color-grid stream."""

from vdrip_packets import (
    NAME_TABLE,
    PATTERN_TABLE,
    multicolor_registers,
    output_path,
    reset,
    vdp_write_bytes,
    write_packet_file,
)


def build_packets():
    packets = [reset()]

    # Multicolor mode table addresses:
    # pattern/color block table: 0x0000
    # name table: 0x3800
    packets += multicolor_registers(backdrop=0x01)

    names = bytearray((row * 32 + col) & 0xFF for row in range(24) for col in range(32))
    packets += vdp_write_bytes(NAME_TABLE, names)

    pattern_bytes = bytearray()
    for tile in range(256):
        for row_pair in range(4):
            left = ((tile + row_pair) % 15) + 1
            right = ((tile // 16 + row_pair * 3) % 15) + 1
            value = (left << 4) | right
            pattern_bytes.extend([value, value])
    packets += vdp_write_bytes(PATTERN_TABLE, pattern_bytes)
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("60_multicolor_64x48_grid.bin"), build_packets())
