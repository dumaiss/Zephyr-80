# ZCPR2 for Zephyr-80

An optional replacement for the CP/M 2.2 command processor, assembled into the
ROM in place of the stock CCP.

```sh
make zcpr2 RUNCPM=/path/to/RunCPM   # assemble ZCPR2 -> build/ccp-zcpr2.bin
make CCP=zcpr2                      # build a ROM carrying it
make                                # unchanged: the stock DRI CCP
```

`CCP=stock` is the default and produces a byte-identical ROM to a tree without
any of this.

## Why it fits, and why ZCPR3 does not

The common region is fixed in hardware at `C000h-FFFFh`, and applications own
the 1 KiB at `C000h-C3FFh` — it is the only memory visible from every bank, so
it is what programs use to move data between banks. Anything the command
processor needs outside its own slot competes with that, and nothing else can
absorb it: total free BIOS space is ~319 bytes, largest run 77.

ZCPR2 is configured here to need **nothing** outside the 2 KiB slot:

| Setting | Value | Consequence |
|---|---|---|
| `MULTCMD` | `FALSE` | no external command-line buffer at `CLBASE` |
| `INTPATH` | `TRUE` | the search path lives inside the CCP |
| `INTSTACK` | `TRUE` | the stack lives inside the CCP |
| `EXTFCB` | `TRUE`, `FCBADR=005Ch` | reuses page zero's standard FCB, not extra RAM |
| `WHEEL` | `FALSE` | no wheel byte |

Built with those, ZCPR2 assembles to **1987 bytes of code in the 2048-byte
slot**; its internal 48-byte stack occupies most of the reported remainder.

ZCPR3 was considered and rejected: its environment (`Z3ENV`, plus `NDR`, `FCP`,
`RCP`) must be common and would come out of that same 1 KiB. Its prebuilt
binary is 2304 bytes — it does not even fit the standard CCP slot.

## Addresses

Zephyr-80 is a textbook 56K CP/M, so ZCPR2's own equates land on it exactly:

```
CPRLOC = 3400H + (MSIZE-20-BIOSEX)*1024   ; MSIZE=56, BIOSEX=0 -> C400h = CBASE
BIOS   = CPRLOC + 800H + 0E00H            ;                       DA00h = CBIOS_BASE
```

Two lines in `src/Z2HDR.LIB` differ from the RunCPM original, and only two:

```
CPRLOC EQU 0C400H   ; was 0E400H, RunCPM 60K
BIOS   EQU 0DA00H   ; was 0FE00H, RunCPM
```

## Entry points

A CCP has two: one that processes a pending command line, one that does not.
`cbios_boot.asm` jumps to `CCP_CLEARBUF_ENTRY` (`CBASE+3`) with `C` = drive, from
both cold and warm boot, which is the second of the pair. ZCPR2 keeps the
convention — as built here, `C400h -> JP C4BAh` (CPR) and `C403h -> JP C4B6h`
(CPR1). `tools/patch_ccp.py` refuses to install anything that does not begin
with that two-jump header.

## One-line recall cooperation

ZCPR2 leaves the preceding command text in `CMDLIN` until ZSDOS function 10
begins reading the next line. ZSDOS saves the preceding length, clears the
current length normally, and uses the retained bytes when `^R` is pressed on an
empty CCP line. Non-empty-line `^R` remains the standard retype operation.

The warm-entry path still clears `CMDLIN`, and this machine restores the CCP
from ROM on WBOOT, so recall intentionally does not survive a warm boot. No
external buffer or common-TPA allocation is used.

## What is NOT replaced

The slot is `C400h-CBFFh`. The six bytes at `CC00h` are the BDOS serial number
and `FBASE` — the BDOS entry the whole system calls — is at `CC06h`. Only 2048
bytes are written. `restore_ccp_from_rom` copies `CBASE..FBASE`, i.e. 2054
bytes: the CCP *plus* that serial, so the serial has to survive the patch for
warm boot to work.

The BDOS is untouched. ZSDOS/ZRDOS would be a separate change to `CC00h-D9FFh`.

## Configuration is baked in, and the ROM makes that worse

ZCPR2's search path and named directories are *assembled into the CCP*. On a
floppy system reconfiguring means writing a new CCP to disk; here the CCP lives
in ROM and `restore_ccp_from_rom` reinstates it on **every warm boot**, so a
runtime change would not survive `^C` even if you made one.

Changing configuration therefore means editing `src/Z2HDR.LIB`, `make zcpr2`,
and reflashing.

There is a cheaper way if that becomes annoying: `restore_ccp_from_rom` already
runs with ROM visible on every warm boot, and adding a step after its `LDIR`
that overlays a saved config block onto ZCPR2's config area would give
runtime-editable paths for ~40 bytes of BIOS code and no common RAM. Slot 5 has
77 contiguous bytes free. Not implemented.

## Verified on hardware

Running as of 2026-09-07, alongside ZSDOS. Confirm it is actually live
by dumping `C400h`: ZCPR2 begins `C3 BA C4`, the stock CCP `C3 53 C7`. The prompt needed one fix: the
stock header sets `CPRMPT EQU '>'+80H`, whose high bit exists only so ZEX can
recognise the prompt, and ZCPR2 emits it with `MVI A,CPRMPT` / `CALL CONOUT`
**without masking**. A 7-bit terminal drops the bit and prints `>`, which is
why this has gone unnoticed wherever ZCPR2 has ever run; this console has a
full 8-bit font, so `0BEh` printed a glyph instead. It is now plain `'>'`.

Masking bit 7 in the console driver would have "fixed" it and broken every
graphic character the CP850 font provides, so the fix belongs here.

Not yet exercised: named directories, the search path, and the resident
`DIR`/`ERA`/`TYPE` commands — the features that are the reason to run ZCPR2 at
all.

## Provenance and licence

`src/ZCPR2.ASM` is ZCPR2 Version 2.0, Mod 0.3, **Copyright (c) 1982, 1983
Richard Conn**, released to the public domain **for non-commercial use only**;
commercial use requires the author's written approval. The copyright banner at
the top of the file is part of that grant — do not strip it.

`src/Z2HDR.LIB` is Conn's configuration header with the two address changes
above.

Vendored from a RunCPM distribution rather than referenced in place, so this
builds without depending on anything outside the repository:

| Path | What |
|---|---|
| `src/ZCPR2.ASM` | ZCPR2 source, locally patched to retain `CMDLIN` for ZSDOS empty-line `^R` recall |
| `src/Z2HDR.LIB` | configuration header, retargeted |
| `tools/MAC.COM` | DRI macro assembler — reads the `MACLIB`/macro dialect nothing else does |
| `tools/MLOAD.COM` | kept for reference; `tools/hex_to_ccp.py` does the HEX→binary step |
| `tools/EXIT.COM` | terminates RunCPM cleanly |
| `tools/runcpm-ccp/` | RunCPM's own bootstrap CCPs; which one it wants is compiled into the binary, so the script reads the name from its banner |

**RunCPM itself is a toolchain dependency**, like `sdasz80` or `xc8-cc` — not
vendored. Point `RUNCPM` at the executable (note: in the RunCPM tree the
executable is `RunCPM/RunCPM`, one level below the directory of the same name).
