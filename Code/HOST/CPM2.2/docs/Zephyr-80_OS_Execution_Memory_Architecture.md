# Zephyr-80 Banked OS Execution Architecture

**Status:** Implementation plan for this port — active  
**Branch:** `banked-os`, based on `3e0854a`, the last commit before any ROM-service work. Earlier work is preserved on `rom-services` (`abff820`).  
**Scope:** The work required in this port: decoder, BIOS, ZSDOS and ZCPR2 integration, build, and this tree's own utilities. Application-facing documentation is a separate pass once Phase 2 is complete.  
**Compatibility:** None required. Every Zephyr program in the tree is retrofitted. Third-party tools on the A: ROM disk that cannot work through BDOS are dropped, and anything useful among them is rewritten (section 11).  
**Hardware constraint:** No PCB changes. Decoder equations, firmware, linker layout and software may change.  
**Supersedes:** The runtime ROM-service / ROM-overlay execution architecture.  
**Lifetime:** This becomes a historical record once Phase 2 is complete and validated on hardware.

---

## 1. Summary

Zephyr-80 moves its operating system into a dedicated SRAM bank and runs it from RAM. The OS no longer lives in high common memory, and BIOS and driver code no longer execute from ROM.

The final address space has three classes:

```text
0000-1FFF   caller window        always the running program's bank
2000-DFFF   switchable body      the program's bank, or the OS in bank 7
E000-FFFF   common window        always physical bank 0
```

The two RAM execution modes:

```text
MODE 10 — APPLICATION EXECUTION          latch = 10h | N

0000-DFFF   application bank N (0-6)
E000-FFFF   physical bank 0


MODE 11 — OS EXECUTION                   latch = 18h | N

0000-1FFF   application bank N           unchanged
2000-DFFF   physical bank 7
E000-FFFF   physical bank 0
```

Bank 7 belongs to the OS. The low 8 KiB stays on the running program's bank while the OS runs, so ZSDOS sees that program's real page zero, default FCBs, default DMA and command tail. The top 8 KiB is common in both modes.

ROM is storage: boot, recovery, canonical system images and immutable resources. It is not a runtime execution environment.

**The 8 KiB common window is the required end state.** Phase 1 reaches it in two steps to keep each step testable, but Phase 2 is not optional: recovering `C000h-DFFFh` as banked memory is one of the reasons for doing this at all.

The model is CP/M 2.2 and ZSDOS semantics on a CP/M 3-style banked kernel, using decoder support specific to this machine.

---

## 2. Corrections to the Converged Design

These are defects in the design as it was first written: each one fails if implemented as stated. They are expanded in the sections noted, and all of them are part of the Phase 1 work.

| # | Correction | Failure if omitted | Section |
|---|---|---|---|
| F1 | ZSDOS's two `RST 0` (`zsdos/src/zsdos.z80:487`, `:1026`) jump to a common helper that restores mode 10 before jumping to `0000h` | A program that has replaced the `JP` at `0000h` has its handler executed in mode 11, with `2000h-DFFFh` mapped to bank 7 | 12, 19 |
| F2 | ZSDOS gets a real stack of 128-256 bytes, grown in place so `IXSAVE` stays the two bytes directly below `ZSDOSS`; every ISR switches to a common ISR stack; every interrupt-enabled stack keeps two bytes of headroom | The stock stack is about 56 bytes (`zsdos.z80:316-326`) and an interrupt overruns it into `SPSAVE`. Moving it by changing `LD SP,ZSDOSS` (`:342`) alone corrupts IX on every BDOS return, because `DOSEXT0` restores IX from `IXSAVE` by address (`:1065`) | 12, 15, 18 |
| F3 | Every BIOS latch write becomes a common crossing helper that restores the mode bits it found | Nine existing routines restore a hardcoded mode 10; called from bank-7 code, they unmap the code calling them | 16 |
| F4 | IOC bulk transfers never change the mapping mid-transfer | The bulk lane is timing-fragile (first-byte loss, the Tx underrun latch, persistent sync); a chunk boundary inside a transfer can underrun the transmitter | 14 |
| F5 | ISR registrations are cleared by `WBOOT` and when a transient returns to ZCPR2, with their CTC channels reset; `WBOOT` also reloads `I` and reprograms the device vectors | A program that exits with a callback registered — including by `RET` to ZCPR2, which does not warm boot (`zcpr2/src/ZCPR2.ASM:2143-2146`) — leaves a vector into the reservation the next program overwrites | 18, 19 |
| F6 | The common BIOS table keeps the CP/M 2.2 shape with only boot and console entries live, and ZCPR2's `BIOS EQU` is generated to point at it | ZCPR2 calls `BIOS+6` (CONST) and `BIOS+9` (CONIN) directly (`zcpr2/src/ZCPR2.ASM:691`, `:920-924`); `Z2HDR.LIB:96` hardcodes `0DA00H` | 11 |
| F7 | BDOS functions 27 and 31 return common copies of the ALV and DPB; the disk structures themselves live in bank 7 | A pointer into bank 7 is invalid the moment the call returns to mode 10 | 22 |
| F8 | The BDOS facade is non-reentrant: bank-7 code calls ZSDOS and the BIOS directly, never through `CALL 5`, and ISRs never call BDOS | A nested entry overwrites the saved caller state and returns with the wrong mapping | 9 |
| F9 | The BIOS owns IM2: `I` is always the BIOS vector page, every entry in it reaches common BIOS code, and program interrupt handlers are callbacks registered through the Zephyr BDOS range, with the entry validated inside `E000h-E3FFh` | `I` locates the vector table, not the handlers: a program-installed table in common can vector to a handler at `9000h`, which is bank 7 in mode 11. The facade cannot see that, so a policy based on `I` must either disable interrupts across every OS call or risk a crash | 9, 18 |
| F10 | The facade's DMA tracking follows function 13 as well as `SETDMA` | Function 13 resets the DMA to `0080h` inside ZSDOS (`zsdos.z80:1080`); staging would otherwise target a stale address | 13 |

Decisions recorded:

- Third-party tools that need the direct disk BIOS are dropped, starting with `DU2`; the rest stay only if they pass validation, and anything useful that fails is rewritten (section 11).
- The bank primitives `MOVE`, `XMOVE`, `SELMEM` and `SETBNK` join the device services in the Zephyr BDOS range (section 10).
- IM2 belongs to the BIOS. Programs register interrupt callbacks; they never load `I` or install vector tables (section 18).

Accuracy corrections carried into the text:

- Phase 1's OS body is 40 KiB (`2000h-BFFFh`), not 48 KiB. 48 KiB is Phase 2.
- The ZSDOS page-zero accesses verified in source are `0004h` (`zsdos.z80:619`), `0080h` (`:485`, `:1080`) and the two `RST 0`.
- Modes 00 and 01 need no change in either phase if the canonical bank-7 image is kept within `2000h-BFFFh` (section 7).
- ZSDOS locates the BIOS as `ZSDOS+0E00H` (`zsdos.z80:99`). That stays correct if the bank-7 BIOS jump table is placed immediately after ZSDOS, so ZSDOS needs no patch for it (section 12).

---

## 3. Why This Architecture

The 16 KiB common window exists because the BIOS, BDOS, drivers and their state had to stay visible while application banks were switched. Once the OS has a private bank, that requirement goes away:

1. The OS leaves the application's address space.
2. Common memory shrinks from 16 KiB to 8 KiB.
3. Every application bank regains `C000h-DFFFh` as distinct storage.
4. Most BIOS and driver state becomes private to bank 7.

