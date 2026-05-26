"""Generate a small Graphics I register initialization stream."""

from vdrip_packets import graphics1_registers, output_path, reset, write_packet_file


def build_packets():
    # Graphics I register setup only.
    # pattern table: 0x0000
    # color table: 0x2000
    # name table: 0x3800
    # sprite attribute table: 0x3B00
    # sprite pattern table: 0x1800
    return [reset(), *graphics1_registers()]


if __name__ == "__main__":
    write_packet_file(output_path("10_set_registers.bin"), build_packets())
