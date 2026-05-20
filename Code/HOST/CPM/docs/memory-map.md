# Provisional Memory Map

This is a planning document for the Zephyr-80 CP/M port scaffold. The final
layout will change once CCP, BDOS, CBIOS, storage, and monitor handoff are
integrated.

## CP/M-Oriented Layout

- `0000h-00FFh`: CP/M page zero in selected low RAM bank 0. BOOT currently
  installs `JP WBOOT` at `0000h` and `JP BDOS_STUB` at `0005h`.
- `0100h-DFFFh`: future TPA, CCP, and BDOS low-bank area.
- `E000h-FFFFh`: provisional high common CBIOS, stack, and bank-helper area.

## Boot-Copy Stage

The ROM scaffold starts with a minimal reset vector at `0000h`:

```asm
jp cpm_rom_entry_high
```

The real boot-copy routine is assembled in `E000h-FFFFh`. It first copies the
high safe/common window, `E000h-FFFFh`, from ROM page 0 into SRAM bank 0 while
normal mode still reads ROM and writes SRAM underneath. It then enables
shadow/copy mode, where `E000h-FFFFh` is safe SRAM bank 0 and `0000h-DFFFh`
reads the selected ROM page while writing the selected SRAM bank.

Each ROM/RAM page copy covers `0000h-DFFFh`, so only 56 KiB per page is copied.
The top 8 KiB of RAM banks 1-7 is sacrificed/inaccessible under this common-area
model. After page 7 is copied, the routine writes `10h` to the banking latch to
disable ROM and select RAM bank 0, then jumps to the temporary CBIOS post-copy
BOOT path.

After ROM is disabled, `cbios_boot_after_rom_copy` initializes the stack in high
common RAM and enters `BOOT`. The current BOOT path initializes SIO channel B,
sets the default DMA address to `0080h`, initializes the page-zero vectors,
prints a scaffold banner, and enters a tiny echo loop.

## Zephyr-80 Memory Decoder Model

Normal ROM mode:

- `0000h-5FFFh`: reads ROM, writes SRAM
- `6000h-DFFFh`: reads/writes SRAM
- `E000h-FFFFh`: reads ROM, writes SRAM

Shadow/copy mode:

- `0000h-DFFFh`: reads selected ROM page, writes selected SRAM bank
- `E000h-FFFFh`: reads/writes SRAM bank 0 safe execution area

RAM-only mode:

- `0000h-DFFFh`: reads/writes selected SRAM bank
- `E000h-FFFFh`: reads/writes fixed/common SRAM bank 0

This is CP/M-friendly because page zero and the TPA can live in the selected low
bank while the CBIOS, stack, and future bank helpers stay in high common RAM.

## Zephyr-80 Notes

- Current monitor-based experiments often load standalone code at `8000h`.
- The monitor is moving toward copying ROM to RAM and running with ROM disabled.
- No storage is implemented yet.
- Disk layout, drive geometry, allocation vectors, and I/O controller protocol
  are intentionally undefined in this scaffold.