```text
today      0000-BFFF   banked   48 KiB      C000-FFFF   common   16 KiB
final      0000-DFFF   banked   56 KiB      E000-FFFF   common    8 KiB
```

---

## 4. Physical SRAM Ownership

```text
Bank 0      base bank: CP/M's normal application bank, and the backing for common memory
Banks 1-6   application banks
Bank 7      OS bank
```

Bank 7 is never application memory. The bank primitives enforce it:

```text
SELMEM 0-6     accepted
SELMEM 7       rejected
SETBNK 7       rejected
XMOVE 7        system use only
```

All of bank 7 is reserved, although only `2000h-DFFFh` of it is visible in mode 11. Its low 8 KiB and top 8 KiB are unreachable in normal operation and remain reserved system storage.

---

## 5. Final Memory Map

### 5.1 Mode `10` — application execution

```text
0000-DFFF   application bank N      N = 0..6
E000-FFFF   physical bank 0
```

### 5.2 Mode `11` — OS execution

```text
0000-1FFF   application bank N      same N
2000-DFFF   physical bank 7
E000-FFFF   physical bank 0
```

The latch's bank bits keep the application's bank number while the OS runs. Entering and leaving the OS is a single change to `D3`:

```text
application bank 3        latch = 13h
enter OS                  latch = 1Bh
return                    latch = 13h, bank 3 reappears
```

The GAL substitutes bank 7 only for the switchable body, so the latch itself records which application bank is suspended. Nothing else has to remember it.

---

## 6. The Three Address Classes

### 6.1 Caller window — `0000h-1FFFh`

Mapped from the running program's bank in both modes. It carries CP/M's low-memory conventions:

```text
0000   warm-boot vector
0003   I/O byte
0004   drive/user byte
0005   BDOS vector
005C   default FCB 1
006C   default FCB 2
0080   default DMA and command tail
```

Keeping it on the program's bank means ZSDOS reads the real page zero while it runs, with no copies to keep synchronised. It also gives the default FCB and DMA — the common case — a path that needs no marshalling.

### 6.2 Switchable body — `2000h-DFFFh`

The application's bank in mode 10; bank 7 in mode 11. This is the OS's private body:

```text
Phase 1    2000-BFFF   40 KiB
Phase 2    2000-DFFF   48 KiB
```

Bank 7 holds ZSDOS, the BIOS implementation, drivers, OS and BIOS private stacks, private driver state, disk and search state, deferred-work queues, private buffers and system tables.

### 6.3 Common window — `E000h-FFFFh`

Physical bank 0 in both modes, for what must survive a mapping change. It is not all permanent system memory:

```text
E000-E3FF   program-owned reservation            1 KiB
E400-....   common TPA, and the CCP
....-FFFF   permanent system common
```

With the resident boundary near `F100h`:

```text
E000-E3FF   program-owned reservation
E400-F0FF   common TPA and CCP
F100-FFFF   permanent system common
```

**The `E000h-E3FFh` reservation** is for this tree's own programs that need code or data mapped in both modes: registered interrupt callbacks and their state, and bank-switch trampolines. A registered callback's entry must lie here (section 18). Programs do not install vector tables. The OS never uses the reservation.

It belongs to the running program and does not persist across a program exit: a transient's TPA includes it. Something that must outlive a program exit cannot live there without lowering `0006h` below `E000h`, which gives up the common TPA. Persistent residents are out of scope for this port.

---

## 7. Memory Modes

```text
D4 D3
 0  0    00   boot / ROM-visible
 0  1    01   shadow / load
 1  0    10   application execution
 1  1    11   OS execution
```

**Mode 00 and mode 01 do not change in either phase.** Mode 00 is reset and bootstrap. Mode 01 loads ROM images into SRAM by reading ROM at `0000h-BFFFh` and writing the selected bank, which is enough to load bank 7 **provided the canonical bank-7 image fits within `2000h-BFFFh`**.

That is a layout rule for the OS image, not a limitation: `C000h-DFFFh` of bank 7 is used in Phase 2 for zero-initialised runtime state — stacks, buffers, work areas — which needs clearing rather than loading. Keeping the image inside the range mode 01 already exposes means neither phase touches the reset or load equations.

Only modes 10 and 11 change: mode 11 in Phase 1, both in Phase 2.

---

## 8. Decoder Changes

The memory GAL already receives `A13`, `A14`, `A15`, `RAM_SHADOW` (`D3`), `ROM_DIS` (`D4`) and `BANK_Q0..2`, and it drives `RAM_A16..18` directly. The regions are within its decode granularity:

```text
LOW_8K      = !A15 & !A14 & !A13      ; 0000-1FFF
COMMON_8K   =  A15 &  A14 &  A13      ; E000-FFFF    (Phase 2)
SAFE_RAM    =  A15 &  A14             ; C000-FFFF    (Phase 1, existing)
```

Only `RAM_A16..18` change. `SRAM_CS` already selects SRAM for every read and write when `ROM_DIS` is set, and `ROM_CS` is already suppressed by `ROM_DIS`, so mode 11 needs no chip-select changes.

Bank selection in mode 11, conceptually:

```text
address in 0000-1FFF   ->  BANK_Q0..2
address in common      ->  bank 0
otherwise              ->  bank 7
```

and in mode 10:

```text
address in common      ->  bank 0
otherwise              ->  BANK_Q0..2
```

In Phase 2, "common" is `COMMON_8K` for modes 10 and 11 while mode 01 keeps `SAFE_RAM`, so the force-to-bank-0 term becomes mode-dependent.

These are conceptual equations. Compile and fit the WinCUPL source for the ATF22V10 before treating any of them as hardware logic.

---

## 9. The BDOS Facade

`CALL 5` enters a resident facade in common memory. It:

- saves the caller's SP and switches to the common transition stack
- dispatches Zephyr extension numbers itself, before ZSDOS sees them (section 10)
- stages caller objects that are not visible in mode 11 (section 13)
- enters mode 11 and calls ZSDOS, or a Zephyr service, in bank 7
- returns to mode 10, copies staged results back, restores SP, and returns

```text
APPLICATION                   mode 10, bank N
    | CALL 5
    v
COMMON FACADE                 E000-FFFF
    | save SP, common transition stack
    | stage arguments as required
    | enter mode 11
    v
BANK 7
    +---> ZSDOS
    +---> Zephyr service dispatcher
    v
BIOS / DRIVERS                bank 7
    v
COMMON EXIT
    | mode 10
    | unstage results
    | restore SP
    v
APPLICATION
```

**Not reentrant (F8).** The facade keeps the caller's state in single slots. Bank-7 code calls ZSDOS and the BIOS directly and never through `CALL 5`. Interrupt handlers never call BDOS.

**Interrupts (F9).** The facade has no interrupt policy. The BIOS owns IM2 (section 18): `I` is always the BIOS vector page and every entry in it reaches common code, so an interrupt is safe in mode 11 whatever the program is doing, and the facade leaves the caller's interrupt state alone. A debug build asserts on entry that `I` is still the BIOS page. A program that changes `I` is outside the supported interface.

Code that must disable interrupts for its own reasons — the IOC transport, bulk transfers — captures and restores the caller's state with the erratum-safe `LD A,I` retry, as the IOC transport now does in `cbios_iocall.asm` on `rom-services`, rather than forcing `EI` on exit.

---

## 10. Zephyr Services Become BDOS Extensions

Everything this tree's programs call at fixed extended-BIOS addresses moves behind `CALL 5`, together with the bank primitives and interrupt registration:

