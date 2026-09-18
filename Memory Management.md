# Zephyr-80 Memory Management

This document describes the memory hardware, the banking latch, the boot-time ROM copy, and the banked memory model the CP/M system runs in. It is derived from `MEM_DECODER.pld` revision 12 and the current BIOS source.

Exact addresses are declared in [`cbios_defs.inc`](Code/HOST/CPM2.2/src/cbios_defs.inc), in its "Banked OS layout" block. The design, its invariants and its validation are in [OS Execution Memory Architecture](Code/HOST/CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md). The generated [memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md) give exact addresses and free space for the current build, and the build validates the layout as it generates them.

## Hardware model

- Z80 logical address space: 64 KiB
- SRAM: 512 KiB, organized as eight 64 KiB banks
- ROM/Flash address capacity: 512 KiB, organized as eight 64 KiB pages
- Banking latch: I/O port `00h`
- Memory decoder: `MEM_DECODER.pld`, revision 12
- I/O decoder: `IO_DECODER.pld`

The hardware exposes three SRAM-bank bits, three ROM-page bits, and two mode bits. While CP/M runs, a program sees its own bank and a small common region:

| Z80 range | Program running (mode 10) | Operating system running (mode 11) |
| --- | --- | --- |
| `0000h-1FFFh` | Program's SRAM bank | Program's SRAM bank |
| `2000h-DFFFh` | Program's SRAM bank | SRAM bank 7, the operating system |
| `E000h-FFFFh` | SRAM bank 0, common | SRAM bank 0, common |

Every physical SRAM bank is a full 64 KiB, including `E000h-FFFFh`. Modes 10 and 11 overlay that top 8 KiB with bank 0 to create the common region; flat mode 01 does not, so the hidden top of banks 1-7 is reachable there. Nothing in `E000h-FFFFh` is missing in the nonzero banks — it is covered, not absent.

ROM pages have distinct roles, and the page number is independent of the SRAM bank number. Two pages are boot images that seed SRAM at cold boot; three back CP/M drive A: and are never copied anywhere; three are unused. See "ROM layout" below.

Decoder revision 12 and this ROM must be programmed together. The mode-bit meanings changed, so neither works with an earlier revision of the other.

The firmware builder emits a 512 KiB image: one 64 KiB page per ROM page.

## Banking latch

The latch is decoded throughout `00h-0Fh`; software convention uses port `00h`. Writes update the latch and reads return its current value through the readback buffer.

| Bits | Name | Function |
| --- | --- | --- |
| D0-D2 | `BANK_Q0..2` | SRAM bank number, 0-7 |
| D3 | `MEM_MODE0` | Memory-mode bit 0 |
| D4 | `MEM_MODE1` | Memory-mode bit 1 |
| D5-D7 | ROM page | ROM page number, 0-7 |

For ROM page `p`, SRAM bank `b`, and mode bits `m`:

```text
latch = ((p & 7) << 5) | m | (b & 7)
```

The ROM-page bits are not used inside `MEM_DECODER.pld`; they select the ROM address externally. The SRAM-bank bits feed the decoder's `RAM_A16-A18` outputs.

### Mode-bit combinations

`D4:D3` selects one of four memory mappings. They are mappings, not feature flags: no bit "disables ROM" or "enables copying" on its own.

| D4:D3 | Value | Constant | Mode |
| --- | ---: | --- | --- |
| `00b` | `00h` | `MEM_MODE_ROM` | ROM access / RAM destination |
| `01b` | `08h` | `MEM_MODE_FLAT` | Flat selected SRAM bank |
| `10b` | `10h` | `MEM_MODE_APPLICATION` | Application + common |
| `11b` | `18h` | `MEM_MODE_OS` | Application low + bank-7 OS + common |

The constants are defined once, in [`memory_modes.inc`](Code/HOST/CPM2.2/src/memory_modes.inc), alongside `RAM_BANK_MASK`, `MEM_MODE_MASK`, `ROM_PAGE_MASK` and `ROM_PAGE_SHIFT`, which separate the latch's three fields.

Common latch expressions are:

| Operation | Value |
| --- | --- |
| Reset/default page 0, bank 0 | `00h` |
| Read ROM page `p` while writing SRAM bank `b` | `((p & 7) << 5) | (b & 7)` |
| Use SRAM bank `b` flat, all 64 KiB | `08h | (b & 7)` |
| Run a program in SRAM bank `b` | `10h | (b & 7)` |
| Run the operating system over program bank `b` | `18h | (b & 7)` |

