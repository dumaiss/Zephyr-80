# Zephyr-80 Memory Management

This document describes the memory hardware, the banking latch, the boot-time ROM copy, and the banked memory model the CP/M system runs in. It is derived from `MEM_DECODER.pld` revision 11 and the current BIOS source.

Exact addresses are declared in [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc), in its "Banked OS layout" block. The design, its invariants and its validation are in [OS Execution Memory Architecture](Code/HOST/CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md). The generated [memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md) give exact addresses and free space for the current build, and the build validates the layout as it generates them.

## Hardware model

- Z80 logical address space: 64 KiB
- SRAM: 512 KiB, organized as eight 64 KiB banks
- ROM/Flash address capacity: 512 KiB, organized as eight 64 KiB pages
- Banking latch: I/O port `00h`
- Memory decoder: `MEM_DECODER.pld`, revision 11
- I/O decoder: `IO_DECODER.pld`

The hardware exposes three SRAM-bank bits, three ROM-page bits, and two mode bits. While CP/M runs, a program sees its own bank and a small common region:

| Z80 range | Program running (mode 10) | Operating system running (mode 11) |
| --- | --- | --- |
| `0000h-1FFFh` | Program's SRAM bank | Program's SRAM bank |
| `2000h-DFFFh` | Program's SRAM bank | SRAM bank 7, the operating system |
| `E000h-FFFFh` | SRAM bank 0, common | SRAM bank 0, common |

ROM is storage only. At reset every ROM page is copied into the matching SRAM bank, and from then on the operating system — ZSDOS, the BIOS and its drivers — runs from SRAM bank 7. It is mapped in only while it executes, so each program bank keeps 56 KiB below the 8 KiB common region.

Decoder revision 11 and the banked-OS ROM must be programmed together. Neither works with an earlier revision of the other.

The firmware builder emits a 512 KiB image: one 64 KiB page per bank.

## Banking latch

The latch is decoded throughout `00h-0Fh`; software convention uses port `00h`. Writes update the latch and reads return its current value through the readback buffer.

| Bits | Name | Function |
| --- | --- | --- |
| D0-D2 | `BANK_Q0..2` | SRAM bank number, 0-7 |
| D3 | `RAM_SHADOW` | With ROM enabled: shadow/copy mode. With ROM disabled: operating-system mode |
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
| `00b` | `00h` | Boot: ROM visible |
| `01b` | `08h` | Shadow/copy |
| `10b` | `10h` | Application |
| `11b` | `18h` | Operating system |

Common latch expressions are:

| Operation | Value |
| --- | --- |
| Reset/default page 0, bank 0 | `00h` |
| Show ROM page `p` over SRAM bank `b` | `((p & 7) << 5) | (b & 7)` |
| Copy ROM page `p` into SRAM bank `b` | `((p & 7) << 5) | 08h | (b & 7)` |
| Run a program in SRAM bank `b` | `10h | (b & 7)` |
| Run the operating system over program bank `b` | `18h | (b & 7)` |

Entering and leaving the operating system changes only D3. The bank bits keep the program's bank throughout, so the latch itself records which bank is suspended:

```text
program in bank 3        latch = 13h
enter the OS             latch = 1Bh
return                   latch = 13h, bank 3 reappears
```

## Decoder behavior

All memory writes select SRAM. The mode bits determine which device answers memory reads and which SRAM bank each address reaches.

The bank-address equations of revision 11 are:

```text
SAFE_RAM    = A15 & A14                                ; C000h-FFFFh
COMMON_8K   = A15 & A14 & A13                          ; E000h-FFFFh
OS_BODY     = (A13 & !A14) # (A14 & !A15) # (A15 & !A13)   ; 2000h-DFFFh

FORCE_BANK0 = (SAFE_RAM & RAM_SHADOW & !ROM_DIS) # (COMMON_8K & ROM_DIS)
FORCE_BANK7 = ROM_DIS & RAM_SHADOW & OS_BODY

RAM_A16 = (BANK_Q0 & !FORCE_BANK0) # FORCE_BANK7
RAM_A17 = (BANK_Q1 & !FORCE_BANK0) # FORCE_BANK7
RAM_A18 = (BANK_Q2 & !FORCE_BANK0) # FORCE_BANK7
```

### Boot mode

Condition: `ROM_DIS=0`, `RAM_SHADOW=0`

