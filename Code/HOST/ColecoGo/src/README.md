# Source

`colecogo.asm` is the complete first-pass CP/M loader. It uses SDCC's
ASxxxx-compatible `sdasz80` syntax and builds as a CP/M transient program at
`0100h`.

| File | Role |
| --- | --- |
| `colecogo.asm` | the loader and both takeover stages |
| `cartscan.inc` | the cartridge I/O trace; no I/O and no CP/M dependency |
| `cartpatch.inc` | the `PAT` manifest reader, CRC and scan report |
| `scantest.asm` | a standalone harness for the two includes; test-only |

`scantest.asm` is not part of `COLECOGO.COM`. It assembles the same two
includes against the same buffer addresses but needs none of the Zephyr BDOS
extensions, so `make test` can run it under an ordinary CP/M emulator and
compare its results with `tools/scan_cartridge.py`.

The source keeps the three execution contexts visibly separate:

- the CP/M loader validates and reads both files into the current TPA
- the relocatable Stage A template runs from the program's common reservation at `E000h`
- the Stage B template runs from takeover bank 6 at `5F80h`

After reading `COLECO.ROM`, the CP/M phase verifies and adapts the 15 VDP-port
operands in the standard Coleco BIOS. This converts the Coleco `BEh/BFh`
aliases to LunchCrema's native `A0h/A1h` data/command ports. An unrecognized
BIOS is rejected before takeover, and the BIOS file on disk is never changed.

The cartridge is then adapted the same way, but its operands have to be found
rather than looked up. `cartscan.inc` traces reachable code from the cartridge
header's entry vectors and rewrites only the operands it can prove belong to
executed I/O instructions, so data tables that happen to contain a `D3h` or
`DBh` byte are left alone. `cartpatch.inc` then applies the optional `GAME.PAT`
manifest for the sites the trace cannot reach. Neither file on disk is
changed, and every error still returns to CP/M with bank 6 intact.

The scan uses three fixed scratch areas above the cartridge buffer, all well
below the Stage A window at `E000h`:

```text
BC00h-CBFFh   visited bitmap, one bit per cartridge byte
CC00h-D3FFh   trace worklist, 1024 pending addresses
D400h-DC7Fh   one PAT manifest
```

Stage A also replaces the CP/M console's inherited V9958 state with a known
TMS-compatible baseline. This is required before the BIOS performs its initial
VRAM clear: the CP/M G6 console normally leaves `R#14` on VRAM page 7, while
the original BIOS can address only page 0 and cannot reset V9958-only
registers.

Stage B is deliberately placed over the final 128-byte record of the temporary
upper-cartridge staging area. The loader first backs that record up at `7F80h`;
Stage B copies the preceding bytes, restores the saved record to `FF80h`, clears
Coleco RAM, and jumps to the BIOS at `0000h`.