Copying ROM page `p` into SRAM bank `b` is the same latch value as reading page `p` while writing bank `b`: in mode 00 a single `LDIR` reads ROM and writes SRAM, because the read and write sides select different chips.

Entering and leaving the operating system changes only the mode field. The bank bits keep the program's bank throughout, so the latch itself records which bank is suspended:

```text
program in bank 3        latch = 13h
enter the OS             latch = 1Bh
return                   latch = 13h, bank 3 reappears
```

## Decoder behavior

All memory writes select SRAM. The mode bits determine which device answers memory reads and which SRAM bank each address reaches.

The whole decoder is these eight lines of revision 12:

```text
COMMON_8K   = A15 & A14 & A13                              ; E000h-FFFFh
OS_BODY     = (A13 & !A14) # (A14 & !A15) # (A15 & !A13)   ; 2000h-DFFFh

FORCE_BANK0 = MEM_MODE1 & COMMON_8K
FORCE_BANK7 = MEM_MODE1 & MEM_MODE0 & OS_BODY
ROM_READ    = !MEM_MODE1 & !MEM_MODE0

RAM_A16 = (BANK_Q0 & !FORCE_BANK0) # FORCE_BANK7
RAM_A17 = (BANK_Q1 & !FORCE_BANK0) # FORCE_BANK7
RAM_A18 = (BANK_Q2 & !FORCE_BANK0) # FORCE_BANK7

ROM_CS  = !MREQ & RD & ROM_READ
SRAM_CS = !MREQ & (WR # (RD & !ROM_READ))
```

Six terms carry the whole model: the common region, the OS body, force-bank-0, force-bank-7, ROM read enable, and the selected bank passing through untouched. `FORCE_BANK7` drives all three bank lines high, so it needs no term in the latch path, and it can never overlap `FORCE_BANK0` because `OS_BODY` excludes `COMMON_8K`.

Modes 00 and 01 force nothing, so the selected bank reaches every address. Only `MEM_MODE1` can force a bank, which is what makes the common region exist in modes 10 and 11 and not in modes 00 and 01.

### Mode 00 — ROM access / RAM destination

Condition: `MEM_MODE1=0`, `MEM_MODE0=0`

| Address | Read source | Write target |
| --- | --- | --- |
| `0000h-FFFFh` | Selected ROM page | Selected SRAM bank |

Completely regular: every read comes from the ROM page in D5-D7, every write goes to the SRAM bank in D0-D2, across the whole address space. There is no split, no forced region and no common window. This is the reset mode and the primitive behind both the cold-boot copy and drive-A reads.

Two consequences follow from reads coming from ROM everywhere, and both matter:

- **Code must be stackless while this mode is active.** A `PUSH` writes SRAM but the matching `POP` or `RET` reads ROM, so a stack cannot survive the window. Restore another mode before the first stack read.
- **Instruction fetches come from ROM too.** Code can only keep executing if the ROM page holds the same bytes at the same address that the running code occupies. The cold-boot bootstrap satisfies this by being byte-identical in every page it switches between; the drive-A primitive satisfies it by being mirrored into each drive-A page.

### Mode 01 — flat SRAM

Condition: `MEM_MODE1=0`, `MEM_MODE0=1`

| Address | Read/write target |
| --- | --- |
| `0000h-FFFFh` | Selected SRAM bank |

A true 64 KiB view of one SRAM bank. No ROM, no forced bank 0, no forced bank 7, no common region. This is the only mode that reaches `E000h-FFFFh` in banks 1-7.

It is general-purpose, not a compatibility mode. Uses include machine/personality loaders such as ColecoGo, RAM diagnostics, whole-bank initialization, and any future resident manager that needs a complete bank. Because there is no common region, there is no common stack: code running here must keep its stack inside the selected bank.

### Mode 10 — application

Condition: `MEM_MODE1=1`, `MEM_MODE0=0`

| Address | Read/write target |
| --- | --- |
| `0000h-DFFFh` | Selected SRAM bank |
| `E000h-FFFFh` | SRAM bank 0 |

ROM is not selected anywhere. Programs run in this mode.

### Mode 11 — operating system

Condition: `MEM_MODE1=1`, `MEM_MODE0=1`

| Address | Read/write target |
| --- | --- |
| `0000h-1FFFh` | Selected SRAM bank |
| `2000h-DFFFh` | SRAM bank 7 |
| `E000h-FFFFh` | SRAM bank 0 |

