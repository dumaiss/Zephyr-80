# Direct V9958 Console Implementation Plan and Status

## Current status

The direct `v9958` console backend, build-time selector, HID-only input path,
VT100-compatible output path, generated memory reporting, and retained `vdrip`
compatibility build have been implemented. Static verification passes for all
supported console/storage combinations.

The original direct-driver scrolling implementation was subsequently revised.
An interim page-copy approach still moved roughly 51 KiB for every scroll and
did not provide the expected performance on the physical card. The current
implementation instead uses R#23 as a circular vertical origin, commits the
origin during vertical retrace, and clears only the newly exposed bottom row
and the four-line display margin. The original hardware-proven font-atlas and
sprite layout was restored, and palette entries are now selected explicitly so
palette entry 15 is deterministically programmed as white.

First hardware bring-up of that revision produced two defects, both addressed
in the revision described under "Hardware bring-up findings" below: white text
displayed as yellow, and scrolling output was slower than the VDrip console.

Remaining work is hardware validation of the current circular-scroll and
palette fixes. This document distinguishes those pending hardware checks from
the completed implementation and static build verification below.

## Goal

The project now has a `v9958` CP/M console backend for the physical LunchCrema
V9958 card. The new backend is the normal build choice, preserves the
existing ANSI/VT100-light terminal behavior, and uses the IO Controller HID
queue as its only keyboard source. The existing `vdrip` console remains in the
tree as an independently selectable compatibility backend.

This pass does not change the CP/M BIOS jump table, disk geometry, drive
mapping, IOC protocol, HID byte semantics, or the Virtual Drip wire protocol.

## Build-time selection

The Makefile selector supports these values:

```text
CONSOLE=v9958    direct LunchCrema V9958 output plus IOC HID input (default)
CONSOLE=vdrip    retained Virtual Drip console, including proxy keyboard input
```

The generated aggregate assembly source includes exactly one console backend.
`vdrip_transport.asm` is linked only for the retained `vdrip`
console. Consequently, the normal `CONSOLE=v9958 STORAGE_A=rom` image (ROM
drive A plus the existing SD-card drive B) contains no Virtual Drip
console, keyboard, readiness, packet-output, or shared-transport code.
`STORAGE_A=vdrip` remains a legacy compatibility choice only with
`CONSOLE=vdrip`; the direct console does not retain a VDrip dependency just to
support a superseded storage path.

Both console modules implement neutral backend symbols consumed by the
existing console facade and boot path. Their backend-specific public symbols
remain available for maps and diagnostics. This keeps the CP/M-visible
`CONST`, `CONIN`, `CONOUT`, `LIST`, `PUNCH`, `READER`, and `LISTST` entries and
their order unchanged.

## Direct V9958 hardware initialization

The implementation follows `docs/lunchcrema-v9958-console-bringup.md`. The
console owns a software shadow of the LunchCrema configuration
latch so D0, the interrupt-route bit, is preserved whenever D1 (`/WS_EN`) is
changed.

Cold and warm initialization explicitly establish every VDP value used by the
console; they do not assume that CP/M warm boot reset VDP registers or the
LunchCrema latch. The sequence is:

1. Disable the U11 front porch by setting configuration-latch D1 while
   preserving D0.
2. Use explicitly software-paced command-port writes to set R#25 to `00h`
   (`WTE=0`, `VDS=0`).
3. Use paced writes to set R#8 to `08h` (`VR=1` for the installed 64Kx4
   DRAMs). R#8 must never be left at the reset value used by the virtual VDP.
4. Program the remaining G6 registers and palette with paced accesses. The
   real-card value for R#2 is `1Fh`, not the virtual backend's `00h`.
5. Set R#25 to `04h` with a paced write (`WTE=1`, `VDS=0`).
6. Enable the U11 front porch by clearing configuration-latch D1 while
   preserving D0.
7. Only then begin normal direct VRAM and command-engine traffic.