```text
devices            IOCALL   IOCBULK   IOCBULKW   VIDEO_SEND
bank primitives    MOVE     XMOVE     SELMEM     SETBNK
interrupts         REGISTER_ISR   UNREGISTER_ISR   program exit (section 18)
```

The bank primitives were CP/M 3 BIOS functions, but nothing here needs that ABI. Putting them in the same range leaves `CALL 5` as the single entry for everything except section 11's boot and console entries, and keeps the bank-7 checks of section 4 in one place.

**Function range.** ZSDOS handles functions 0-47 and 98-103 and returns immediately for anything else (`zsdos.z80:354-365`). The facade claims a Zephyr range — for example 200-239 — and dispatches it directly to bank 7, so ZSDOS is not modified. The range stays clear of ZSDOS's numbers and of CP/M 3's.

**Register convention.** BDOS convention passes the function in `C` and a parameter in `DE`. `IOCALL` needs two pointers, `IOCBULK` a pointer and a length, and `XMOVE` two banks, so the Zephyr range defines its own registers. Define them before retrofitting callers.

**Retrofit list.** These call the extended entries at fixed addresses today:

```text
../Utilities/src    hidkey  hidstat  ioc_bulk  ioc_diagchk  ioc_ping  ioc_reset
                    ioc_sdbench  ioc_sdblk  ioc_sdfmt  ioc_sd_read  ioc_sdrec
                    ioc_sdsoak  ioc_sdwrite  padstat
                    sdfs.inc  (used by sddir, sdget, sdput, sddel)
../HelloWorld/src   mandelbrot  mandelbrot_v9958  video_smiley  video_smiley_v9958
```

Any program using the bank primitives, such as banked song data in the tracker, joins the list when it lands.

Programs that install their own IM2 table move to registration when they are retrofitted: `../HelloWorld/src/ctctest_interrupts.asm:126`, `../VGMPlayer/src/vgmplay.asm:572`, `../SNTracker/src/tracker.asm:293` and `../SNTrackerTM2/SRC/CTCLOW.Z80:103`. The private-table procedure in `docs/ctc-and-real-time-programming.md` ("IM2 integration under CP/M") is replaced, and is rewritten in the application documentation pass.

`tools/check_ext_entries.py` on `rom-services` guards the fixed-address literals. Carry it forward only until the calls move to BDOS, then retire it.

---

## 11. Direct BIOS Entry

**Decision: the direct BIOS entry provides boot and console only.** Third-party tools that need the direct disk BIOS are dropped, and anything useful among them is rewritten against BDOS or the Zephyr extensions.

The common BIOS table keeps the standard CP/M 2.2 jump-table shape, so offsets such as `BIOS+6` stay valid, but only some entries are live:

```text
live     BOOT   WBOOT   CONST   CONIN   CONOUT
inert    LIST   PUNCH   READER  HOME    SELDSK   SETTRK   SETSEC   SETDMA
         READ   WRITE   LISTST  SECTRAN
```

Inert entries fail cleanly: `SELDSK` returns `HL = 0`, `READ` and `WRITE` return an error, `LISTST` reports not ready and `READER` returns `^Z`. A tool that tries them reports an error rather than crashing. BDOS list and punch output still work, because ZSDOS reaches the bank-7 BIOS directly.

**Why it is needed at all (F6).** ZCPR2 calls `BIOS+6` (CONST) and `BIOS+9` (CONIN) directly (`zcpr2/src/ZCPR2.ASM:691`, `:920-924`). Its `BIOS EQU` in `Z2HDR.LIB:96` is a literal `0DA00H` and must be generated to point at this table.

**Third-party tools on A:** (`tools/build_rom_disk.py`):

```text
DU2     sector editor; needs the direct disk BIOS           dropped
STAT    reads DPB and ALV through BDOS 27 and 31            kept, via section 22's copies
PIP  DUMP  CRC  MCOPY  NSWP    expected BDOS only           kept if they pass validation
ZSID    debugger; hooks page-zero vectors,
        may use BIOS console entries                        kept if it passes validation
```

Whatever fails validation is dropped or rewritten.

```text
APPLICATION
    +--- CALL 5 ----------------> BDOS facade -------> mode 11 --> ZSDOS / services --> BIOS
    |
    +--- BIOS boot, console ----> common BIOS entry --> mode 11 --> bank-7 BIOS console
```

ZSDOS, already in mode 11, calls the bank-7 BIOS directly; the common table serves only code running in mode 10.

---

## 12. ZSDOS Integration

### 12.1 Low memory

Verified accesses in `zsdos/src/zsdos.z80`:

```text
619    LD A,(RAMLOW+0004H)     drive/user byte
485    RAMLOW+80H              default DMA
1080   LD HL,RAMLOW+0080H      function 13 resets the DMA
487    RST 0                   warm boot
1026   RST 0                   warm boot
```

The caller window makes the first three refer to the running program's real memory, with no page-zero shadowing or synchronisation.

### 12.2 Warm boot is not safe through page zero (F1)

The two `RST 0` are the exception. In mode 11 they reach the program's `0000h` vector, which is correct only while that vector is still the system's `JP WBOOT`. If a program has replaced it, its handler runs **in mode 11**. That handler lives in `2000h-DFFFh`, which is bank 7 at that moment.

Replace both with a jump to a common helper that switches to the common stack, restores mode 10 and then jumps to `0000h`. A replaced vector then runs in application mode, as it would have on unmodified CP/M, and an untouched one reaches `WBOOT`.

The BIOS contains no `RST` instructions. With these two replaced, no code in bank 7 uses `RST`, and that stays an invariant.

### 12.3 BIOS linkage

ZSDOS computes its BIOS as `BIOS EQU ZSDOS+0E00H` (`zsdos.z80:99`). Place the bank-7 BIOS jump table immediately after ZSDOS and this is correct as written. The common BIOS entry of section 11 is a separate table.

### 12.4 Internal stack (F2)

ZSDOS switches to its own stack on entry (`zsdos.z80:341-343`):

```text
LD    (SPSAVE),SP
LD    SP,ZSDOSS
PUSH  IX
```

The stack is the region between `SPSAVE` (`:316`) and `ZSDOSS` (`:326`): about 56 bytes, most of it the copyright string. `IXSAVE` (`:325`) is its last two bytes, which is exactly where that first `PUSH IX` lands.

That placement is load-bearing. `DOSEXT0` restores the caller's IX by address rather than by popping it (`:1064-1065`):

```text
LD    SP,(SPSAVE)
LD    IX,(IXSAVE)       ; "Restore IX (stack is don't care)"
```

So the stack cannot be moved by changing `LD SP,ZSDOSS` alone. The first push would land somewhere else, and every BDOS call would return with IX holding the ASCII bytes `'er'`.

Grow the region in place instead: insert 128-256 bytes of storage between `SPSAVE` and the copyright text, keeping `IXSAVE` as the two bytes directly below `ZSDOSS`. That also stops the copyright string being overwritten.

Two knock-ons, both benign here:

- `BGRAMTOP EQU ZSDOSS` (`:328`) moves up, growing BackGrounder ii's high-RAM save size `BGHIL` (`:3245`). This matters only if BGii is used.
- `RAMINI` (`:467`) clears from `BGLORAM` up to `SPSAVE`, below the stack, and is unaffected.

With a 40-48 KiB private body there is no reason to keep the stock size. Measure the enlarged stack with the `STKCHK` fill, and shrink it later only if it matters.

### 12.5 `CCPBUF`

`CCPBUF`'s command-processor range test must be derived from `CBASE`. `rom-services` has this as `CCPLO`/`CCPHI` generated by `tools/gen_zsdos_bios.py`; carry it forward.

---

