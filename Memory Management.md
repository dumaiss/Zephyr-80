# Zephyr-80 Computer Memory Management

Memory and I/O architecture reference derived from the current WinCUPL equation
files:

- `Code/HDL/WinCUPL/src/MEM_DECODER.pld`
- `Code/HDL/WinCUPL/src/IO_DECODER.pld`

This document intentionally follows the equations in those PLD files. If older
software notes disagree with this file, treat the PLD equations as the source of
truth.

## 1. Hardware Overview

- CPU: Z80
- RAM: 512 KiB SRAM, arranged as eight 64 KiB banks
- ROM: 512 KiB ROM/Flash, arranged as eight 64 KiB pages
- Memory banking latch: I/O port `00h`
- Memory decoder: ATF22V10 / WinCUPL design `Z80_MEM_DECODE`
- I/O decoder: ATF22V10 / WinCUPL design `Z80_IO_DECODE`

The current memory model reserves the top 16 KiB of the CPU address space as a
fixed/common area in RAM-only and shadow/copy modes:

- `0000h-BFFFh`: selected bank/page area
- `C000h-FFFFh`: fixed/common SRAM bank 0 area

This is the model used by the Zephyr CP/M/BBC BASIC work: CP/M page zero and
TPA live in the selected low bank, while the common runtime, BDOS/BIOS support,
bank helpers, and firmware stack can live in the protected high region.

## 2. Banking Latch at Port 00h

The memory banking latch is selected by the I/O decoder on ports `00h-0Fh`.
Writes clock the latch, and reads enable the latch readback buffer.

| Bit | Name | Meaning |
| --- | --- | --- |
| D0-D2 | RAM bank | Selected SRAM bank number, `0-7`, for the banked area. |
| D3 | RAM shadow | Enables shadow/copy mode when ROM is still enabled. |
| D4 | ROM disable | Disables ROM and selects RAM-only operation. |
| D5-D7 | ROM page | Selected ROM page number, `0-7`, for ROM-read copy/boot paths. |

Common latch values:

| Value | Meaning |
| --- | --- |
| `00h` | Reset/default: ROM enabled, shadow off, RAM bank 0, ROM page 0. |
| `08h` | Shadow/copy mode for ROM page 0 / RAM bank 0. |
| `10h` | RAM-only mode, shadow off, RAM bank 0. |
| `10h | n` | RAM-only mode, selected RAM bank `n`. |
| `(n << 5) | 08h | n` | Shadow/copy mode for ROM page `n` into RAM bank `n`. |

The MEM decoder equations directly use the RAM bank bits, `RAM_SHADOW`, and
`ROM_DIS`. The ROM page bits are part of the same latch scheme but are not
decoded inside `MEM_DECODER.pld` itself.

## 3. Memory Decoder Equations

`MEM_DECODER.pld` uses WinCUPL polarity conventions. `MREQ` is the physical
active-low `/MREQ` input and is inverted in the equations as `!MREQ`. `RD` and
`WR` are declared as negative-logic inputs, so those terms are true when `/RD`
or `/WR` are asserted. The chip-select outputs are declared as active-low pins;
when the logical equation for `ROM_CS`, `SRAM_CS`, or `CART_CS` is true, the
corresponding physical `/CS` output is asserted low.

The current region terms are:

```text
BIOS_RANGE = !A15 & (!A14 # !A13)    -> 0000h-5FFFh
UPPER_32K  = A15                     -> 8000h-FFFFh
RAM_ONLY   = !A15 & A14 & A13        -> 6000h-7FFFh
SAFE_RAM   = A15 & A14               -> C000h-FFFFh
COPY_AREA  = !SAFE_RAM               -> 0000h-BFFFh
BOOT_ROM   = BIOS_RANGE # SAFE_RAM   -> 0000h-5FFFh and C000h-FFFFh
```

The mode/helper terms in the PLD are:

```text
ALL_RAM_MODE     = ROM_DIS
EFFECTIVE_SHADOW = RAM_SHADOW & !ROM_DIS
FORCE_BANK0      = SAFE_RAM & (ROM_DIS # RAM_SHADOW)
```

`ALL_RAM_MODE` and `EFFECTIVE_SHADOW` document intent in the source, but the
current select equations use `ROM_DIS` and `RAM_SHADOW` directly.

SRAM address lines `A16-A18` are generated from the bank latch unless
`FORCE_BANK0` is true:

```text
RAM_A16 = BANK_Q0 & !FORCE_BANK0
RAM_A17 = BANK_Q1 & !FORCE_BANK0
RAM_A18 = BANK_Q2 & !FORCE_BANK0
```

Therefore SRAM bank 0 is forced only for `C000h-FFFFh` while either RAM-only
mode or shadow/copy mode is active. Otherwise SRAM address lines follow latch
bits `D0-D2`.

