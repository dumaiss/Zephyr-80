# Zephyr-80 Memory Management

This document describes the memory hardware, banking latch, boot-time ROM copy, and the current CP/M banking model. It is derived from the active WinCUPL equations and the current BIOS source.

For exact addresses inside a particular firmware build, use the generated [CP/M memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md).

## Hardware model

- Z80 logical address space: 64 KiB
- SRAM: 512 KiB, organized as eight 64 KiB banks
- ROM/Flash address capacity: 512 KiB, organized as eight 64 KiB pages
- Banking latch: I/O port `00h`
- Memory decoder: `MEM_DECODER.pld`
- I/O decoder: `IO_DECODER.pld`

The hardware exposes three SRAM-bank bits, three ROM-page bits, and two mode bits. During normal CP/M execution:

| Z80 range | Physical memory |
| --- | --- |
| `0000h-BFFFh` | Selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0, fixed/common |

The 16 KiB common window exists in **shadow/copy mode** and **RAM-only mode**. Normal ROM-visible mode has different rules, described below.

The current firmware builder emits a 128 KiB burnable image. That is the present image size, not the hardware page-addressing limit.

## Banking latch

The latch is decoded throughout `00h-0Fh`; software convention uses port `00h`. Writes update the latch and reads return its current value through the readback buffer.

| Bits | Name | Function |
| --- | --- | --- |
| D0-D2 | `BANK_Q0..2` | SRAM bank number, 0-7 |
| D3 | `RAM_SHADOW` | Enables ROM-to-RAM shadow/copy mode while ROM remains enabled |
| D4 | `ROM_DIS` | Disables ROM and selects RAM-only operation |
| D5-D7 | ROM page | ROM page number, 0-7 |

For ROM page `p`, SRAM bank `b`, and mode bits `m`:

```text
latch = ((p & 7) << 5) | m | (b & 7)
```

The ROM-page bits are not used inside `MEM_DECODER.pld`; they select the ROM address externally. The SRAM-bank bits feed the decoder's `RAM_A16-A18` outputs.

### Mode-bit combinations

| D4:D3 | Value | Mode |
| --- | ---: | --- |
| `00b` | `00h` | Normal ROM-visible mode |
| `01b` | `08h` | Shadow/copy mode |
| `10b` | `10h` | RAM-only mode |
| `11b` | `18h` | RAM-only mode; D3 has no additional effect |

Software uses `10h`, rather than `18h`, as the canonical RAM-only mode value.

Common latch expressions are:

| Operation | Value |
| --- | --- |
| Reset/default page 0, bank 0 | `00h` |
| Show ROM page `p` over SRAM bank `b` | `((p & 7) << 5) | (b & 7)` |
| Copy ROM page `p` into SRAM bank `b` | `((p & 7) << 5) | 08h | (b & 7)` |
| Run from SRAM bank `b` | `10h | (b & 7)` |

## Decoder behavior

All memory writes select SRAM. The mode bits determine which device answers memory reads and whether the upper 16 KiB follows the selected SRAM bank or is forced to bank 0.

The bank-address equations reduce to:

```text
force_bank0 = address >= C000h and (ROM_DIS or RAM_SHADOW)

RAM_A16 = BANK_Q0 and not force_bank0
RAM_A17 = BANK_Q1 and not force_bank0
RAM_A18 = BANK_Q2 and not force_bank0
```

### Normal ROM-visible mode

Condition: `ROM_DIS=0`, `RAM_SHADOW=0`

| Address | Read source | Write target |
| --- | --- | --- |
| `0000h-5FFFh` | Selected ROM page | Selected SRAM bank |
| `6000h-BFFFh` | Selected SRAM bank | Selected SRAM bank |
| `C000h-FFFFh` | Selected ROM page | Selected SRAM bank |

This is the reset and ROM-restore mode. Writes to ROM-visible addresses go to hidden SRAM underneath. Because the common-bank force is inactive in this mode, those hidden writes follow D0-D2; reset value `00h` therefore writes SRAM bank 0.

### Shadow/copy mode

Condition: `ROM_DIS=0`, `RAM_SHADOW=1`

| Address | Read source | Write target |
| --- | --- | --- |
| `0000h-BFFFh` | Selected ROM page | Selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0 | SRAM bank 0 |

Code can execute safely from the common high window while copying the lower 48 KiB of a selected ROM page into a selected SRAM bank.

### RAM-only mode

Condition: `ROM_DIS=1`; `RAM_SHADOW` is ignored

| Address | Read/write target |
| --- | --- |
| `0000h-BFFFh` | Selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0 |

ROM is not selected anywhere. This is the normal CP/M runtime configuration.

## Reset and ROM-to-RAM copy

The current CP/M boot path is implemented in [`boot_shadow_copy.asm`](Code/HOST/CPM2.2/src/boot_shadow_copy.asm). It does not use a stack until RAM is fully established.

1. Reset starts with latch value `00h` and executes the ROM reset vector at `0000h`.
2. The reset vector jumps to `cpm_rom_entry_high` in the high ROM region.
3. In normal mode, the routine copies `C000h-FFFFh` from ROM page 0 into hidden SRAM bank 0.
4. It writes `08h`, entering shadow/copy mode for ROM page 0 and SRAM bank 0.
5. It copies `0000h-BFFFh` from ROM page 0 into SRAM bank 0.
6. For pages/banks 1-7, it writes `(n << 5) | 08h | n` and copies `0000h-BFFFh` into the matching SRAM bank.
7. It writes `10h`, disabling ROM and selecting SRAM bank 0.
8. It establishes the BIOS stack and continues into the cold-boot path.

