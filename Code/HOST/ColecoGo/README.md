# ColecoGo

`ColecoGo` is a CP/M user-space launcher for running ColecoVision software directly on Zephyr-80 hardware.

The intended command-line interface is:

```text
A>COLECOGO GAME.ROM
```

The launcher is a one-way machine takeover. It uses CP/M only to locate and load the ColecoVision BIOS and cartridge image, prepares a dedicated RAM bank and the Zephyr compatibility hardware, then transfers control to the ColecoVision BIOS at `0000h`. Returning to CP/M is not supported or expected.

## Scope

The initial implementation targets conventional ColecoVision cartridge images up to 32 KiB.

The ColecoVision BIOS is not embedded in the executable. `COLECOGO.COM` is expected to load it from a separate file, initially named:

```text
COLECO.ROM
```

The initial loader should validate that the BIOS image is exactly 8 KiB and that the cartridge image is no larger than 32 KiB.

Larger bank-switched cartridge formats are outside the scope of the first version.

## Relevant Zephyr-80 memory model

In normal RAM-only operation, Zephyr-80 exposes:

```text
0000h-BFFFh   selected SRAM bank
C000h-FFFFh   SRAM bank 0, fixed/common
```

This means a ColecoVision cartridge mapped at `8000h-FFFFh` crosses the Zephyr physical bank boundary at `C000h`.

That boundary is invisible to the Z80, so the loader can construct the final Coleco address space from two physical RAM regions:

```text
Logical address   Physical Zephyr RAM
---------------   -------------------
0000h-1FFFh       selected Coleco bank
2000h-5FFFh       selected Coleco bank, temporary staging area
6000h-7FFFh       selected Coleco bank, Coleco RAM
8000h-BFFFh       selected Coleco bank, cartridge lower 16 KiB
C000h-FFFFh       bank 0, cartridge upper 16 KiB
```

The first implementation can reserve one SRAM bank, for example bank 7, as the Coleco takeover bank.

## Loading scheme

### 1. Run normally under CP/M

`COLECOGO.COM` starts as an ordinary CP/M transient program at `0100h`.

While CP/M is still fully operational, it:

1. parses the cartridge filename from the command line
2. opens `COLECO.ROM`
3. validates the BIOS size
4. opens the requested cartridge image
5. validates the cartridge size
6. loads both files through normal CP/M BDOS services
7. uses the Zephyr extended BIOS cross-bank move support to construct the target bank

All errors should be reported before the takeover begins.

### 2. Construct the target bank

The target bank is prepared as follows:

```text
0000h-1FFFh   ColecoVision BIOS
2000h-5FFFh   temporary staging for GAME.ROM offsets 4000h-7FFFh
6000h-7FFFh   cleared for Coleco RAM
8000h-BFFFh   GAME.ROM offsets 0000h-3FFFh
```

For cartridge images smaller than 32 KiB, the cartridge destination should be initialized to a deterministic fill value before overlaying the file contents. `FFh` is the proposed initial fill value.

The upper 16 KiB of a 32 KiB cartridge cannot be placed directly at logical `C000h-FFFFh` in the target bank because that logical range always resolves to physical bank 0 in RAM-only mode. It is therefore staged temporarily at `2000h-5FFFh` in the target bank.

### 3. Install the final handoff code

The final takeover requires code that survives the bank switch.

The current CP/M memory model reserves `C000h-C3FFh` as application-owned common memory. A small Stage A trampoline can be copied there before takeover.

Stage A is responsible for:

1. disabling interrupts
2. shutting down CP/M-owned interrupt sources that must not fire during takeover
3. switching to the selected Coleco RAM bank
4. jumping to Stage B in the newly selected bank

Stage B must live below `C000h` in the target bank. Its exact location is intentionally left open until implementation, but it must not depend on CP/M, BDOS, BIOS stack state, or any code/data that will be overwritten.

### 4. Complete the cartridge mapping

Once Stage B is executing in the target bank, the loader can overwrite the common bank-0 CP/M region.

Conceptually:

```asm
ld      hl,2000h
ld      de,0C000h
ld      bc,4000h
ldir
```

This copies the staged upper 16 KiB of the cartridge into the live logical range `C000h-FFFFh`.

At this point CP/M, BDOS, BIOS, drivers, and the former CP/M stack in that region are intentionally destroyed. No return path is expected.

The final Z80-visible image is then:

```text
0000h-1FFFh   ColecoVision BIOS
2000h-5FFFh   don't-care / available
6000h-7FFFh   Coleco RAM
8000h-FFFFh   cartridge image
```

## Hardware compatibility handoff

Zephyr-80 was designed so Coleco software can access compatible hardware directly after CP/M gets out of the way.

The final handoff therefore does not emulate Coleco I/O and does not proxy runtime accesses through CP/M.

### V9958 video

Before jumping to the ColecoVision BIOS, ColecoGo only needs to establish the Zephyr/V9958-specific state that original Coleco software cannot establish itself:

1. select the Coleco-compatible VDP interrupt route, with the V9958 interrupt presented to the Z80 as NMI
2. program the V9958 palette to reproduce the fixed Coleco/TMS9918 palette

The ColecoVision BIOS is then allowed to initialize the ordinary TMS9918-compatible VDP registers itself.

### Controller input

No runtime HID translation layer is required in ColecoGo.

The Zephyr I/O Controller maintains controller state in hardware latches at the addresses expected by ColecoVision software. Once takeover is complete, Coleco software reads those latches directly with its normal I/O instructions.

### Sound

Coleco-compatible sound accesses are expected to reach the appropriate SN76489-compatible path directly through the Zephyr hardware decode. ColecoGo may silence/reset the sound path during handoff if required, but it should not remain involved at runtime.

## Final takeover sequence

The intended final sequence is:

```text
COLECOGO GAME.ROM
        |
        +-- load COLECO.ROM -> target bank 0000h-1FFFh
        |
        +-- load GAME.ROM lower half -> target bank 8000h-BFFFh
        |
        +-- stage GAME.ROM upper half -> target bank 2000h-5FFFh
        |
        +-- install Stage A in common application-owned RAM
        |
        +-- all validation and error reporting complete
        |
        +-- DI
        +-- quiesce CP/M interrupt sources
        +-- select V9958 interrupt -> NMI
        +-- program Coleco/TMS9918 palette
        +-- switch to target Coleco bank
        +-- jump to Stage B
        +-- copy staged upper cartridge -> C000h-FFFFh
        +-- establish a safe temporary stack if needed
        +-- JP 0000h
                |
                v
        ColecoVision BIOS
                |
                v
             cartridge
```

The transfer to `0000h` is a `JP`, not a `CALL`. There is no caller to return to.

## Implementation notes

The initial implementation should prefer the existing Zephyr extended BIOS banking services while CP/M is still active instead of writing directly to the memory-control latch. In particular, the current BIOS provides cross-bank move support suitable for staging data into the takeover bank while restoring the caller's original bank afterward.

Direct low-level bank manipulation belongs only in the final no-return trampoline where CP/M bookkeeping is no longer relevant.

The exact Stage B address and final scratch layout should be chosen when the assembly implementation begins. The loader must ensure that Stage B does not overwrite itself while copying the upper cartridge half and that the final Coleco RAM area is left in a suitable state before `JP 0000h`.

## Project layout

```text
Code/HOST/ColecoGo/
|-- README.md
|-- Makefile
|-- src/
|   `-- README.md
`-- tools/
    `-- README.md
```

The current Makefile is intentionally a placeholder until the assembler/linker and source organization are selected.
