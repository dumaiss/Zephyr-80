# ZCPR2 for Zephyr-80

The command processor of the Zephyr-80 system, assembled into the ROM at
`CBASE`.

```sh
make zcpr2    # assemble ZCPR2 -> build/ccp-zcpr2.bin
make          # build a ROM carrying it
```

`CCP=zcpr2` is the only supported value. The banked operating system needs the
program-exit call below, which the stock DRI CCP does not make.

## Why it fits, and why ZCPR3 does not

The CCP lives in common memory, the 2 KiB at `E400h-EBFFh` just below the BDOS
facade. Common memory is the 8 KiB at `E000h-FFFFh` that stays mapped whichever
bank is in use, and everything in it comes out of every program's address space.
So the command processor must need nothing outside its own slot.

ZCPR2 is configured here to need **nothing** outside the 2 KiB slot:

| Setting | Value | Consequence |
|---|---|---|
| `MULTCMD` | `FALSE` | no external command-line buffer at `CLBASE` |
| `INTPATH` | `TRUE` | the search path lives inside the CCP |
| `INTSTACK` | `TRUE` | the stack lives inside the CCP |
| `EXTFCB` | `TRUE`, `FCBADR=005Ch` | reuses page zero's standard FCB, not extra RAM |
| `WHEEL` | `FALSE` | no wheel byte |

Built with those, ZCPR2 fits the 2048-byte slot, including its internal 48-byte
stack. `tools/split_banked_image.py` refuses to install anything that is not a
2048-byte image beginning with the two-jump header.

ZCPR3 was considered and rejected: its environment (`Z3ENV`, plus `NDR`, `FCP`,
`RCP`) must be common and would need common memory outside the slot. Its
prebuilt binary is 2304 bytes — it does not even fit the standard CCP slot.

## Addresses

ZCPR2 needs two addresses: its own origin, `CPRLOC`, and the BIOS jump table,
because it calls `BIOS+6` (`CONST`) and `BIOS+9` (`CONIN`) directly.

`src/Z2HDR.LIB` carries both as literals:

```
CPRLOC EQU 0E400H   ; CBASE
BIOS   EQU 0F000H   ; CBIOS_BASE
```

`build-zcpr2.sh` rewrites both lines in its working copy on every build, from
`CBASE` in `../src/zephyr.asm` and `CBIOS_BASE` in `../src/cbios_defs.inc`, and
assembles at that base. Moving the layout therefore cannot leave ZCPR2 pointing
at the old one. The BIOS keeps `CONST` and `CONIN` live in its common table for
this reason.

## Entry points

A CCP has two: one that processes a pending command line, one that does not.
`cbios_boot.asm` jumps to `CCP_CLEARBUF_ENTRY` (`CBASE+3`) with `C` = drive, from
both cold and warm boot, which is the second of the pair. ZCPR2 keeps the
convention: `CBASE` jumps to `CPR`, and `CBASE+3` jumps to `CPR1`.

## Program exit

When a transient returns to ZCPR2 with `RET`, it never passes through warm
boot. ZCPR2 therefore calls Zephyr BDOS function 202 right after `CALL TPA`,
which stops any CTC channel the program left registered and clears its callback.
Without it, a stale callback would vector into memory the next program
overwrites. `GO` and `JUMP` reach the same call.

## One-line recall cooperation

ZCPR2 leaves the preceding command text in `CMDLIN` until ZSDOS function 10
begins reading the next line. ZSDOS saves the preceding length, clears the
current length normally, and uses the retained bytes when `^R` is pressed on an
empty CCP line. Non-empty-line `^R` remains the standard retype operation.

The warm-entry path still clears `CMDLIN`, and this machine restores the CCP
from ROM on WBOOT, so recall intentionally does not survive a warm boot. No
external buffer or common-memory allocation is used.

## The slot and its neighbours

The slot is `E400h-EBFFh`. The six bytes at `EC00h` are the BDOS serial number,
and `FBASE` — the BDOS entry the whole system calls — is at `EC06h`. Both belong
to the BDOS facade, which carries ZSDOS's `'ZSDOS '` serial so that tools reading
it still identify the BDOS.

`restore_ccp_from_rom` copies `CBASE..FBASE-1`, 2054 bytes, from ROM page 0 on
every warm boot: the CCP *plus* that serial.

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
runtime-editable paths. Not implemented.

## Verified on hardware

Running on the banked operating system with ZSDOS as of 2026-09-12. `SYSID.COM`
reports which command processor is actually executing. The prompt needed one
fix: the stock header sets `CPRMPT EQU '>'+80H`, whose high bit exists only so
ZEX can recognise the prompt, and ZCPR2 emits it with `MVI A,CPRMPT` /
`CALL CONOUT` **without masking**. A 7-bit terminal drops the bit and prints
`>`, which is why this has gone unnoticed wherever ZCPR2 has ever run; this
console has a full 8-bit font, so `0BEh` printed a glyph instead. It is now
plain `'>'`.

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

`src/Z2HDR.LIB` is Conn's configuration header with the address and prompt
changes above.

Vendored from a RunCPM distribution rather than referenced in place, so this
builds without depending on anything outside the repository:

| Path | What |
|---|---|
| `src/ZCPR2.ASM` | ZCPR2 source, locally patched to retain `CMDLIN` for ZSDOS empty-line `^R` recall and to make the program-exit call |
| `src/Z2HDR.LIB` | configuration header, retargeted |
| `tools/MAC.COM` | DRI macro assembler — reads the `MACLIB`/macro dialect nothing else does |
| `tools/MLOAD.COM` | kept for reference; `tools/hex_to_ccp.py` does the HEX→binary step |
| `tools/EXIT.COM` | terminates RunCPM cleanly |
| `tools/runcpm-ccp/` | RunCPM's own bootstrap CCPs; which one it wants is compiled into the binary, so the script reads the name from its banner |

RunCPM itself is vendored in `../tools/runcpm` and built by the Makefile.
`RUNCPM=` still overrides it.