The upper 16 KiB is copied only once because it is common SRAM bank 0 at runtime. Only the lower 48 KiB of banks 1-7 is normally visible.

Warm boot uses the same read-ROM/write-hidden-RAM property more selectively: it temporarily restores ROM-visible page 0 and recopies the CCP restore range before returning to RAM-only mode.

## CP/M runtime layout

The hardware boundary is `C000h`; the current `MEM=56` software build places CP/M and the BIOS within the common 16 KiB window.

| Range | Current use |
| --- | --- |
| `0000h-00FFh` | Bank-local CP/M page zero and default DMA/command-tail area |
| `0100h-BFFFh` | Banked TPA/program area |
| `C000h-C3FFh` | Application-owned protected/common TPA |
| `C400h-CC05h` | CCP allocation and warm-boot restore range |
| `CC06h-D9FFh` | BDOS and CP/M state |
| `DA00h-DFFFh` | Core BIOS and extended BIOS services |
| `E000h-F3FFh` | Fixed driver slots 0-4 |
| `F400h-F67Fh` | Reserved gap |
| `F680h-FA7Fh` | Fixed driver slot 5 |
| `FA80h-FDFFh` | BIOS scratch and storage buffers |
| `FE00h-FE7Fh` | Persistent BIOS runtime-state window |
| `FE80h-FFFFh` | Firmware work and stack window |

Two ownership rules matter:

- `C000h-C3FFh` is common across bank switches but remains **application-owned**. The BIOS must not claim it for persistent state, vectors, scratch, or drivers.
- Banked programs and data that must differ between banks must remain below `C000h`.

The exact occupied endpoints change as the firmware is rebuilt. Do not copy addresses from this overview into code when a named symbol exists.

## BIOS banking services

The extended BIOS owns the runtime bank-latch policy. Its implementation is in [`cbios_bank.asm`](Code/HOST/CPM2.2/src/cbios_bank.asm).

| Entry | Inputs | Behavior |
| --- | --- | --- |
| `SELMEM` | `A` = bank | Selects RAM-only bank `A & 7` and updates `CURRENT_BANK` |
| `SETBNK` | `A` = bank | Records the bank containing the next disk DMA buffer; does not switch immediately |
| `XMOVE` | `C` = source bank, `B` = destination bank | Arms the next `MOVE` as a cross-bank transfer |
| `MOVE` | `BC` = length, `DE` = source, `HL` = destination | Performs a same-bank `LDIR` or the pending cross-bank copy |

A cross-bank `MOVE` copies through the common `MOVE_BUFFER` at `FA80h` in chunks of at most 192 bytes, restores the caller's original bank, and clears the pending-XMOVE state. It does not use the application-owned `C000h-C3FFh` window as scratch.

Direct application writes to port `00h` can desynchronize the hardware latch from the BIOS `CURRENT_BANK` record. Outside boot code and low-level diagnostics, use `SELMEM` and the other extended BIOS calls.

## I/O decode summary

`IO_DECODER.pld` decodes address bits A7-A4 into 16-port blocks. A3-A0 select registers or subfunctions within the chosen device. Standard I/O cycles exclude interrupt-acknowledge cycles and reset.

| Port block | Function |
| --- | --- |
| `00h-0Fh` | Banking-latch read/write |
| `20h-2Fh` | SIO0 |
| `30h-3Fh` | SIO1 |
| `40h-4Fh` | CTC |
| `60h-6Fh` | Cartridge/expansion I/O |
| `A0h-BFh` | Video |
| `E0h-FFh` writes | Sound |
| `E0h-FFh` reads | Controllers |

The active peripheral register assignments are documented in [Z80 Peripheral Controller Architecture](Z80%20Peripherals%20Controller.md).

The remaining blocks—`10h`, `50h`, `70h`, `80h`, `90h`, `C0h`, and `D0h`—are not selected by the current `IO_EN` equation. `CART_CS` is declared by the memory decoder but currently has no memory-select equation; the `60h` cartridge I/O block does not by itself create a cartridge memory window.

## Sources of truth

Use these in descending order when implementation notes disagree:

1. [`MEM_DECODER.pld`](Code/HDL/WinCUPL/src/MEM_DECODER.pld) for memory chip selects and SRAM bank-address forcing.
2. [`IO_DECODER.pld`](Code/HDL/WinCUPL/src/IO_DECODER.pld) for I/O block selection.
3. [`platform_zephyr80.inc`](Code/HOST/CPM2.2/src/platform_zephyr80.inc) for software-visible port and latch constants.
4. [`boot_shadow_copy.asm`](Code/HOST/CPM2.2/src/boot_shadow_copy.asm) and [`cbios_bank.asm`](Code/HOST/CPM2.2/src/cbios_bank.asm) for current boot/runtime behavior.
5. The generated [memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md) for exact addresses in the current build.

Some comments inside the PLD and older test sources still refer to an earlier 8 KiB or `E000h` safe window. The active equations implement a 16 KiB common window at `C000h-FFFFh`.