## 13. Pointer Visibility and Marshalling

In mode 11, a caller range is:

```text
directly visible    wholly inside 0000-1FFF, or wholly inside the common window
hidden              touching the switchable body
```

Decide on the whole range, not the starting address. Hidden objects go through the common workspace, an explicit crossing helper, or chunked transfer.

The facade uses a per-function table:

```text
FCB_IN   FCB_OUT   DMA_IN   DMA_OUT   SPECIAL   RETURNS_POINTER
```

```text
OPEN            FCB_IN + FCB_OUT
CLOSE           FCB_IN + FCB_OUT
READ SEQ        FCB_IN + FCB_OUT + DMA_OUT
WRITE SEQ       FCB_IN + FCB_OUT + DMA_IN
SETDMA          SPECIAL
PRINT STRING    SPECIAL
READ CONSOLE    SPECIAL          buffer up to 257 bytes
```

**DMA tracking (F10).** The facade holds the program's real DMA address. `SETDMA` sets it, and so does function 13, which resets it to `0080h` inside ZSDOS (`zsdos.z80:1080`).

**Forced staging.** The conditional path — staging only when a range is hidden — rarely runs, because most programs use the page-zero FCB and DMA. Build an option that stages every eligible call, and run the stress programs with it before enabling conditional staging.

---

## 14. Bulk Transfers (F4)

IOC bulk transfers **do not** cross the mapping mid-transfer. The bulk lane loses its first byte, is bound to the SIO Tx underrun latch, and runs in persistent sync, and a mapping change between chunks can underrun the transmitter.

`IOC_BULK_MAX_LEN` is 512 (`src/cbios_defs.inc:318`). Either:

- size the common transfer workspace to 512 bytes, so a bulk payload is one crossing; or
- keep the `OUTI`/`INI` byte loops in common and run them in mode 10, where the caller's buffer is simply its own memory.

Chunked crossings remain the general mechanism for future services without timing constraints, implemented once rather than per driver.

---

## 15. Stacks

**Never change the mode while SP points into memory that will disappear.**

Entry: save the caller's SP, switch to the common transition stack, enter mode 11, and then switch to a private bank-7 stack if wanted. Exit: return to common code, switch back to the common stack, restore mode 10, restore the caller's SP, return. `WBOOT`, fatal errors and every crossing helper follow the same rule.

**The interrupt return address lands first.** A maskable interrupt or NMI pushes the interrupted PC onto the current stack before the handler's first instruction runs. No handler can avoid those two bytes; it can only move everything that follows. So:

- every ISR switches to the common ISR stack as its first action, so its own pushes and calls never land on the interrupted stack (F2)
- every stack that runs with interrupts enabled keeps two bytes of headroom beyond its measured depth: the transition stack, ZSDOS's stack, the BIOS private stacks, and whatever stack a program runs on in mode 10
- ZSDOS gets a real stack (section 12.4), because its stock 56 bytes leaves no meaningful headroom

The ISR-stack switch uses a single saved-SP slot. The SIO handler and the CTC dispatcher run with interrupts disabled until their closing `EI` / `RETI`, and registered callbacks never enable them, so the slot is never reentered. An NMI source, if the board uses one, needs its own arrangement.

Measure every one of these stacks with the `STKCHK` fill from `rom-services`.

---

## 16. Mode Changes and the Existing Latch Writers

**The instruction that changes the mapping, and everything that must run immediately after it, executes from common memory.** After `OUT (00h)`, the next fetch comes from whatever the new mapping presents at that address.

**F3.** These existing routines restore the latch with a hardcoded mode 10:

```text
src/cbios_bank_select.asm:22       bank helpers
src/cbios_storage_rom.asm:176      drive A read
src/cbios_storage_sd.asm:217       SD record staging
src/cbios_bank.asm:45,139,150,171  SELMEM, SETBNK, MOVE, XMOVE
src/cbios_storage_ramdisk.asm:284  not linked
src/cbios_storage_vdrip.asm:364    not linked
```

Moved into bank 7 unchanged, each switches the lower address space away from the code executing it. They become crossing helpers in common that restore the mode bits they found, and `CURRENT_BANK` keeps the meaning in section 24.

The drive A read also does `DI` ... `EI` unconditionally, enabling interrupts for a caller that had them disabled. Fix it in the same pass.

---

## 17. BIOS and Driver Placement

The BIOS implementation, drivers and their private state live in bank 7, and OS-internal execution is ordinary calls in one address space:

```text
ZSDOS -> BIOS -> driver
```

Only state that must be visible across the mapping or from interrupt context stays common.

---

## 18. Interrupts: The BIOS Owns IM2

IM2 belongs to the BIOS. Programs request interrupt service; they do not install vector tables. CP/M 2.2 had no answer for interrupt-driven programs and CP/M 3 left interrupts inside the BIOS, but this machine's programs need timer interrupts that keep running during OS calls.

### 18.1 The BIOS interrupt path

All of it is common, because interrupts arrive in both modes:

- the IM2 vector page
- the SIO handler, the CTC dispatcher, and every stub the vector page points at
- the ISR registration slots
- RX sinks called from interrupt context, and every routine a sink calls
- ring and queue indexes and metadata
- handler-local state
- the common ISR stack (F2)

Payload buffers need not be common if the handler records minimal state and defers the work.

### 18.2 The vector page (F9)

`I` is loaded at cold boot, reloaded by `WBOOT`, and never otherwise changes. It always selects the BIOS vector page.

IM2 forms the table address as `I × 100h + vector`, so the page starts at a page boundary in permanent common memory. It is a full 256 bytes, and every entry leads somewhere safe:

```text
00h-06h      CTC channels 0-3     CTC dispatch stubs
10h-1Eh      SIO0                 BIOS SIO handler (10h is live; the rest
                                  cover status-affects-vector)
all others                        unexpected-interrupt stub: EI, RETI
```

Today's table is a single two-byte entry (`src/cbios_defs.inc:918-929`). The full page costs 256 bytes of common memory and makes any vector an unprogrammed or future device supplies harmless, which VGMPLAY's private table already found necessary. `CBIOS_IM2_VECTOR_PAGE` is regenerated with the layout.

The BIOS programs the CTC vector base and SIO0 `WR2` at cold boot and in `WBOOT`. Programs never write the CTC vector word.

### 18.3 Registration

A program that wants an interrupt registers a callback through the Zephyr BDOS range (section 10):

```text
REGISTER_ISR      source, callback address
UNREGISTER_ISR    source
```

Registration rejects the call unless:

- the source is registerable. In Phase 1 that is CTC channels 0-3. SIO0/B and SIO1 belong to the BIOS. SIO0/A delivers the same vector as SIO0/B while status-affects-vector is off, so it becomes registerable only if the SIO handler learns to dispatch by channel.
- the source is not already registered
- the callback entry lies within `E000h-E3FFh`

It writes the slot with interrupts disabled. The program then sets the channel's mode and time constant with its interrupt enabled, through the CTC ports as it does today, and stops the channel before unregistering.

### 18.4 Dispatch

```text
interrupt, in mode 10 or 11
    -> BIOS vector page -> CTC channel n stub
    -> common dispatcher
         switch to the common ISR stack, save AF BC DE HL
         slot n empty:    reset channel n
         otherwise:       CALL the callback
         restore registers and SP
         EI
         RETI
```

A channel enabled without a registration is shut off on its first interrupt instead of crashing, which also makes a program's unregister order forgiving.