The palette is loaded after step 6, with native WAIT and the porch enabled, so
palette bytes are written in the same regime as normal VRAM traffic rather than
under software pacing alone.

The display remains disabled while the font atlas, screen, and cursor are
initialized, then R#1 is set to its final display-enabled value. Direct port
helpers use the LunchCrema mapping:

| Port | Use |
|---:|---|
| `A0h` | VRAM data |
| `A1h` | VDP command/status |
| `A2h` | palette data |
| `A3h` | indirect register data |
| `A4h` | LunchCrema configuration latch |

Normal transfers rely on both native V9958 WAIT (`R#25.WTE=1`) and the enabled
U11 porch (`/WS_EN=0`). Command-engine operations poll status register 2's
CE bit before reusing command registers or touching command-owned VRAM.

## Display model and VT100 behavior

The new driver retains the current console's output parser and its
CP/M-style separation of concerns:

```text
CONOUT byte -> ANSI/VT100-light parser -> direct V9958 rendering
IOC HID bytes -> HID queue -> CONST/CONIN
```

Keyboard bytes never enter the output parser. No keyboard handler can
draw, move the cursor, or scroll the screen.

The physical V9958 uses the established GRAPHIC 6 layout: 85 columns by 26
rows, six by eight pixels per cell, with a 512x212 source bitmap displayed as
an interlaced 512x424 image. The existing CP850 font remains embedded at the
same ROM/TPA location and is uploaded to V9958 VRAM during console
initialization.

To avoid retaining a large BIOS RAM shadow, the new backend uses two
precolored V9958 font atlases: normal white-on-blue and reverse blue-on-white.
Printable runs issue V9958 high-speed VRAM-to-VRAM copies from the
appropriate 32-column atlas into the circular page-zero bitmap. Erase and clear
operations use solid-fill commands. The sprite cursor remains a BIOS-owned
steady 6x8 block and is updated through direct VRAM writes.

Palette initialization explicitly selects R#16 before writing each RB/G
pair, matching the hardware-validated `MANDELV5` sequence, and now also runs in
the same WAIT-enabled access regime that sequence uses. In particular, palette
entry 15 is always programmed as `77h,07h` (white) rather than relying on
retained palette-pointer or auto-increment state.

## Hardware bring-up findings

Two defects appeared on the physical card and were fixed by the current
revision.

### White text displayed as yellow

Palette entry 15 is programmed `77h,07h`, which is R=7, B=7, G=7. The observed
text was pure yellow, that is R=7, G=7, B=0, so the low three bits of the
entry's RB byte were not taking effect on the card. The Z80-side code emits the
correct bytes: `v9958_init_palette_paced` selects each entry through R#16 and
writes RB then G to port `A2h`, which is the same sequence the
hardware-validated `MANDELV5.COM` uses.

The one structural difference from `MANDELV5.COM` was *when* the palette was
programmed. `MANDELV5.COM` never touches the LunchCrema configuration latch, so
its palette writes run with the U11 front porch enabled and with `R#25.WTE=1`;
every palette byte it writes is held by a real hardware WAIT. The console
driver instead programmed the palette inside the bootstrap regime, with the
porch bypassed and `WTE=0`, relying only on software pacing. Software pacing
fixes the interval *between* accesses; it does not widen the `/CSW` pulse or
extend the data-valid window of the access itself, so a palette byte can be
latched with individual bits wrong. Losing only the low RB bits is the
signature of that kind of marginal write rather than of a dropped write, which
would leave a whole entry, or every following entry, wrong.

The palette is therefore now loaded after `v9958_enable_hardware_wait`, in the
same regime as the font-atlas upload and all other normal traffic, and after
the porch is re-enabled. The bring-up document's step ordering lists the
palette in the porch-off phase; that step is now understood to cover display
registers only, and the palette belongs with normal traffic.

