# Tools

- `ihx_to_com.py` converts the linked Intel HEX image at origin `0100h` into a
  CP/M `.COM` file and validates Intel HEX checksums.
- `check_build.py` checks the code/TPA boundary and the size and placement of
  both takeover stages from the assembler listing.
- `scan_cartridge.py` is the reference model for the loader's in-memory
  cartridge I/O scan, and builds the `.PAT` manifests the loader reads. The Z80
  implementation in `src/cartscan.inc` must agree with it exactly.
- `make_io_test_rom.py` generates a synthetic cartridge, and its manifest, that
  exercises every decision the scanner makes. Real ROMs do not: Donkey Kong has
  no direct I/O and Zaxxon reaches the hardware only through `OUT (C)`.
- `test_cartscan.py` runs `build/SCANTEST.COM` under a CP/M emulator and
  compares its trace bitmap and adapted image, byte for byte, with the model.
  It skips itself when no emulator is installed.
- `patch_cartridge.py` verifies and applies title-specific, size-preserving ROM
  patches on the development PC. It always writes a separate output file and
  requires both a whole-ROM SHA-256 match and expected bytes at every patch
  site.

The build tools run as part of `make`; `make test` runs the scanner
comparison. The cartridge patcher is invoked manually.

## Cartridge scan and PAT manifests

Report what the loader's trace will do to an image, without changing it:

```sh
python3 tools/scan_cartridge.py scan GAME.ROM
```

A non-zero indirect count means the title drives the hardware through
`OUT (C)` or `IN r,(C)`, which no operand rewrite can reach. Correct a copy of
the ROM by hand and turn the differences into a manifest:

```sh
python3 tools/scan_cartridge.py pat GAME.ROM GAME.FIX GAME.PAT
```

`pat` records only what the automatic scan does not already do, and binds the
manifest to the image by record-rounded length and CRC-16. Copy `GAME.PAT`
beside `GAME.ROM` on the CP/M drive; the loader finds it by name.

## Development-PC ROM patching

`patch_cartridge.py` is unrelated to the loader's `PAT` manifests: it writes a
separately patched ROM file on the PC. Print a cartridge's identity with:

```sh
python3 tools/patch_cartridge.py info GAME.ROM
```

A patch manifest uses mapped cartridge addresses or zero-based file offsets:

```json
{
  "format": "colecogo-patch-v1",
  "title": "Example timing patch",
  "load_address": "0x8000",
  "rom": {
    "size": 32768,
    "sha256": "64 lowercase hexadecimal characters"
  },
  "patches": [
    {
      "name": "replace one guarded instruction sequence",
      "address": "0x9123",
      "expect": "06 40 10 FE",
      "replace": "01 00 01 00"
    }
  ]
}
```

`address` is converted to a file offset using `load_address`; `offset` can be
used instead. `expect` and `replace` must contain the same non-zero number of
bytes. Patches may not overlap or extend beyond the ROM.

Verify every guard without writing a file, then apply it:

```sh
python3 tools/patch_cartridge.py verify GAME.ROM game-patch.json
python3 tools/patch_cartridge.py apply GAME.ROM game-patch.json GAME-PATCHED.ROM
```

The patcher refuses to overwrite either the source or an existing output. A
manifest must target one exact ROM revision; do not weaken the hash or
expected-byte guards to make a patch fit another dump.