**`EI` before `RETI` is required.** Accepting a maskable interrupt clears both IFF1 and IFF2, so a handler that ends in a plain `RETI` returns with interrupts disabled. `EI`'s one-instruction delay keeps the `RETI` from nesting. The current `sio_core_isr` in `src/sio_core.asm` ends in a plain `RETI`, and interrupts come back only when foreground code runs `EI`; fix it when the handler moves.

### 18.5 Callback contract

```text
location      entry, code, callees and state all within E000h-E3FFh
mapping       runs in mode 10 or mode 11; touches no memory below E000h
stack         the common ISR stack, with a fixed budget (for example 32 bytes)
registers     AF BC DE HL are free; IX, IY and the alternate set are preserved
interrupts    disabled throughout; never EI
return        RET, not RETI
never         BDOS, the BIOS, latch writes, waiting on a port
```

The caller window is also visible in both modes, but `SELMEM` changes what it holds, so callbacks are limited to the reservation. Registration validates only the entry address. The rest is the program's responsibility, and is checked in validation (section 27).

Keep callbacks to the count-and-return pattern. The CTC sits above SIO0 in the daisy chain (`IEI -> CTC -> SIO0 -> SIO1`), so a long callback delays console receive.

### 18.6 Lifetime (F5)

Registrations belong to the running program, and are cleared:

- by `WBOOT`
- when a transient returns to ZCPR2 without warm booting. `CALL TPA` falls through to `DEFDMA`, `DLOGIN` and `CONT` (`zcpr2/src/ZCPR2.ASM:2143-2146`), so ZCPR2 calls the program-exit extension there. `GO` and `JUMP` reach the same `CALL`.

Clearing disables interrupts, resets every registered CTC channel, empties the slots, and restores the interrupt state. Without it, a callback left registered vectors into a reservation the next program overwrites.

### 18.7 What the facade no longer needs

Every vector entry reaches common code, so interrupts stay as the caller had them across OS calls (section 9). There is no BDOS-safe declaration and no disable-by-default. A program that loads `I` or changes interrupt mode is outside the supported interface. A debug build asserts `I` on facade entry.

---

## 19. Warm Boot and Recovery

Warm boot arrives either from a program jumping to `0000h` in mode 10, or from ZSDOS through the common helper of section 12.2 (F1), which has already restored mode 10.

`WBOOT` trusts nothing about the dying context — not the mode, SP, bank, DMA, or partly completed driver work. It:

1. runs from common code on a known common stack
2. forces mode 10
3. selects bank 0
4. **reloads `I` with the BIOS vector page, resets the CTC, and reprograms the CTC and SIO vectors (F5)**
5. **reinitialises facade and crossing state and clears ISR registrations (F5)**
6. repairs page zero
7. reloads the CCP
8. reinstalls bank 7 only if policy requires it
9. enters the command processor

A transient that returns to ZCPR2 does not pass through `WBOOT`; section 18.6's program-exit call covers that path.

Bank 7 can always be rebuilt from ROM. Whether every warm boot reinstalls it is a policy decision, because doing so discards ZSDOS state that may be meant to persist.

---

## 20. ROM Policy

ROM holds reset and bootstrap code, the canonical bank-0 and bank-7 images, recovery firmware, diagnostics, and immutable fonts, tables and resources. Runtime execution happens from SRAM. The ROM-service gate and page-4 execution are retired.

What carries forward from the ROM work is the discipline, not the mechanism: separating code from state, generated addresses, `RES_`-style classification, interrupt-path audits, reentrancy rules, and restoring the latch mode that was found.

---

## 21. State Placement

Classify every BIOS, driver and ZSDOS support object as one of:

```text
COMMON REQUIRED
SYSTEM BANK 7
APPLICATION / TPA
CAN BE STAGED
ROM / IMMUTABLE
```

Must it be visible:

```text
1  in application mode?
2  in OS mode?
3  when an interrupt arrives?
4  while a program holds a pointer to it?
5  while a crossing helper runs?
```

Only 2: bank 7. Immutable: ROM. Crosses an interface only transiently: stage it. Common memory is only for objects that genuinely need cross-mode or asynchronous visibility.

---

## 22. Returned Pointers (F7)

A pointer returned to a program must stay valid in mode 10, so it cannot point into bank 7.

With the direct disk BIOS inert (section 11), no program can obtain a DPH, and the DPH, DPBs, allocation vectors, checksum vectors and directory buffer all live privately in bank 7.

That leaves BDOS functions 27 and 31, which return the address of the current drive's ALV and DPB. The facade copies them into common memory on the call and returns the copy's address:

```text
function 31    DPB copy     15 bytes
function 27    ALV copy     up to 256 bytes on the current SD geometry
```

Keep the two copies in separate areas, so a program that calls 27 and then 31 does not find its ALV overwritten. Each copy is a snapshot taken at the call, which is what `STAT` needs to report free space.

---

## 23. Common Memory: Contents and Budget

Permanent common contents:

```text
BDOS facade and exit                     direct BIOS entry: boot, console
mode and bank crossing helpers           WBOOT and recovery entry
transition stack and ISR stack           transfer workspace
cross-context state                      BIOS interrupt path
DPB and ALV copies for functions 27 and 31
```

Rough budget, **to be replaced by measurement of the built image**:

```text
DPB and ALV copies                                        ~275
BIOS interrupt path, queues, CTC dispatcher, ISR slots    ~400
IM2 vector page                                            256
BDOS facade, BIOS entry, crossing helpers, WBOOT          ~400
transition stack and ISR stack                            ~200
transfer workspace, bulk-sized                             512
cross-context state                                       ~100
                                                        ------
                                                        ~2,150
```

Against `F100h-FFFFh` (3,840 bytes) that leaves roughly 1,700 bytes. Dropping the direct disk BIOS is what moved the disk structures, about 1,000-1,250 bytes, into bank 7. Earlier estimates in this project were wrong in both directions, so the final `FBASE` comes from the linked binary, and the margin may allow a higher one.

The hardware common window is 8,192 bytes, and the program reservation takes 1,024 of it.

---

## 24. `CURRENT_BANK`

`CURRENT_BANK` means the running or suspended **application** bank. It does not mean the physical bank executing below `E000h`:

```text
mode 11:   CURRENT_BANK = N        physical body = bank 7
```

Entering the OS does not change which application bank is current.

---

## 25. Migration Plan

Don't combine moving the OS with shrinking common memory.

### Phase 0 — Baseline (done)

`banked-os` is created at `3e0854a`: the RAM-executed BIOS with ZSDOS and ZCPR2, before any ROM-overlay work.

The baseline builds from a clean tree with `make CCP=zcpr2 BDOS=zsdos`, using the vendored RunCPM, since the baseline scripts expect an emulator on `PATH`. Nothing else is changed. Image: `build/zephyr80-zcpr2-zsdos.bin`, sha256 `460c0c12…6a57`.

Confirmed on hardware: it boots, and SC2 and a TM2 build work.

Correction: that build was not fully clean. The CPM2.2 Makefile packed whatever was in `../Utilities/build` without rebuilding it, so A: carried SDDIR, SDGET, PING and SDREAD from `rom-services`, calling `IOCALL` at `E23Fh`. They failed with transport error kind 01. The ROM build now runs the Utilities and Monitor builds itself, and `make clean` cleans them.

Carry the rest forward from `rom-services` as each becomes relevant. They are independent of ROM execution:

