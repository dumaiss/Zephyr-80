# Source

`colecogo.asm` is the complete first-pass CP/M loader. It uses SDCC's
ASxxxx-compatible `sdasz80` syntax and builds as a CP/M transient program at
`0100h`.

The source keeps the three execution contexts visibly separate:

- the CP/M loader validates and reads both files into the current TPA
- the relocatable Stage A template runs from common RAM at `C000h`
- the Stage B template runs from bank 7 at `5F80h`

After reading `COLECO.ROM`, the CP/M phase verifies and adapts the 15 VDP-port
operands in the standard Coleco BIOS. This converts the Coleco `BEh/BFh`
aliases to LunchCrema's native `A0h/A1h` data/command ports. An unrecognized
BIOS is rejected before takeover, and the BIOS file on disk is never changed.

Stage A also replaces the CP/M console's inherited V9958 state with a known
TMS-compatible baseline. This is required before the BIOS performs its initial
VRAM clear: the CP/M G6 console normally leaves `R#14` on VRAM page 7, while
the original BIOS can address only page 0 and cannot reset V9958-only
registers.

Stage B is deliberately placed over the final 128-byte record of the temporary
upper-cartridge staging area. The loader first backs that record up at `7F80h`;
Stage B copies the preceding bytes, restores the saved record to `FF80h`, clears
Coleco RAM, and jumps to the BIOS at `0000h`.
