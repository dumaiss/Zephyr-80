# Initial CBIOS ABI Notes

This project starts with a CP/M 2.2-style CBIOS jump table and minimal stubs.

## ROM-to-RAM Startup

- `shadow_copy_rom_to_ram`: early Zephyr-80 ROM startup routine. It uses no
  stack, copies ROM pages into RAM using the high-safe shadow/copy mode,
  disables ROM, and jumps to `cbios_boot_after_rom_copy`.
- `shadow_copy_rom_to_ram_done`: label immediately after the final ROM-disable
  output.
- `cbios_boot_after_rom_copy`: post-copy high-common entry. It initializes the
  stack at `CBIOS_STACK_TOP` and jumps to `BOOT`.
- `BOOT`: temporary cold boot placeholder. It disables interrupts, initializes
  SIO channel B, sets the default DMA address to `0080h`, installs provisional
  page-zero vectors for `WBOOT` and `BDOS_STUB`, prints a skeleton banner, and
  enters a small `CBIOS>` echo loop.
- `WBOOT`: temporary warm boot placeholder. It prints `WBOOT` and returns to the
  placeholder loop.
- `BDOS_STUB`: placeholder only. Real BDOS is not present yet.

The CP/M BIOS jump table is high-resident at `CBIOS_BASE`, not at `0000h`.
Page zero belongs to the selected low RAM bank once ROM is disabled.

## Console

- `sio_init`: initializes Zephyr-80 SIO channel B for 115200 8N1 polling I/O
  with SIO interrupts disabled. The implementation selects RR0 before polling
  SIO status.
- `bios_putc_a`: local helper, not a CP/M jump-table entry. Input `A` is the
  character to send.
- `bios_puts`: local helper, not a CP/M jump-table entry. Input `HL` points to
  a NUL-terminated string.
- `CONST`: returns `A = 00h` when no console character is available, `A = FFh`
  when a character is available. It does not consume the character.
- `CONIN`: blocks until a console character is available, returns it in `A`,
  and does not echo.
- `CONOUT`: sends the character in `C` after waiting for Tx Buffer Empty.

## Auxiliary Character Streams

- `LIST`: currently aliases `CONOUT`; it may later become a printer or log
  output path.
- `PUNCH`: currently aliases `CONOUT`. This is a good future candidate for an
  Intel HEX or other machine-readable output stream, inspired by paper tape
  punch usage.
- `READER`: currently aliases `CONIN`. This is a good future candidate for an
  Intel HEX or other machine-readable input stream, inspired by paper tape
  reader usage.
- `LISTST`: currently returns `A = FFh` because `LIST` aliases console output.

The monitor's HEX loader/exporter may eventually be layered above these
character-stream primitives.

## Disk Stubs

- `SETDMA`: stores the DMA address for future disk I/O.
- `READ`: currently returns `BIOS_ERR`.
- `WRITE`: currently returns `BIOS_ERR`.
- `SELDSK`: currently returns `HL = 0000h`, meaning disk select failure.
- `SECTRAN`: currently returns identity translation with `HL = BC`.
