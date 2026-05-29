# Virtual Drip Packet Tests

These tests generate Virtual Drip packet streams that exercise VDP-visible
state changes through the same packet protocol that Zephyr-80 will use:

```text
[SYNC0=0xA5][SYNC1=0x5A][LEN][TYPE][PAYLOAD...][CRC8]

`LEN` counts the complete packet body after the sync bytes, including `LEN`,
`TYPE`, `PAYLOAD`, and `CRC8`.
```

The generators write TMS9928A register and VRAM operations using
`VDP_CTRL_WRITE` and `VDP_DATA_WRITE` packets. They do not generate final RGB
pixels.

## Generate

```bash
python3 tests/generators/generate_all.py
```

Outputs are written to `tests/packets/`.

## Test Files

- `01_reset.bin`: sends `RESET` and `PING` to verify basic non-VDP control packets are accepted.
- `10_set_registers.bin`: small Graphics I register setup using control-port writes only.
- `20_palette_all_colors_graphics1.bin`: Graphics I screen showing all 16 TMS9918 color indices.
- `30_text_mode_ascii_grid.bin`: Text mode 40x24 character-grid test for 6x8 rendering and edges.
- `31_text_mode_cursor_overlay.bin`: Text mode grid with a visible Virtual Drip cursor overlay.
- `40_g1_name_table_grid.bin`: Graphics I 32x24 tile/name-table indexing and boundary test.
- `50_g2_three_bands.bin`: Graphics II top/middle/bottom thirds with different pattern and color table data.
- `60_multicolor_64x48_grid.bin`: Multicolor mode coarse 64x48 color grid.
- `70_sprite_8x8_basic.bin`: Graphics I background with several 8x8 sprites and transparent pixels.
- `77_sprite_4_per_scanline_limit.bin`: five sprites on one scanline to expose the four-sprite display limit.
- `91_frame_mark_sprite_motion.bin`: animated sprite motion with `FRAME_MARK` packets for paced serial replay.

## File Replay

Static files can be replayed directly through the proxy:

```bash
./build/virtual-vdp --file tests/packets/50_g2_three_bands.bin
```

For non-visual decoder smoke tests:

```bash
./build/virtual-vdp --file tests/packets/50_g2_three_bands.bin --no-vnc
```

## Paced Animation Replay

File replay reaches the final frame immediately. To observe animation, stream
the packet file through the serial path and pace on `FRAME_MARK` packets:

```bash
python3 tools/serial_replay.py tests/packets/91_frame_mark_sprite_motion.bin \
  --port /tmp/vdrip-host \
  --baud 115200 \
  --frame-delay-ms 16.67 \
  --verbose
```

## Generator Layout

```text
tests/generators/
  vdrip_packets.py
  generate_all.py
  gen_01_reset.py
  gen_10_set_registers.py
  gen_20_palette_all_colors_graphics1.py
  gen_30_text_mode_ascii_grid.py
  gen_40_g1_name_table_grid.py
  gen_50_g2_three_bands.py
  gen_60_multicolor_64x48_grid.py
  gen_70_sprite_8x8_basic.py
  gen_77_sprite_4_per_scanline_limit.py
  gen_91_frame_mark_sprite_motion.py
```

`vdrip_packets.py` mirrors the packet type values from `src/protocol.h` and
contains helpers for CRC8, packet wrapping, TMS9928A register writes, VRAM write
address setup, and packet-file output.

## Legacy Fixtures

Older fixtures remain at the top of `tests/`:

- `packets.bin`: Graphics I checkerboard pattern.
- `test-bars-smiley.bin`: Graphics I vertical color bars with a small smiley tile.
- `sprite-moving.bin`: earlier sprite-motion test using `FRAME_MARK` packets.