If yellow text survives this change, the cause is not the access regime, and
the next checks are, in order: whether the screen background is still blue
(palette entry 4, `05h,00h`) or has become black, which would show that every
entry lost its blue component rather than entry 15 alone; and a temporary
change of the foreground index in `v9958_pair_color_table` from `Fh` to a
distinctive index such as `3h`, which separates "palette entry 15 is wrong"
from "the glyph pixels are not index 15".

### Scrolling slower than the VDrip console

`v9958_scroll_up_one` waited for `S#2.VR` before committing the new R#23
origin, so the origin changed only during vertical retrace. That wait costs up
to one full field, 16.7 ms on NTSC timing and 20 ms on PAL, roughly 8 ms on
average, and it ran on every scrolled line. It capped scrolling output at the
field rate no matter how fast the rest of the driver was, which is why the
direct driver felt slower than the VDrip console even though the VDrip console
does far more work per line.

For comparison, the work the wait was protecting is two HMMV fills totalling
twelve scanlines, about 0.3 ms of command-engine time, so the retrace wait was
more than twenty times the cost of the operation it made tear-free.

The retrace wait was removed. R#23 is now committed as soon as the fills
complete. The fills are still allowed to finish first, because the newly
exposed bottom row would otherwise briefly show stale circular-buffer content.
Writing R#23 mid-field can tear a single field; during continuous output that
is not visible.

There is no double buffering in this design to be ineffective: the circular
R#23 origin replaced the earlier page-copy scheme precisely so that scrolling
moves no bitmap data. The V9958 command engine is in use for both glyph
rendering (HMMM from the precolored atlas) and erasing (HMMV).

If scrolling is still not fast enough after this change, the next cost is the
per-glyph command setup rather than the scroll itself. `v9958_start_command`
writes all fifteen command registers R#32..R#46 for every character. Within one
printable run only SX and DX change; SY, DY, NX, NY, colour, argument and the
command code are constant. Writing R#32..R#37 through R#17 auto-increment and
then re-pointing R#17 at R#46 for the start byte would cut the per-character
port traffic from seventeen writes to eleven.

## Native circular scrolling

Full-screen scrolling uses the V9958's R#23 vertical-scroll facility rather
than copying a 512x200-pixel bitmap. VRAM is assigned as follows:

| Range | Use |
|---|---|
| `00000h-0FFFFh` | 256-line circular G6 text surface |
| `10000h-13FFFh` | 32-column normal-color glyph atlas |
| `14000h-17FFFh` | 32-column reverse-color glyph atlas |
| `1F000h-1F1FFh` | mode-2 sprite color table |
| `1F200h-1F27Fh` | cursor SAT allocation |
| `1F800h-1FFFFh` | sprite-pattern allocation; cursor uses its first pattern |

The retained logical origin identifies the physical scanline containing text
row zero and is always a multiple of eight. R#23 is programmed to four lines
before that origin, preserving the existing four-line top margin. A scroll
advances the origin by eight modulo 256, clears the newly exposed eight-line
bottom row and four-line top margin, and writes the new R#23 value as soon as
those fills complete. The normal scroll path therefore changes only 12 scanlines and
one display register; it performs no full-screen HMMM or YMMM.

Glyph rendering and erase coordinates are translated through the circular
origin. Multi-row fills split at scanline 255 so they cannot enter the atlas
page. Insert/delete-line copies process one logical cell row at a
time in overlap-safe order, which preserves behavior when the circular surface
wraps. Cursor SAT coordinates include the physical origin so R#23 scrolling
does not displace the visible cursor.

The current parser behavior is preserved, including printable CP850
bytes, CR/LF, backspace, tab, form feed, cursor movement, CUP/CHA/VPA,
ED/EL/ECH, SGR reverse video, save/restore cursor, DECAWM, cursor visibility,
insert/delete lines, and safe consumption of unsupported sequences. The CCP
up-arrow recall helper remains present.

## HID-only input for the direct driver

