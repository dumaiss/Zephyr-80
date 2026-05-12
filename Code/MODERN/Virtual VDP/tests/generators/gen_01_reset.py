"""Generate a minimal Virtual Drip control-packet smoke test."""

from vdrip_packets import output_path, ping, reset, write_packet_file


def build_packets():
    return [
        reset(),
        ping(),
    ]


if __name__ == "__main__":
    write_packet_file(output_path("01_reset.bin"), build_packets())
