"""Generate a Text mode stream with a visible proxy cursor overlay."""

from gen_30_text_mode_ascii_grid import build_packets as build_text_grid
from vdrip_packets import (
    CURSOR_ENABLE,
    CURSOR_SET_COLOR,
    CURSOR_SET_POSITION,
    CURSOR_SET_STYLE,
    CURSOR_SHOW,
    CURSOR_STYLE_BLOCK,
    cursor_command,
    output_path,
    write_packet_file,
)


def build_packets():
    packets = build_text_grid()
    packets.append(cursor_command(CURSOR_ENABLE, 1))
    packets.append(cursor_command(CURSOR_SET_COLOR, 255, 255, 0))
    packets.append(cursor_command(CURSOR_SET_STYLE, CURSOR_STYLE_BLOCK))
    packets.append(cursor_command(CURSOR_SET_POSITION, 20, 12))
    packets.append(cursor_command(CURSOR_SHOW))
    return packets


if __name__ == "__main__":
    write_packet_file(output_path("31_text_mode_cursor_overlay.bin"), build_packets())