`v9958` initialization initializes the existing IOC HID mailbox/queue but does
not register an SIO0/B receive sink, wait for `PROXY_READY`, send a proxy reset,
or manage proxy RTS. `CONST` flushes any pending display run and then calls the
existing rate-limited `hid_input_status`. `CONIN` blocks on that
same HID queue and returns exactly one terminal byte through `hid_input_get`.

The retained `vdrip` backend keeps its current proxy and HID merge behavior so
selecting it does not silently change its compatibility semantics.

## Completed source and layout changes

The implementation made focused changes to:

- `src/cbios_console_v9958.asm`: added the direct-hardware backend, derived from the
  existing parser and console behavior without proxy framing or proxy input.
- `src/cbios_console_vdrip.asm`: added only the neutral backend aliases required
  by build-time selection and retained its existing behavior.
- `src/cbios_console.asm` and `src/cbios_boot.asm`: changed calls to use the neutral selected
  backend symbols instead of hard-coding VDrip entry points.
- `src/platform_zephyr80.inc` and `src/cbios_defs.inc`: defined and documented the
  direct V9958 ports, configuration bits, selected-console placement, and
  neutral font placement while preserving existing compatibility constants.
- `src/zephyr.asm` and `Makefile`: now include exactly the requested console and
  conditionally include the VDrip transport.
- `tools/generate_memory_docs.py`: recognizes the selected console and reports
  its actual slot ownership without weakening overlap checks.
- `README.md`: documents the console selector and normal direct-hardware build.

The driver starts at slot 0 (`E000h`) and ends at the exclusive address
`ECACh`, leaving 84 bytes before the existing IOC Bulk block at `ED00h`. It
does not overlap the IOC bulk/SD code, HID code/state, selected drive-A
backend, scratch buffers, runtime state, or stack. No existing driver was
moved to another slot.

## Completed static verification

The complete build matrix was assembled, linked, checked for emitted-byte
overlap, packaged, and passed through the normal memory-document generator:

```text
make CONSOLE=v9958 STORAGE_A=rom
make CONSOLE=vdrip STORAGE_A=rom
make CONSOLE=vdrip STORAGE_A=vdrip
```

The resulting assembler/linker output, overlap checker, symbol map, layout
manifest, and generated memory documentation confirm:

- no unresolved or duplicate symbols;
- no emitted-byte or declared-range overlaps;
- the BIOS jump table and all existing CP/M-visible entry addresses remain
  intact;
- the BIOS still begins at `DA00h`, the SIO IM2 vector remains at `DD10h`, and
  scratch/runtime/stack regions retain their boundaries;
- the direct build contains the `v9958` driver and omits VDrip transport
  symbols;
- the compatibility build contains the retained `vdrip` driver;
- ROM/SD geometry, mappings, RAM-disk definitions, and HID command protocol are
  unchanged;
- memory documentation was regenerated only through the project generator;
- the direct V9958 image occupies `E000h-ECABh`, with its exclusive end marker
  at `ECACh` and IOC Bulk still beginning at `ED00h`;
- all 32 possible eight-line circular origins map all 26 text rows within
  page-zero boundaries.

## Pending hardware verification

Hardware validation remains required for the current revision: cold boot,
warm boot after a VDP-using transient program, long scrolling output, ED/EL,
insert/delete lines, reverse video, cursor motion/visibility, WordStar, Turbo
Pascal 3, Turbo Modula-2, MBASIC, PIP copies, and USB keyboard control/arrow
sequences. During first hardware boot, verify V9958 native `/WAIT`, U11
`WAIT_SINK`, Z80 `/WAIT`, CPUCLK, `/CSR`, and `/CSW` as described in the
bring-up document.

## Scope boundary

This implementation pass ended after the new driver, selector, conditional
dependency, static build validation, and generated documentation were
complete. It did not proceed into
VDP interrupt handling, new terminal features, protocol changes, storage
changes, font replacement, or unrelated cleanup.
