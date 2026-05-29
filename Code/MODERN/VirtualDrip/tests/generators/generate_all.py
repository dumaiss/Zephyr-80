"""Generate all Virtual Drip packet fixtures under tests/packets."""

from gen_01_reset import build_packets as build_01
from gen_10_set_registers import build_packets as build_10
from gen_20_palette_all_colors_graphics1 import build_packets as build_20
from gen_30_text_mode_ascii_grid import build_packets as build_30
from gen_31_text_mode_cursor_overlay import build_packets as build_31
from gen_40_g1_name_table_grid import build_packets as build_40
from gen_50_g2_three_bands import build_packets as build_50
from gen_60_multicolor_64x48_grid import build_packets as build_60
from gen_70_sprite_8x8_basic import build_packets as build_70
from gen_77_sprite_4_per_scanline_limit import build_packets as build_77
from gen_91_frame_mark_sprite_motion import build_packets as build_91
from vdrip_packets import output_path, write_packet_file


GENERATORS = [
    ("01_reset.bin", build_01),
    ("10_set_registers.bin", build_10),
    ("20_palette_all_colors_graphics1.bin", build_20),
    ("30_text_mode_ascii_grid.bin", build_30),
    ("31_text_mode_cursor_overlay.bin", build_31),
    ("40_g1_name_table_grid.bin", build_40),
    ("50_g2_three_bands.bin", build_50),
    ("60_multicolor_64x48_grid.bin", build_60),
    ("70_sprite_8x8_basic.bin", build_70),
    ("77_sprite_4_per_scanline_limit.bin", build_77),
    ("91_frame_mark_sprite_motion.bin", build_91),
]


def main() -> None:
    for filename, build_packets in GENERATORS:
        path = output_path(filename)
        write_packet_file(path, build_packets())
        print(f"generated {path}")


if __name__ == "__main__":
    main()
