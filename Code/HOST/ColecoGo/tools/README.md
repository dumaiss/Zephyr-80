# Tools

- `ihx_to_com.py` converts the linked Intel HEX image at origin `0100h` into a
  CP/M `.COM` file and validates Intel HEX checksums.
- `check_build.py` checks the code/TPA boundary and the size and placement of
  both takeover stages from the assembler listing.

Both tools run as part of `make`.