The chip-select equations are:

```text
ROM_CS = !MREQ & RD & !ROM_DIS & (
           (RAM_SHADOW & !SAFE_RAM)
         # (!RAM_SHADOW & BOOT_ROM)
         )

SRAM_CS = !MREQ & (
            WR
          # (RD & ROM_DIS)
          # (RD & !ROM_DIS & !RAM_SHADOW & RAM_ONLY)
          # (RD & !ROM_DIS & !RAM_SHADOW & UPPER_32K & !SAFE_RAM)
          # (RD & !ROM_DIS & RAM_SHADOW & SAFE_RAM)
          )
```

These equations imply:

| Mode | ROM reads | SRAM reads | SRAM writes |
| --- | --- | --- | --- |
| Normal ROM mode | `BOOT_ROM`: `0000h-5FFFh`, `C000h-FFFFh` | `6000h-BFFFh` | `0000h-FFFFh` |
| Shadow/copy mode | `!SAFE_RAM`: `0000h-BFFFh` | `SAFE_RAM`: `C000h-FFFFh` | `0000h-FFFFh` |
| RAM-only mode | none | `0000h-FFFFh` | `0000h-FFFFh` |

The SRAM bank selected for each access is still controlled by the `RAM_A16-A18`
equations above: in RAM-only and shadow/copy modes, `C000h-FFFFh` is forced to
SRAM bank 0, while `0000h-BFFFh` follows the selected bank.

## 4. Runtime Memory Modes

### 4.1 Normal ROM Mode

Condition:

```text
ROM_DIS = 0
RAM_SHADOW = 0
```

Read map:

| Address range | Read source |
| --- | --- |
| `0000h-5FFFh` | selected ROM page |
| `6000h-BFFFh` | selected SRAM bank |
| `C000h-FFFFh` | selected ROM page |

Write map:

| Address range | Write target |
| --- | --- |
| `0000h-FFFFh` | selected SRAM bank |

Normal mode therefore allows ROM to be visible for boot, while writes still
plant bytes into SRAM underneath the ROM-visible addresses. On reset the latch
is expected to be `00h`, so these hidden writes go to SRAM bank 0.

### 4.2 Shadow/Copy Mode

Condition:

```text
ROM_DIS = 0
RAM_SHADOW = 1
```

Read map:

| Address range | Read source |
| --- | --- |
| `0000h-BFFFh` | selected ROM page |
| `C000h-FFFFh` | SRAM bank 0 |

Write map:

| Address range | Write target |
| --- | --- |
| `0000h-BFFFh` | selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0 |

This is the ROM-to-RAM copy mode. Code running from `C000h-FFFFh` is safe
because that range reads and writes SRAM bank 0 while the lower 48 KiB reads
from the selected ROM page and writes to the selected SRAM bank.

### 4.3 RAM-Only Mode

Condition:

```text
ROM_DIS = 1
```

Read/write map:

| Address range | Read/write target |
| --- | --- |
| `0000h-BFFFh` | selected SRAM bank |
| `C000h-FFFFh` | SRAM bank 0 |

In RAM-only mode ROM is never selected. The top 16 KiB is fixed/common SRAM
bank 0, and the lower 48 KiB is the selected application/TPA bank.

## 5. ROM-to-RAM Boot Copy Model

The current high-common boot model is:

1. Reset starts at `0000h` in ROM page 0.
2. The reset vector jumps to high ROM code in `C000h-FFFFh`.
3. While still in normal ROM mode, copy `C000h-FFFFh` from ROM page 0 into
   SRAM bank 0. Reads come from ROM and writes go to hidden SRAM bank 0.
4. Enable shadow/copy mode for page/bank 0 with latch value `08h`.
5. Copy `0000h-BFFFh` from ROM page 0 into RAM bank 0.
6. For pages `1-7`, write `(n << 5) | 08h | n` to the latch and copy
   `0000h-BFFFh` from ROM page `n` into RAM bank `n`.
7. Disable ROM and select RAM bank 0 with latch value `10h`.
8. Continue execution from common RAM bank 0.

Only the lower 48 KiB of each page is copied per app bank. The top 16 KiB of
the CPU address space is common SRAM bank 0 in RAM-only mode, so the top 16 KiB
of RAM banks 1-7 is intentionally not visible in the normal runtime model.

## 6. CP/M-Oriented Layout

With the current 16 KiB common model, the intended CP/M-style runtime layout is:

| Address range | Purpose |
| --- | --- |
| `0000h-00FFh` | bank-local CP/M page zero |
| `0100h-BFFFh` | bank-local TPA/application area |
| `C000h-C3FFh` | Zephyr common ABI, bank helpers, buffers, debug state |
| `C400h-CBFFh` | CP/M CCP area for `MEM=56` |
| `CC00h-DFFFh` | CP/M BDOS area for `MEM=56` |
| `E000h-FFFFh` | Zephyr BIOS, hardware services, work area, firmware stack |

