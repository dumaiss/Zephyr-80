# The V9958 video card

The LunchCrema card carries a Yamaha V9958 with 128 KiB of VRAM on the pBITz
backplane at A0h–BFh. The machine uses MAME's stock `v9958_device` for every
function of the chip; the machine adds only the port decode, the VRAM size, the
screen type and the interrupt route.

The code is in `mame/src/mame/pbitz/zephyr80.cpp` (`vdp_r`, `vdp_w`,
`vdp_int_w`, the machine configuration) and `zephyr80_map.h` (`io::VDP_*`); the
chip is `mame/src/devices/video/v9938.cpp`. Source of truth for the card:
`IO_DECODER.pld` and the LunchCrema schematic; for what the guests do with it,
the KonaOS driver (`drivers/v9958/`, `user/sdk/gfx/`) and the ZSDOS console
(`drivers/console/v9958.asm`).

## What is stock and what is the machine's

| Item | Source |
|---|---|
| Registers, ports, status registers, palette, the mode decoders, the sprite engine, the command engine and its timing | stock `v9958_device` |
| Clock | the card's 21.477272 MHz crystal (`XTAL`) |
| Screen | `set_screen_ntsc("screen")`: 262 lines, 59.92 Hz |
| VRAM | `set_vram_size(0x20000)`: 128 KiB, A16 reachable through R#14 |
| Ports | the card's `~CS_VDP` window A0h–BFh: A1:A0 select data (+0), control and status (+1), palette (+2), indirect register (+3); the ports repeat every 4. Reads always select the chip; a write with A2 set is the interrupt latch, not the chip |
| `/INT` | outside the daisy chain; the latch routes it to `/INT` or `/NMI` (see [build-and-run](build-and-run.md#clocks-and-interrupts)) |

The card's WAIT generator is not modelled (the latch's D1 is stored and has no
effect), and the chip's own `/WAIT` (R#25 WTE) has no counterpart in the stock
device: the CPU is never held by a VRAM or port access. The guests program WTE
and do not depend on the hold for correctness; their timing on the board
includes it.

## Behaviour the guests meet (stock, observed)

- **VRAM address counter.** The 14-bit counter carries into R#14 only when R#0
  has M4 or M5 set (GRAPHIC4–7); in the 16 KiB-compatible modes (TEXT, GRAPHIC1–3)
  it wraps inside its bank. Past the last byte (R#14 = 7, counter wrapped) the
  address wraps to 0.
- **GRAPHIC6/7 layout.** Logical byte L (the address the CPU names) is stored at
  `((L & 1) << 16) | (L >> 1)`; the sprite tables are read through the same
  mapping.
- **Palette.** R#16 is the entry pointer and increments after each pair (red and
  blue first, green second); the upper bits are ignored; the pointer wraps from 15
  to 0. The 3-bit components are shown as `pal3bit`. The chip starts with the
  MSX2 default palette and the guests program their own.
- **GRAPHIC7.** The 256-colour palette is fixed (GRB 3-3-2, blue levels 0, 2, 4, 7)
  and sprites use a fixed sixteen-colour table, not the palette registers.
- **Status.** S#0 bit 7 (F) is set once per frame and cleared by a read; S#1
  returns the V9958 ID (bits 5:1 = 00010); S#2 carries CE (bit 0) while a command
  runs.
- **Command engine.** The timing comes from per-command tables in units of a tenth
  of a VDP clock per byte or dot, by display and sprite state (for example HMMV
  53.1 clocks per byte with the display on and sprites off, HMMM 85.4, LMMV 105.6,
  LMMM 117.2, LINE 116.1 per step); the engine is given 13,662 units each
  scanline (63.7 µs) and a command started on an idle engine uses what is left
  of the current line's budget at once. Commands shorter than a line therefore
  finish earlier than their table time (a 6×8 HMMM in GRAPHIC6 with sprites off
  takes 26 µs against 95 µs from the table); long commands run at the table's
  rate, within the 2–3 % of each line the whole-byte steps leave unused.

## Rendering and observation

`screen:pixels()` is a 544×466 RGB bitmap: the active area starts at column 16 and
is 512 hi-res pixels wide (a 256-pixel mode doubles each pixel), each display line
is two rows, the first at row 22 for 212 lines and 42 for 192. Colour 0 and the
backdrop are drawn with alpha 0 (compare colours, not alpha).

The test harness (`harness.vdp`, see [the test README](../tests/README.md)) reads
the chip's VRAM through its address space and its registers, palette and status
registers from the saved state, never through a port, so observing changes no flag,
pointer or latch the guest can see. It decodes GRAPHIC4, 6 and 7 pixels, the
display geometry, the sprite attribute table (sprite mode 2), and compares the
rendered bitmap with what VRAM and the palette say for every pixel outside the
sprites.

## Timing against the board

The recorded board figures and the emulator's, for the same programs at the same
build settings (CPU 10 MHz, V9958 21.477272 MHz, GRAPHIC6 512×212 with the
interlace bit set for the console and clear for the graphics programs, 59.92 Hz,
unthrottled emulated time, IO controller paced; fast changes only the card
steps):

| Workload | Unit | Board | Emulator, paced | Emulator, fast IOC |
|---|---|---|---|---|
| `sntview` row step (about 60 4×6 text calls, P-scroll) | ms, exit line | 22–26 | 27 mean / 42 max | 27 mean / 39 max |
| `sntview` order load and decode | ms, exit line | 48–153 | 44 mean / 88 max | 44 mean / 88 max |
| console `putchar` | T-states per character | 3,479 | 2,490 | 2,495 |
| console `printf` | T-states per character | 3,761 | 3,196 | 3,200 |
| console `write` (256-byte calls) | T-states per character | 3,071 | 2,504 | 2,498 |

The board's `sntview` figures are the owner's, from the program's exit line playing
the tracker song (the range covers the measured runs; mean and maximum are not
separated). The board's console figures are the KonaOS `iobench` rows
`con.putchar`, `con.printf` and `con.write` recorded after the console's render
transactions; the programs have changed since, so they are a reference, not a
same-build pair. The emulator's `iobench` also reports the VDP and direct-write rows
(`vdp.hmmm6` 2,606 T-states a 6×8 copy, `vdp.hmmm12` 3,876, `vdp.direct.on` 1,122 a
glyph), the call chain alone (`con.held` 148 per character) and the card rows
(`file.byte`, `file.getc`, `file.block`), which move with the IO controller setting
while the console and VDP rows do not.

What the figures say: the viewer's row step, which is dominated by large commands, runs
at the board's rate; the console, which is one short command per character, runs
15–28 % faster than the board's recorded cost. The command engine's early
completion of short commands (above) accounts for the direction; the board's WAIT
states (not modelled) and the build difference are the other candidates, and the
recorded board figures cannot separate them. The sntview order step is not card-bound
in the emulator (the paced and fast runs agree), so the board's longer maximum is not
reproduced by the model; it belongs to the card's own latency.

- The command timing is the stock device's; the board's chip is the authority.
- The CPU is not held by VRAM and port accesses (the chip's `/WAIT` and the card's
  generator are not modelled), so CPU-side loops that touch the chip run at the
  instruction rate.
- Interrupt latency from the chip's `/INT` is the machine's (the latch and the
  CPU's acknowledge), not the card's propagation delays.

## Not modelled

- The analogue output: the composite/RGB levels, the card's output stage, the
  display's overscan and the NTSC colour artefacts. The bitmap is the digital
  frame.
- The chip's mouse and light-pen inputs, and the digitiser and external-video
  paths.
- The card's WAIT generator and the chip's `/WAIT` (above).