The operating system runs in this mode. `0000h-1FFFh` stays on the program's bank, so ZSDOS reads the program's own page zero, default FCB and default DMA directly.

## ROM layout

The ROM is not eight boot images. Each page has one role, and the builder records it explicitly in [`config/banks.ini`](Code/HOST/CPM2.2/config/banks.ini) with a `kind` field rather than inferring it from the page number.

| ROM page | Kind | Contents | Copied to SRAM at cold boot |
| ---: | --- | --- | --- |
| 0 | boot | Common memory, reset vector and bootstrap, CCP, BDOS facade, BIOS tables, drivers' common halves | Bank 0, all 64 KiB |
| 1-3 | romdisk | CP/M drive A:, 48 KiB of filesystem per page at `0000h-BFFFh` | Never |
| 4-6 | unused | Erased | Never |
| 7 | boot | ZSDOS, the BIOS and drivers at `2000h-DFFFh`, plus the pristine CCP | Bank 7, all 64 KiB |

Drive-A pages are persistent immutable storage. They are not copied merely because an SRAM bank with the same number exists; SRAM banks 1-6 are never seeded, and the system initializes them in software when it needs them.

The only bytes written into a drive-A page outside its filesystem payload are the seven-byte ROM-read primitive, mirrored into the unused tail at `ROM_ACCESS_BASE`. The builder asserts that this lies above the 48 KiB payload and re-checks the filesystem bytes afterwards, so a drive-A page can never receive bootstrap code or accidental modification.

## Reset and ROM-to-RAM copy

The cold-boot copy is implemented in [`boot_rom_copy.asm`](Code/HOST/CPM2.2/src/boot_rom_copy.asm). It is stackless throughout: mode 00 is active for the whole sequence, and a stack could not survive it.

It copies only the two pages that are boot images, and maps each to its destination bank explicitly:

```text
ROM page 0 -> SRAM bank 0     (latch 00h)
ROM page 7 -> SRAM bank 7     (latch E7h)
```

1. Reset starts with latch value `00h` and executes the ROM reset vector at `0000h`.
2. The reset vector jumps to `cpm_rom_entry_high` in common memory, which masks interrupts and enters the bootstrap at `0003h`.
3. With the latch at `00h`, `HL=DE=BC=0000h` and one `LDIR` copy all 64 KiB of ROM page 0 into SRAM bank 0. `BC=0000h` is deliberate: the Z80 treats it as 65536 transfers.
4. It writes `E7h` — ROM page 7, SRAM bank 7, still mode 00 — and repeats the same full-page `LDIR`.
5. It writes `10h`, entering application mode on bank 0, and jumps to `boot`.

Step 4 is why both boot pages carry the identical bootstrap at the identical address. Changing the ROM-page selector changes where the next instruction is fetched from, so execution can only continue if the new page has the same bytes there. `split_banked_image.py` copies page 0's first `BOOTSTRAP_LIMIT` bytes into page 7, and the image builder asserts the two are equal. Step 5 works the same way: bank 0 now holds a copy of page 0, so the instruction after the `OUT` is the same byte either way.

The bootstrap occupies `0003h-0027h`, 37 bytes of a 128-byte budget. The copies it leaves in each bank's page zero are disposable; normal page-zero initialization overwrites them.

Cold boot then continues in [`cbios_boot.asm`](Code/HOST/CPM2.2/src/cbios_boot.asm):

1. It writes `18h`, entering operating-system mode over bank 0, and moves to the BIOS stack in bank 7.
2. It checks that bank 7 holds this build's image, by its `BANK7OS1` marker. If not, it reports over SIO0/B and halts.
3. It initializes the hardware and the drivers, all of which live in bank 7.
4. It moves to a common stack, writes `10h` and enters the CCP.

Because cold boot installs a complete 64 KiB page, bank 7's `C000h-DFFFh` is no longer restricted to runtime use. It still holds the BIOS private stacks and the SD scratch buffer at `C000h-C3BFh`, but initialized content may now live above them; the pristine CCP at `C400h-CBFFh` is the first such asset.

### Warm boot

Warm boot enters operating-system mode over bank 0 and resets the CTC, clears program interrupt registrations, restores the CCP, reinitializes the console, and returns to application mode. Bank 7 is not reloaded.

Removing the old copier did not remove WBOOT's need for pristine data. A transient program may destroy VRAM, the font uploaded into it, the video mode, or the palette, so WBOOT has to rebuild the console environment from a known-good source. Both sources it needs are resident in bank 7, which no program can reach:

| Asset | Location | Used by |
| --- | --- | --- |
| Console font, CP850 6x8 | Bank 7 `8000h` | Console init, re-uploaded to VRAM |
| Boot banner | Bank 7 `8800h` | Cold boot |
| Pristine CCP | Bank 7 `C400h-CBFFh` | `restore_ccp_from_os` |

WBOOT therefore performs no memory-mode transition to reach any of them: it is already in mode 11 with bank 7 mapped, and the destinations are the common CCP slot and VRAM. It never maps ROM. ROM remains available after cold boot — drive A: depends on it — but WBOOT has no reason to read it.

## Drive A: ROM access

Drive A: is the constraint that shapes mode 00. A ROM-disk read has to map ROM in, but in mode 00 every instruction fetch and every stack read comes from ROM, so the driver cannot simply call a copy routine the way the old design did from common SRAM.

The solution is software, not extra decoder logic. A seven-byte primitive is mirrored into the unused tail of each drive-A page, at the same address it occupies in common SRAM:

```text
ROM_ACCESS_BASE   ld bc,#128      ; one CP/M record
                  ldir            ; ROM -> SRAM, one instruction
                  out (BANK_PORT),a   ; restore the caller's mapping
                  ret             ; fetched from SRAM again
```

`xing_rom_read` in [`cbios_xing.asm`](Code/HOST/CPM2.2/src/cbios_xing.asm) enters it with `OUT (C),B`, the instruction immediately before `ROM_ACCESS_BASE`. That `OUT` switches to mode 00, and the very next fetch comes from the ROM page — which holds the same three instructions at the same address, so execution continues. The closing `OUT` restores the caller's latch from `A` before the `RET`, so the return address is read from SRAM, never from ROM.

The contract this depends on:

- the primitive is stackless between the two `OUT`s, and holds its return latch in `A`;
- interrupts are masked for the window, one 128-byte record, because an ISR would fetch from ROM;
- `ROM_ACCESS_BASE` lies above the 48 KiB filesystem payload, so mirroring it into a drive-A page cannot touch file data;
- the assembler checks the mirrored block is exactly `ROM_ACCESS_SIZE` bytes and starts exactly at `ROM_ACCESS_BASE`, and the builder checks the bytes it mirrors match the assembled ones.

Because mode 00 forces no bank, the destination follows D0-D2 across the whole address space, including `C000h-DFFFh`. The old design had to refuse DMA there; this one does not.

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
| `C000h-C3BFh` | BIOS private stacks and the SD scratch buffer |
| `C400h-CBFFh` | Pristine CCP, the warm-boot restore source |
| `CC00h-DFFFh` | Unallocated; initialized content may be placed here |

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

Direct application writes to port `00h` can desynchronize the hardware latch from the BIOS `CURRENT_BANK` record. A write that changes the mode field to `11b` maps bank 7 into the program's address space, and one that clears `MEM_MODE1` removes the common region under the program's stack. Outside boot code and low-level diagnostics, use `SELMEM`.

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
5. [`memory_modes.inc`](Code/HOST/CPM2.2/src/memory_modes.inc) for the latch's three fields and the four mode constants.
6. [`boot_rom_copy.asm`](Code/HOST/CPM2.2/src/boot_rom_copy.asm), [`cbios_boot.asm`](Code/HOST/CPM2.2/src/cbios_boot.asm), [`cbios_xing.asm`](Code/HOST/CPM2.2/src/cbios_xing.asm), [`cbios_bank.asm`](Code/HOST/CPM2.2/src/cbios_bank.asm) and [`cbios_facade.asm`](Code/HOST/CPM2.2/src/cbios_facade.asm) for boot, drive-A ROM access and runtime behavior.
7. The generated [memory map](Code/HOST/CPM2.2/docs/memory-map.md) and [symbol map](Code/HOST/CPM2.2/docs/symbol-map.md) for exact addresses in the current build.
8. [OS Execution Memory Architecture](Code/HOST/CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md) for the design rationale and invariants.

Older test sources were written for earlier memory arrangements and describe those, not this one. `Code/HOST/HelloWorld/tests/banktest` and `Code/HOST/HelloWorld/src/shadow_copy_low.inc` still use the pre-revision-12 names `ROM_DIS` and `RAM_SHADOW`, and their shadow-copy sequence does not work on this decoder. They are kept as historical records of the earlier hardware.