Because `C000h-FFFFh` is common/protected RAM bank 0, CCP, BDOS, and BIOS can
be common across application banks. Application payloads must fit below
`C000h`.

## 7. I/O Decoder

The current `IO_DECODER.pld` decodes I/O space using address bits `A7-A4`.
Each decoded block is therefore 16 ports wide. Lower address bits are passed to
the selected peripheral.

In WinCUPL terms for this file, `IORQ`, `M1`, `WR`, `RD`, and `RESET` are true
when the corresponding active-low bus pins are asserted. Standard I/O cycles are
decoded only when `/IORQ` is asserted, `/M1` is not asserted, and the system is
not in reset:

```text
StdIO_Cycle = IORQ & !M1 & !RESET
IntAck_Cycle = IORQ & M1 & !RESET
```

`IntAck_Cycle` is defined, but the current file no longer contains the older VDP
vector-generation or daisy-chain output equations.

### 7.1 Banking Latch Decode

The memory banking latch uses only `Block_00`:

```text
Block_00 = !A7 & !A6 & !A5 & !A4      -> 00h-0Fh
CS_MEMBANK_WR = StdIO_Cycle & Block_00 & WR
CS_MEMBANK_RD = StdIO_Cycle & Block_00 & RD
```

| Port range | Access | Signal |
| --- | --- | --- |
| `00h-0Fh` | write | `CS_MEMBANK_WR` |
| `00h-0Fh` | read | `CS_MEMBANK_RD` |

Although an older source comment says `$00-$1F`, the actual equation uses
`Block_00`, which is only `00h-0Fh`.

### 7.2 Peripheral Decode

The source defines this standard peripheral block list:

```text
IO_EN = StdIO_Cycle & (Block_20 # Block_30 # Block_40 # Block_60 #
                      Block_A0 # Block_B0 # Block_E0 # Block_F0)
```

The decoder drives `SEL2..0` for a downstream `74LS138` or equivalent decode
stage. The visible selector equation is:

```text
IO_ADDR =  StdIO_Cycle & 'b'001 & Block_20                    /* SIO0 */
         # StdIO_Cycle & 'b'010 & Block_30                    /* SIO1 */
         # StdIO_Cycle & 'b'011 & Block_40                    /* CTC */
         # StdIO_Cycle & 'b'100 & Block_60                    /* CART_IO */
         # StdIO_Cycle & 'b'101 & (Block_A0 # Block_B0)       /* VDP */
         # StdIO_Cycle & 'b'110 & (Block_E0 # Block_F0) & WR  /* SOUND */
         # StdIO_Cycle & 'b'111 & (Block_E0 # Block_F0) & RD  /* CTRL */
```

Current selector assignments are:

| Port range | Selector | Function |
| --- | --- | --- |
| `20h-2Fh` | `001b` | SIO0 |
| `30h-3Fh` | `010b` | SIO1 |
| `40h-4Fh` | `011b` | CTC |
| `60h-6Fh` | `100b` | cartridge I/O expansion |
| `A0h-AFh` | `101b` | VDP |
| `B0h-BFh` | `101b` | VDP |
| `E0h-EFh` write | `110b` | sound |
| `F0h-FFh` write | `110b` | sound |
| `E0h-EFh` read | `111b` | controller |
| `F0h-FFh` read | `111b` | controller |

These blocks are not selected by the current `IO_EN` equation:

| Port range | Current PLD status |
| --- | --- |
| `10h-1Fh` | unused |
| `50h-5Fh` | unused |
| `70h-7Fh` | unused |
| `80h-8Fh` | unused/reserved |
| `90h-9Fh` | unused/reserved |
| `C0h-CFh` | unused/reserved |
| `D0h-DFh` | unused/reserved |

`IO_EN` is present as a source term in the PLD, but the visible output pins in
this file are the active-low memory-bank latch selects and `SEL2..0`.

## 8. Notes from the Current PLD Files

- `MEM_DECODER.pld` revision 09 is the active source for the 16 KiB common
  memory model.
- `SAFE_RAM` is `C000h-FFFFh`, not the older `E000h-FFFFh` or bottom-8K model.
- The comments inside `MEM_DECODER.pld` still contain a couple of old
  `$E000-$FFFF`, `$0000-$DFFF`, and "high safe 8K" phrases, but the equations
  implement `C000h-FFFFh` as the safe/common region.
- `ROM_CS` and `SRAM_CS` equations, plus the `RAM_A16-A18` equations, are the
  authoritative memory manager behavior for software-visible banking.
- `CART_CS` is declared as an output in `MEM_DECODER.pld`, but the current
  equation file does not assign an active cartridge select equation.
- `IO_DECODER.pld` revision 03 is the active source for the I/O block map above.
