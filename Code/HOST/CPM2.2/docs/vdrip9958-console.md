# Virtual Drip V9958 Console

The `vdrip` BIOS console is permanently a V9958 GRAPHIC 6 console. There is no
TMS9928 console mode or BIOS-side screen mirror.

## Display configuration

The BIOS writes:

| Register | Value | Purpose |
|---|---:|---|
| R#0 | `0Ah` | M5+M3: GRAPHIC 6 |
| R#1 | `40h` | Display enabled; 8x8 sprites |
| R#2 | `00h` | G6 bitmap page at `00000h` |
| R#5 | `E4h` | Sprite attribute table low address |
| R#6 | `3Fh` | Sprite pattern base at `1F800h` |
| R#7 | `04h` | Blue border/background |
| R#9 | `88h` | 212 source lines and interlace, producing 424 output lines |
| R#11 | `03h` | Sprite attribute table high address |
| R#23 | `08h` | Terminal source-line offset |

G6 uses a 256-byte pitch for 512 packed four-bit pixels. The 80x24 terminal
occupies 480x192 source pixels, beginning at source line 8.

## V9958 VRAM map

| Range | Use |
|---|---|
| `00000h-D3FFh` | 512x212 G6 bitmap |
| `0D400h-0EA7Fh` | 1,920 logical cells, three bytes each |
| `10000h-13FFFh` | 256-glyph, 32-column G6 mask atlas |
| `1F000h-1F1FFh` | Mode-2 sprite color table |
| `1F200h-1F207h` | Cursor SAT entry and terminator |
| `1F800h-1F807h` | Cursor sprite pattern |

A logical cell is `[CP850 character, foreground, background|reverse-bit]`.
These V9958 VRAM cells are the authoritative terminal state.

## Font and output

`src/font_cp850_6x8.inc` contains 256 glyphs of eight bytes. Bits 7..2 are
converted during initialization into a packed G6 zero/F mask atlas. Printable
output is buffered in 64-byte BIOS runs and sent with `OP_TEXT_RUN`.

Clear, erase, insert/delete line, and scroll operations use the existing
cell-aware command-stream opcodes. Each operation updates both logical cells
and visible bitmap semantics in the V9958 backend.

## Cursor

The BIOS owns cursor position and visibility. The cursor is a steady,
non-blinking 6x8 block implemented with one mode-2 sprite. Moving or hiding it
updates only sprite VRAM; logical cells and bitmap pixels are unchanged.

## Presentation and transport

`OP_PRESENT` requests presentation without clearing retained accelerator
configuration. `PACKET_RESET` remains the explicit full reset. The shared
PROXY_READY, storage, terminal-input, SIO receive pump, and RTS/CTS paths are
unchanged.

## Baseline size change

The prior `vdrip` image occupied `E000h-F458h` (5,209 bytes) and contained a
1,920-byte BIOS screen mirror. The first V9958 replacement build ends at
`EC27h` (3,112 bytes), reclaiming 2,097 resident bytes while adding a
64-byte printable-run buffer and V9958 command/cursor state.

## Hardware validation still required

Cold/warm boot, long scrolling output, erase operations, cursor movement,
WordStar, ZDE16, Turbo Pascal 3, Turbo Modula-2, MBASIC, and PIP file copies
must be exercised on Zephyr-80 hardware with RTS/CTS observed.