| Change | Files on `rom-services` |
|---|---|
| Vendored RunCPM — **Phase 0** | `tools/runcpm/`, Makefile wiring |
| ROM-disk profile as a make dependency | Makefile |
| L80 link origin derived from `ORG` | `zsdos/build-zsdos.sh` |
| `CBASE_ADDR` derived from `MEM` | Makefile |
| `CCPBUF` range derived from `CBASE` | `tools/gen_zsdos_bios.py`, `zsdos/src/zsdos.z80` |
| Self-locating SYSID | `../Utilities/src/sysid.asm` |
| Stack probe and `STKCHK` — revert to three stacks | `src/boot_shadow_copy.asm`, `src/sio_core.asm`, `src/cbios_defs.inc`, `../Utilities/src/stkchk.asm` |
| IOC transport interrupt-state capture | `src/cbios_iocall.asm`, `src/cbios_ioc_command.asm` |
| Extended-entry literal check, until section 10 | `tools/check_ext_entries.py` |
| Documentation edits | `docs/ctc-and-real-time-programming.md`, `docs/zephyr80_bios_walkthrough.md` |

### Phase 1 — OS in bank 7, common window unchanged

Mode 11 in this phase:

```text
0000-1FFF   application bank N
2000-BFFF   bank 7
C000-FFFF   bank 0
```

Work:

1. **Done.** Decoder: mode 11 as above. `RAM_A16..18` only; modes 00, 01 and 10 unchanged. `MEM_DECODER.pld` revision 10. The WinCUPL expanded terms were checked against revision 09 for all 2,048 input combinations: only the address lines in mode 11 at `2000h-BFFFh` differ. Each address line uses 6 of its 10 product terms, which leaves room for Phase 2's common term.
2. **Done.** Hardware validation, Phase 1 (section 26): `MAP11.COM` (`../Utilities/src/map11.asm`) passes on hardware for application banks 0 and 5.
3. **Done.** Common crossing layer, `src/cbios_xing.asm`:
   - `xing_isr` is the SIO IM2 entry. It saves the interrupted SP at `FE80h`, runs the handler on its own stack below `FEC0h`, and ends `EI` / `RETI`.
   - The ISR stack is the lower half of the transport's old 128-byte run. The handler used to end in a bare `RETI`, which left interrupts disabled until foreground code next ran `EI`.
   - `xing_select_ram_bank` selects a bank while keeping mode 10 or mode 11.
   - **Deviation:** the layer sits in the core-BIOS gap at `DF2Ch`, not at or above `E000h`, because `E000h-FFFFh` is full until the BIOS leaves common memory in step 7. It moves then.
   - **Deviation:** the transition stack comes with the facade in step 8, in the freed BDOS area.
   - To make room, `ccp_clear_redraw` moved from core BIOS to `ECD0h` in slot 3, and banking now starts at `DBDDh`.
4. **Done.** Latch writers (F3):
   - **Converted:** SD record staging (`sd_select_bank`); the drive A read, which now restores the latch and the interrupt state it found instead of forcing mode 10 and `EI`; `SELMEM`, which keeps mode 11; and cross-bank `MOVE`, which copies in mode 10 from common memory and restores the latch it found.
   - **Left forcing mode 10, by design:** cold boot's `bank_select_internal`, `WBOOT`'s entry, `restore_ccp_from_rom`, the font restore (warm boot only) and the boot shadow copy. These run only where section 19 says to force mode 10.
   - **Unchanged because not linked:** the RAM-disk and VDrip storage backends.
5. **Done.** `SELMEM`, `SETBNK` and `XMOVE` refuse bank 7 with `A = FFh` and return `A = 00h` on success. A refused `XMOVE` leaves an earlier one armed.
   - Validation is `XING.COM` (`../Utilities/src/xing.asm`), which passes on hardware along with boot, drives A-C, SC2, TM2, SDDIR and SERCON: bank-7 refusal; `SELMEM` and `MOVE` in both modes; drive A and B reads in mode 11 matching mode 10; and the drive A read preserving interrupts off and on.
6. **Done.** ZSDOS is linked at `2000h` in bank 7 (`zsdos/build-zsdos.sh`: `ORG` `2000h`, `SIZE` `1000h`) and calls its BIOS as `ZSDOS+1000H`, where the firmware assembles ZSDOS's BIOS table. The table used to be at `+0E00H`; the grown stack moved it up, and the `0DF1H`/`0DF9H` size checks and internal-path `ORG`s moved with it.
   - The live `RST 0` (in `ERROR5`) and the one in the unassembled ROM path are both `JP WBTRAP` (F1). `tools/gen_zsdos_bios.py` generates `WBTRAP` from the map.
   - The stack grew in place by 192 bytes between `SPSAVE` and the copyright text, so `IXSAVE` is still the two bytes directly below `ZSDOSS` (F2).
   - **Deviation:** `CCPBUF` keeps its `0C4H`/`0CCH` literals, which stay correct while the CCP is at `C400h`. Derive the range when Phase 2 moves `CBASE`.
7. **Done.** The BIOS and drivers are in bank 7 (see "Banked OS layout" in `src/cbios_defs.inc`):
   - console dispatch, the V9958 console and its font, HID input, the IOC transport, `VIDEO_SEND`
   - the storage stubs, the SD and ROM-disk backends, and every DPH, DPB and allocation vector, plus the directory buffer

   How it is built and what stayed common:
   - **One assembly, two outputs.** `tools/split_banked_image.py` cuts the link into ROM page 0 and a bank 7 payload in ROM page 7, which the existing cold-boot copy loads. The ROM image is 512 KiB.
   - **Common interrupt path.** The SIO core and serial console stay common. So do the IM2 page at `FD00h` (CTC `00h`-`06h`, SIO `10h`-`1Eh`, every other entry `EI`/`RETI`), the CTC dispatcher and registration slots (`src/cbios_irq.asm`) and the ISR stack. Every handler switches stacks first and ends `EI`/`RETI`.
   - **Drive A:** its shadow/copy window runs from common memory (`xing_rom_copy_record`). The destination bank comes from the DMA address as mode 11 sees it. SD record copies need no bank selection.
   - **Stock CP/M removed.** `cpm22.asm`'s CCP and BDOS are no longer assembled. `ccp_clear_redraw` and `ccp_read_up_sequence`, which served only the stock BDOS, are gone, and warm boot no longer restores the font from ROM.
   - **Boot check.** Boot checks a signature in bank 7 (`bank7_check`) before calling into it, and reports over SIO0/B if the signature is missing.
   - **Deviation:** the BIOS private stacks, `MOVE_BUFFER` and the runtime state stay in common memory through Phase 1. Phase 2 moves what it must.
   - **Deviation:** `docs/memory-map.md` and `docs/symbol-map.md` are no longer regenerated, because `tools/generate_memory_docs.py` validates the fixed-slot layout. Until the tool is rewritten, `check_overlap.py` and the assembler region checks guard the layout.
8. **Done.** BDOS facade, `src/cbios_facade.asm`, at `CC00h` (`FBASE` `CC06h`):
   - per-function argument flags for functions 0-48 and 98-103
   - staging buffers at `D400h-D9FFh`
   - DMA tracking that follows function 13 (F10); ZSDOS's DMA is set lazily, on the next call that uses it
   - single-slot, non-reentrant state (F8)
   - the interrupt state left alone (F9)
   - functions 27 and 31 copying into common memory (F7)

   The build forces staging (`FACADE_FORCE_STAGE = 1`), except for function 10: ZSDOS tells the CCP's own line input apart by the buffer's address.
   - **Deviation:** no debug assertion on `I` yet.
9. **Done.** The common table at `DA00h` has boot and console live, and the disk and auxiliary entries inert (F6). ZCPR2 calls function 202 after `CALL TPA` (F5).
   - **Deviation:** ZCPR2's `BIOS EQU` stays a literal, because the table did not move in Phase 1. Generate it when Phase 2 moves the table.
