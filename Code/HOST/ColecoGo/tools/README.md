# Tools

- `ihx_to_com.py` converts the linked Intel HEX image at origin `0100h` into a
  CP/M `.COM` file and validates Intel HEX checksums.
- `check_build.py` checks the code/TPA boundary and the size and placement of
  both takeover stages from the assembler listing.
- `patch_cartridge.py` verifies and applies title-specific, size-preserving ROM
  patches on the development PC. It always writes a separate output file and
  requires both a whole-ROM SHA-256 match and expected bytes at every patch
  site.

The build tools run as part of `make`. The cartridge patcher is invoked
manually. Print a cartridge's identity with:

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