| Address | Read source | Write target |
| --- | --- | --- |
| `0000h-5FFFh` | Selected ROM page | Selected SRAM bank |
| `6000h-BFFFh` | Selected SRAM bank | Selected SRAM bank |
| `C000h-FFFFh` | Selected ROM page | Selected SRAM bank |

This is the reset and ROM-restore mode. Writes to ROM-visible addresses go to hidden SRAM underneath. No bank is forced in this mode, so those hidden writes follow D0-D2; reset value `00h` therefore writes SRAM bank 0.

### Shadow/copy mode

Condition: `ROM_DIS=0`, `RAM_SHADOW=1`

| Address | Read source | Write target |
| --- | --- | --- |
| `0000h-BFFFh` | Selected ROM page | Selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0 | SRAM bank 0 |

Code executes from bank 0's high memory while it copies the lower 48 KiB of a ROM page into an SRAM bank. This mode still forces all of `C000h-FFFFh` to bank 0, so code that enters it must not have its stack or state in bank 7's `C000h-DFFFh`.

### Application mode

Condition: `ROM_DIS=1`, `RAM_SHADOW=0`

| Address | Read/write target |
| --- | --- |
| `0000h-DFFFh` | Selected SRAM bank |
| `E000h-FFFFh` | SRAM bank 0 |

ROM is not selected anywhere. Programs run in this mode.

### Operating-system mode

Condition: `ROM_DIS=1`, `RAM_SHADOW=1`

| Address | Read/write target |
| --- | --- |
| `0000h-1FFFh` | Selected SRAM bank |
| `2000h-DFFFh` | SRAM bank 7 |
| `E000h-FFFFh` | SRAM bank 0 |

The operating system runs in this mode. `0000h-1FFFh` stays on the program's bank, so ZSDOS reads the program's own page zero, default FCB and default DMA directly.

## Reset and ROM-to-RAM copy

The ROM-to-RAM copy is implemented in [`boot_shadow_copy.asm`](Code/HOST/CPM2.2/src/boot_shadow_copy.asm). It does not use a stack until RAM is fully established.

1. Reset starts with latch value `00h` and executes the ROM reset vector at `0000h`.
2. The reset vector jumps to `cpm_rom_entry_high` in the high ROM region.
3. In boot mode, the routine copies `C000h-FFFFh` from ROM page 0 into hidden SRAM bank 0.
4. It writes `08h`, entering shadow/copy mode for ROM page 0 and SRAM bank 0.
5. It copies `0000h-BFFFh` from ROM page 0 into SRAM bank 0.
6. For pages/banks 1-7, it writes `(n << 5) | 08h | n` and copies `0000h-BFFFh` into the matching SRAM bank. ROM page 7 holds the operating-system image, so this step installs it in bank 7.
7. It writes `10h`, disabling ROM and selecting SRAM bank 0.

Cold boot then continues in [`cbios_boot.asm`](Code/HOST/CPM2.2/src/cbios_boot.asm):

1. It writes `18h`, entering operating-system mode over bank 0, and moves to the BIOS stack in bank 7.
2. It checks that bank 7 holds this build's image, by its `BANK7OS1` marker. If not, it reports over SIO0/B and halts.
3. It initializes the hardware and the drivers, all of which live in bank 7.
4. It moves to a common stack, writes `10h` and enters the CCP.

The operating-system image must end below `C000h`, because shadow/copy mode loads only `0000h-BFFFh` of each page. Bank 7's `C000h-DFFFh` is runtime memory for the BIOS stacks and scratch buffers, and is never loaded.

Warm boot enters operating-system mode over bank 0 and resets the CTC. It clears program interrupt registrations and restores the CCP range, `CBASE` to `FBASE-1`, from ROM page 0 through a short boot-mode window. It then reinitializes the console and returns to application mode. Bank 7 is not reloaded.

## CP/M runtime layout

### What a program sees

| Range | Use |
| --- | --- |
| `0000h-00FFh` | Page zero, default FCBs and default DMA, in the program's bank |
| `0100h-DFFFh` | Banked transient program area |
| `E000h-E3FFh` | Program reservation: interrupt callbacks and the data they use |
| `E400h-EBFFh` | CCP (ZCPR2) |
| `EC00h-EC05h` | BDOS serial number, `ZSDOS ` |
| `EC06h` | `FBASE`: the BDOS entry |
| `F000h-FFFFh` | System common memory |

Page zero's `0006h` holds `EC06h`, so the transient program area is `0100h-EC05h`, 59 KiB. A large program may overwrite the CCP; warm boot restores it.