10. **Done.** Zephyr BDOS functions:
    - 200 `REGISTER_ISR`: `B` = CTC channel, `DE` = callback in `E000h-E3FFh`
    - 201 `UNREGISTER_ISR`: `B` = CTC channel
    - 202 `PROGRAM_EXIT`
    - 210-217: the eight extended entries, called through a seven-byte register block at `DE` (`A`, `C`, `B`, `E`, `D`, `L`, `H`)

    Bulk transfers are staged through a 512-byte common buffer, so no transfer crosses the mapping (F4).
    - **Deviation:** the fixed extended table at `DA33h` stays live as staging gates, so this tree's utilities work unchanged. They are retrofitted to functions 210-217 when Phase 2 moves the table.
11. **Done.** `WBOOT` runs in mode 11 on bank 0. It resets the CTC and its vector, clears registrations and restores the CCP through a mode-00 window, then returns to mode 10 for the CCP (F5). Bank 7 is not reinstalled on warm boot.
12. **Done**, as part of steps 7 and 8.
13. **Done.** `DU2` is dropped from A:. The other third-party tools are checked in step 14.
14. **Done.** On hardware: cold and warm boot, `DIR` on A:-C:, `^R`/`^L`, `SYSID`, `BANKOS.COM` from B: (PASS), SD utilities, SC2, a TM2 build, WordStar, PIP, STAT, SERCON and `MAP11` all pass. `BANKOS.COM` (`../Utilities/src/bankos.asm`) automates section 27's tests 3, 5 and 6, and the file I/O part of test 8. The rest, including the third-party tools, is run by hand.

At the end of Phase 1 the OS is out of the application's body.

### Phase 2 — Common window to `E000h-FFFFh` (required)

1. **Done.** `MEM_DECODER.pld` revision 11: common is `E000h-FFFFh` in modes 10 and 11, and the OS body is `2000h-DFFFh`. The WinCUPL product terms match this map for all 2,048 inputs; the chip selects are unchanged from revision 10. Each address line uses 8 of its 10 terms.
2. **Done.** Modes 00 and 01 decode exactly as in revision 10: shadow/copy still forces `C000h-FFFFh` to bank 0. The bank 7 image ends at `883Fh`, and `tools/split_banked_image.py` refuses any byte assembled into `C000h-DFFFh`.
3. **Done.** Boot review. Boot and `WBOOT` set mode 11 before loading the bank-7 stack, and switch to a common stack before the final switch to mode 10. `restore_ccp_from_rom` does no stack operation between its two latch writes.
   - **Found:** drive A:'s shadow/copy window popped its saved latch from the stack while the window was open. With the storage stack in `C000h-DFFFh`, mode 01 maps that stack to bank 0, so `xing_rom_copy_record` now keeps the saved latch and interrupt state in common variables.
   - **Found:** a DMA in `C000h-DFFFh` cannot take a shadow/copy write, so the ROM-disk read refuses one. Nothing the OS reads into lives there.
4. **Done.** Bank 7's `C000h-DFFFh` holds the BIOS private stacks (`C100h`, `C200h`, `C300h`) and the SD scratch buffer. Nothing there is loaded or initialised.
   - The ISR, gate and facade stacks stay common, at `FE80h-FF5Fh`.
   - Cross-bank `MOVE` uses the common staging buffer.
5. **Done.** `CBASE` is `E400h`, `FBASE` is `EC06h` and `CBIOS_BASE` is `F000h`; `TPA` is `0100h-EC05h`. Common memory holds 3,491 bytes plus the CCP in `E000h-FFFFh`, with `E000h-E3FFh` left for program interrupt callbacks.
   - **Common layout:** the facade is at `EC00h`; boot, banking, the diag record, the SIO core, the crossing layer, gates, interrupt dispatch and the serial console are at `F000h-F952h`. The staging buffer and pointer copies are at `F958h-FC97h`, and the IM2 page is at `FD00h`.
   - **Found after the hardware pass:** the staging buffer first started at `F950h`, three bytes inside the serial console's 8-byte receive ring (`F94Bh-F952h`). The serial console region had no declared limit, so nothing checked it. With the serial console armed, a received byte stored from interrupt context could corrupt a record the facade was staging. The staging buffer and the facade copies now start 8 bytes higher, `CBIOS_SERCON_CODE_LIMIT` bounds the region with an assembler check, and the regenerated memory map validates every common region against its limit.
   - **Staging buffers:** the facade's short-lived staging shares one 512-byte buffer.
   - **Generated addresses:** ZCPR2's `CPRLOC` and `BIOS EQU` are generated from `CBASE` and `CBIOS_BASE` (`zcpr2/build-zcpr2.sh`), and ZSDOS's `CCPBUF` range comes from `CBASE` (`CCPLO`/`CCPHI`, `tools/gen_zsdos_bios.py`). This closes Phase 1's deviations for steps 6 and 9.
   - **Build fix:** the generated ZSDOS `MACLIB` now ends in Ctrl-Z. Without it, ZMAC read the padding in the file's last record as source once the file grew.
   - **Retrofit:** nothing is published at a fixed address any more.
     - Zephyr BDOS function 203 returns a system information block: transport level, IOC diag record, serial console flags, BIOS table and extension table.
     - `../Utilities/src/zbdos.inc` gives tools `IOCALL`, `IOCBULK`, `IOCBULKW` and `VIDEO_SEND` under their old names through functions 214-217, plus `MOVE`, `XMOVE`, `SELMEM` and pointers from function 203.
     - Retrofitted: every utility, including `SYSID`, `SERCON` and `SDSOAK`; the Monitor, whose `APP` command is retired; and the four HelloWorld video demos. `SDSOAK` now registers its interrupt load as a callback.
     - This closes Phase 1's step 10 deviation.
6. **Done.** On hardware, with decoder revision 11: cold and warm boot, `DIR` on A:-C:, `^R`/`^L`, `SYSID`, `MAP11` (PASS), `BANKOS.COM` from B: (PASS), SD utilities, SERCON, the Monitor, SC2, WordStar, PIP and STAT all pass. TM2 was run as a memory-pressure check only, against an unmaintained source tree on the SD card: linking inside the TM2 environment still runs out of memory, and the standalone `TLINK` gets further and stops at the linker's own "Internal 2" check. Neither is taken as an OS result; the PC build links the maintained sources at the same `EC06h` BDOS entry (RunCPM 60K).
   - Section 26, with `MAP11.COM` rewritten for this map. It checks mode 10's `C800h`/`DFFFh` as application memory, mode 11's `2000h-DFFFh` as bank 7, and `E000h` as common, and it saves and restores every byte it probes in the running OS's bank. `BANKOS.COM` now works in the `E000h` reservation, and uses a DMA at `C800h` to exercise the newly hidden range.
7. **Done, from the binary:** 3,491 bytes of common memory besides the CCP. The facade region has 110 bytes free, the gates 11, interrupt dispatch 15, and the SIO core 7. `FC90h-FCFFh` and `FF60h-FFFFh` are unallocated.

---

## 26. Hardware Validation

Fill each region with a distinctive signature before any OS integration, and test reads and writes at every boundary.

### Phase 1

```text
mode 10:    0000-BFFF   app bank        C000-FFFF   bank 0
mode 11:    0000-1FFF   same app bank   2000-BFFF   bank 7      C000-FFFF   same bank 0
```

Boundaries: `1FFFh`/`2000h` and `BFFFh`/`C000h`.

**Passed** with `MAP11.COM` for application banks 0 and 5. The program runs its mapping walk from `C000h` with interrupts disabled. For each bank it checks:

- mode-11 reads at `1FFFh` (app bank), `2000h`, `8000h` and `BFFFh` (bank 7), and `C000h` (bank 0)
- the latch readback in both modes
- that mode-11 writes land in the app bank at `1FFEh`, in bank 7 at `2000h`, and in common memory
- that the app bank's body is untouched by mode-11 writes

Two tooling notes from this step:

- `make` in `Code/HDL/WinCUPL` now builds the JED on Linux, running WinCUPL under Wine. The build script used to exec `cupl.exe` directly, which failed with "Exec format error".
- MAME is out of scope for this port. The emulator is on hold until the machine is stable, and validation is on hardware.

### Phase 2

```text
mode 10:    0000-DFFF   app bank        E000-FFFF   bank 0
mode 11:    0000-1FFF   same app bank   2000-DFFF   bank 7      E000-FFFF   bank 0
```

Boundaries: `1FFFh`/`2000h` and `DFFFh`/`E000h`.

In both phases, return to mode 10 and confirm the application bank's contents are unchanged. Repeat with an application bank other than 0.

---

## 27. Software Validation

1. **Transition.** A program calls a common gate that saves SP, switches to the common stack, enters mode 11, checks the caller's page zero, calls a trivial bank-7 routine, returns, restores mode 10 and SP, and returns to the program.
2. **Warm boot (F1).** Force a ZSDOS fatal error and confirm it reaches `WBOOT` in mode 10. Repeat with a program that has replaced the `JP` at `0000h`, and confirm its handler runs in mode 10.
3. **IX across BDOS calls (F2).** Load a distinctive value into IX, call a spread of BDOS functions, and confirm IX returns unchanged each time. This is the test that catches a ZSDOS stack change that lost `IXSAVE`.
4. **Interrupts during OS work (F2).** Drive serial input during disk-heavy work, confirm ZSDOS's saved SP survives, and measure every stack with the `STKCHK` fill.
5. **Program interrupts (F5, F9).** Register a CTC tick callback in the reservation and confirm ticks keep counting through a long disk copy, and that console input keeps working while they run. Confirm registration rejects a callback outside `E000h-E3FFh`, a BIOS-owned source, and a second registration of the same channel. Enable a CTC channel's interrupt without registering and confirm the stub shuts it off. Leave a registration in place and exit, once by `RET` to ZCPR2 and once by warm boot, and confirm the slot is empty and the channel stopped each time.
6. **Page zero from another bank.** Call BDOS with an application bank other than 0 selected and confirm `0004h` and the default DMA are that bank's.
7. **Bulk (F4).** Run the IOC bulk tools with buffers placed in the switchable body.
8. **Forced staging.** With every eligible call staged, run a TM2 build, WordStar, disk copies and the tracker. Then enable conditional staging and run them again.
9. **Third-party tools.** Run `PIP`, `STAT`, `ZSID`, `DUMP`, `NSWP`, `MCOPY` and `CRC`, and drop or rewrite whatever fails.

Enable the full ZSDOS path only after 1, 2 and 3 are reliable.

---

## 28. Invariants

| Invariant | Rule |
|---|---|
| Bank ownership | Banks 0-6 are application banks; bank 7 is the OS's |
| Caller window | `0000h-1FFFh` is the application bank in modes 10 and 11 |
| Common window | `E000h-FFFFh` (Phase 1: `C000h-FFFFh`) is physical bank 0 in modes 10 and 11 |
| OS body | `2000h-DFFFh` (Phase 1: `2000h-BFFFh`) is bank 7 only in mode 11 |
| Bank identity | The latch bank bits keep the application bank in mode 11 |
| Mapping changes | Execute from common memory, with SP in common memory |
| Latch writes | Restore the mode bits that were found; never assume mode 10 |
| Reentrancy | The facade is not reentrant; bank 7 never calls `CALL 5`; ISRs never call BDOS |
| Interrupt stack | Every ISR switches to the common ISR stack as its first action |
| Stack headroom | Every stack that runs with interrupts enabled keeps two bytes beyond its measured depth |
| ZSDOS stack | `IXSAVE` is the two bytes directly below `ZSDOSS` |
| BIOS interrupt path | Wholly common |
| IM2 ownership | `I` is always the BIOS vector page, and every entry in it reaches common BIOS code; programs never load `I` |
| Program interrupts | Registered callbacks only, entry within `E000h-E3FFh`; cleared by `WBOOT` and on return to ZCPR2 |
| Interrupt return | Every handler ends `EI` / `RETI`; callbacks end `RET` and never enable interrupts |
| Direct BIOS | Boot and console entries only; disk entries inert |
| Returned pointers | Never point into bank 7; functions 27 and 31 return common copies |
| Warm boot | Reaches `0000h` only after mode 10 is restored; no `RST` in bank-7 code |
| Private state | Anything needed only in OS mode lives in bank 7 |
| OS image | The canonical bank-7 image fits within `2000h-BFFFh` |
| ROM | Storage and recovery, never the runtime execution environment |

---

## 29. Foot-Guns

- **Self-unmapping code:** changing the mode while executing from a region that changes redirects the next fetch into another bank.
- **Self-unmapping stack:** changing the mode with SP in a changing region corrupts `RET`, `CALL`, `PUSH`, `POP` and interrupts.
- **Hardcoded mode restores (F3):** existing BIOS latch writes restore mode 10 and unmap bank-7 callers.
- **Warm boot through a replaced vector (F1):** `RST 0` in mode 11 runs the replacement in the wrong mode.
- **Moving ZSDOS's stack by its `LD SP` alone (F2):** the first `PUSH IX` misses `IXSAVE`, and every BDOS call returns with IX corrupted.
- **The interrupt return address (F2):** two bytes always land on the interrupted stack, whatever the handler does first.
- **Program-installed vector tables (F9):** `I` locates the table, not the handlers; a table in common can still vector into the switchable body.
- **Callback reach:** registration validates only the entry; a callback that calls or touches anything below `E000h` fails in mode 11.
- **Stale registrations (F5):** a transient that returns to ZCPR2 never passes through `WBOOT`.
- **`RETI` without `EI`:** returns with interrupts disabled, because accepting the interrupt cleared both flip-flops.
- **Mapping changes mid-bulk-transfer (F4):** can underrun the transmitter.
- **Bank 7 exposed:** a bank primitive that accepts 7 lets a program overwrite the OS.
- **Raw caller pointers:** bank-7 code must not dereference caller memory in the switchable body.
- **Stale fixed addresses in this tree:** section 10's retrofit list, and ZCPR2's `BIOS EQU`.
- **Common-memory creep:** private BIOS and driver state left common because it was convenient during migration.

---

## 30. Final Picture

```text
                  MODE 10                   MODE 11
                  APPLICATION               OS EXECUTION
                  -----------               ------------

0000-1FFF         app bank N    =======     app bank N
                  page zero                 caller window

2000-DFFF         app bank N    <------>    bank 7
                  application               ZSDOS, BIOS, drivers,
                                            private OS state

E000-E3FF         bank 0        =======     bank 0
                  program-owned reservation, registered ISR callbacks

E400-FFFF         bank 0        =======     bank 0
                  common TPA and CCP,
                  permanent system common
```

```text
ROM
 +-- boot
 +-- canonical bank-0 and bank-7 images
 +-- recovery and diagnostics
 +-- immutable resources
```

Three runtime domains — caller window, OS body, common window — keep CP/M's low-memory conventions visible to ZSDOS, give the OS a private address space, recover 8 KiB in every application bank, and reduce common memory to what genuinely has to be shared.