### System common memory

| Range | Use |
| --- | --- |
| `EC00h-EFFFh` | BDOS facade: the code behind `FBASE` |
| `F000h-F032h` | CP/M BIOS jump table |
| `F033h-F04Ah` | Zephyr extension table, reached through BDOS functions 210-217 |
| up to `F957h` | Boot and warm boot, banking, IOC link failure record, SIO core, bank-crossing code, interrupt dispatch, serial console |
| `F958h-FC97h` | 512-byte staging buffer, and the DPB and allocation-vector copies returned by BDOS functions 31 and 27 |
| `FD00h-FDFFh` | IM2 vector page |
| `FE00h-FE7Fh` | BIOS runtime state |
| `FE80h-FF5Fh` | Interrupt, gate and BDOS facade stacks |

### SRAM bank 7

| Range | Use |
| --- | --- |
| `2000h-2FFFh` | ZSDOS |
| `3000h-303Fh` | ZSDOS's BIOS jump table and the bank 7 image marker |
| `3040h-5FFFh` | Console, storage, IOC transport, HID, SD and ROM-disk drivers |
| `6000h-7FFFh` | Disk parameter blocks, directory buffer and allocation vectors |
| `8000h-8FFFh` | Console font and boot banner |
| `C000h-DFFFh` | Runtime only: BIOS private stacks and the SD scratch buffer |

### Ownership rules

- Banks 0-6 belong to programs. Bank 7 belongs to the operating system, and the banking services refuse it.
- `E000h-E3FFh` belongs to the running program. The operating system never uses it, and it is not preserved when the program exits.
- Data a program shares between its own banks must live in the common part of the transient area, `E000h-EC05h`.
- Nothing is published at a fixed address. Programs call the operating system through `CALL 5`, reach the BIOS jump table through page zero's `JP WBOOT`, and find the rest with Zephyr BDOS function 203.

## Banking services

Programs reach the banking services as Zephyr BDOS functions. The implementation is in [`cbios_bank.asm`](Code/HOST/CPM2.2/src/cbios_bank.asm), and [`cbios_facade.asm`](Code/HOST/CPM2.2/src/cbios_facade.asm) dispatches the calls.

| Function | Service | Inputs | Behavior |
| ---: | --- | --- | --- |
| 210 | `MOVE` | `BC` = length, `DE` = source, `HL` = destination | Performs a same-bank `LDIR`, or the pending cross-bank copy |
| 211 | `XMOVE` | `C` = source bank, `B` = destination bank | Arms the next `MOVE` as a cross-bank transfer |
| 212 | `SELMEM` | `A` = bank | Maps the bank at `0000h-DFFFh` and updates `CURRENT_BANK` |
| 213 | `SETBNK` | `A` = bank | Records the bank containing the next disk DMA buffer; does not switch immediately |

Each takes `C` = function and `DE` = a seven-byte register block holding `A`, `C`, `B`, `E`, `D`, `L`, `H`. The block is updated with the service's output registers, and `A` is also returned directly. Each refuses bank 7 with `A = FFh`. [`zbdos.inc`](Code/HOST/Utilities/src/zbdos.inc) wraps them for assembly programs.

A cross-bank `MOVE` copies through the common staging buffer in chunks of at most 192 bytes and restores the latch mode it found.

`SELMEM` replaces everything below `E000h` under the caller, so call it from common memory with the stack in common memory.

Direct application writes to port `00h` can desynchronize the hardware latch from the BIOS `CURRENT_BANK` record. A write that sets D3 maps bank 7 into the program's address space. Outside boot code and low-level diagnostics, use `SELMEM`.

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
4. [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc) for the address of everything in common memory and bank 7.
5. [`boot_shadow_copy.asm`](Code/HOST/CPM2.2/src/boot_shadow_copy.asm), [`cbios_boot.asm`](Code/HOST/CPM2.2/src/cbios_boot.asm), [`cbios_bank.asm`](Code/HOST/CPM2.2/src/cbios_bank.asm) and [`cbios_facade.asm`](Code/HOST/CPM2.2/src/cbios_facade.asm) for boot and runtime behavior.
6. The generated [memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md) for exact addresses in the current build.
7. [OS Execution Memory Architecture](Code/HOST/CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md) for the design rationale and invariants.

Older test sources, such as `Code/HOST/HelloWorld/tests/banktest`, were written for earlier memory arrangements and describe those.
