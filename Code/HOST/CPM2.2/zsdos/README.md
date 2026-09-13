# ZSDOS for Zephyr-80

The BDOS of the Zephyr-80 system. It runs from SRAM bank 7 at `2000h`, behind
the BDOS facade in common memory.

```sh
make zsdos    # assemble -> build/bdos-zsdos.bin
make          # build a ROM carrying it
```

`BDOS=zsdos` is the only supported value: the banked operating system is built
around ZSDOS in bank 7.

## Where it lives

```
Total Code Size 0EB1H     = 3761 bytes, in the 4096-byte slot at 2000h
```

ZSDOS is linked at `2000h` (`ZSDOS_ORG`) in bank 7, which is mapped only while
the operating system runs. Its BIOS jump table follows at `3000h`, and the rest
of the BIOS and its drivers follow that.

Programs never call ZSDOS directly. `CALL 5` reaches the BDOS facade at `FBASE`
(`EC06h`) in common memory. The facade switches to its own stack and copies any
FCB, DMA or buffer that ZSDOS cannot see into common memory. It then enters
operating-system mode and calls ZSDOS's entry at `2006h`. While ZSDOS runs,
`0000h-1FFFh` is still the program's bank, so it reads the program's page zero,
default FCB and default DMA directly.

The facade carries a copy of ZSDOS's six-byte `'ZSDOS '` serial at `EC00h`, so
tools that identify the BDOS by the bytes before `FBASE` still see ZSDOS.

## Addresses

`zsdos.lib` sets `ZRL EQU FALSE`, which makes the module standalone, and
`zsdos.z80` defines `BIOS EQU ZSDOS+1000H`. Linked at `2000h` that gives
`3000h`, where the firmware assembles ZSDOS's BIOS jump table.
`tools/split_banked_image.py` checks that a jump is there.

ZSDOS also needs three addresses from the firmware build:

- `WBTRAP`, the common warm-boot trap
- `CCPLO` and `CCPHI`, the bounds of the CCP slot

`tools/gen_zsdos_bios.py` writes them to `ZSDOSBIO.LIB` from the firmware symbol
map on every build, so none of them is written down. The generated file ends in
Ctrl-Z. Without it ZMAC reads the padding in the file's last 128-byte record as
source.

## Local changes

Every change to `zsdos.z80` is marked `[Zephyr-80]`:

| Change | Why |
|---|---|
| `BIOS EQU ZSDOS+1000H`, was `+0E00H` | the grown stack moved the end of ZSDOS up |
| 192 bytes of stack inserted in place | the stock stack is about 56 bytes, mostly its copyright string, and interrupt frames land on it. It grows in place because ZSDOS restores `IX` from `IXSAVE` by address, so `IXSAVE` must stay the two bytes directly below `ZSDOSS` |
| both `RST 0` replaced by `JP WBTRAP` | in operating-system mode `RST 0` would run a program-replaced `0000h` vector with bank 7 mapped. `WBTRAP` restores application mode first |
| `CCPBUF` compares with `CCPLO`/`CCPHI` | the CCP range comes from `CBASE` instead of literals |
| Control-L handler | see below |
| empty-line `^R` recall | see below |

`zsdos.lib` changes one line from RomWBW's:

```
ZRL EQU FALSE   ; was TRUE -- standalone .REL, no NZCOM named COMMON
```

Everything else is as shipped. Worth knowing what that means:

| Equate | Value | Consequence |
|---|---|---|
| `ZSDOS11` | `TRUE` | version 1.1, compatible with released utilities |
| `ZS` | `TRUE` | ZSDOS rather than ZDDOS: search path, and datestamping via an **external** clock driver |
| `PATHAD` | `IPATH` | ZSDOS's own internal path, `DEFB 1,0` — drive A, user 0, which here is the ROM disk holding every utility |
| `WHLADR` | `0` | wheel byte disabled |
| `SLR` | `TRUE` | selects the ZMAC/SLR assembler dialect |

**`ZS=TRUE` expects an external clock driver and file-stamping module**, which
this machine does not have. Datestamping therefore will not work; the BDOS
itself should be unaffected. That is reasoning, not a measurement — see below.

## Build chain, and three things that bite

ZSDOS is Z80 source for Al Hawley's ZMAC or SLR's assemblers. Nothing in the
host toolchain reads it, so it is built the way RomWBW builds it — under a CP/M
emulator. RunCPM, vendored in `../tools/runcpm` and built by the Makefile,
stands in for RomWBW's ZXCC.

**DRI's `LINK.COM` aborts on ZMAC's output.** Even bare, with no options.
Microsoft's `LINK-80` (`L80.COM`) reads the same `.REL` fine, so that is what is
used. L80 writes a `.COM`-style image beginning at `0100h` whatever the link
origin, so linking at `2000h` produces a file padded with zeros up to the code;
`tools/l80_slice.py` cuts out the real 4 KiB.

**ZMAC swallows the console input that follows it**, so `EXIT.COM` never runs in
the same session and RunCPM idles until killed. Rather than pay a fixed
timeout, the build watches the log for ZMAC's completion line and stops as soon
as it appears — 1.8 seconds instead of two minutes.

**CP/M tools need CRLF.** A source file with Unix line endings makes ZMAC report
`INPUT LINE TOO LONG`, because the whole file looks like one line. That is not a
hypothetical: three lines edited into `zsdos.lib` with `\n` instead of `\r\n`
produced exactly that, and the error names neither the file nor the line. The
build script checks both sources before assembling.

## Verified on hardware

Running from bank 7 with ZCPR2 as of 2026-09-12, including the Control-L handler
below, which clears the screen, redraws the prompt correctly, and retypes the
line in progress.

An earlier note here claimed ZSDOS was "noticeably faster". **That claim was
made against a stock ROM** and is withdrawn — performance has not been
characterised. Builds are stamped `zephyr80-<ccp>-<bdos>.bin`, and `SYSID.COM`
reports what is actually executing.

Not exercised on hardware: datestamping (`ZS=TRUE` expects a clock driver this
machine does not have) and ZSDOS's internal path.

## Control-L, and the trap in reusing the BIOS helper

The stock BDOS carried a local patch giving Control-L a clear-and-redraw. It was
gated on the caller being the DRI CCP's buffer, so it died the moment ZCPR2
arrived — before ZSDOS was ever involved.

Reinstated here, entirely inside ZSDOS. The first attempt called the BIOS's
`ccp_clear_redraw`, as the stock patch did, and that was wrong: **that routine
read and wrote stock-BDOS addresses** (from the layout before the banked
operating system, with the BDOS at `CC00h`).

| | Address | Under ZSDOS |
|---|---|---|
| `ACTIVE` | `CF5Ch` | reads `0Ah` from a message string → prompt showed `K` |
| `USERNO` | `CF5Bh` | reads `0Dh` → prompt showed `=` |
| `CURPOS` | `CF26h` | **written** — corrupted a string |
| `STARTING` | `CF25h` | **written** — overwrote a `RET` with `03h` |

The wrong prompt was the visible half. The `RET` overwrite meant ZSDOS fell
through a return into a message string as code, on every Control-L.

The working version needs no BIOS helper at all: the console driver clears the
display on a `0Ch`, the drive and user come from **`0004h`** (the CP/M
convention both the stock CCP and ZCPR2 maintain), and `WRCON` keeps `TABCNT`
in step by itself. User 0 prints no digit, matching ZCPR2's own prompt.

When ZSDOS still lived in the 3584-byte slot below the old BIOS, this and
empty-line `^R` recall left two bytes between the main code and ZSDOS's fixed
high-data block, paid for with `UPATH=FALSE`.

## Empty-line Control-R recall

Literal up-arrow recall cannot reuse the stock BIOS hook: `NBYTES`, the stock
history length, lived inside the stock CCP's slot and has unrelated contents
under ZCPR2. ZSDOS instead gives `^R` a second, CCP-only meaning.

When BDOS function 10 starts, ZSDOS saves the buffer's preceding length before
clearing the current length. ZCPR2 leaves the preceding text bytes in its input
buffer. If `^R` is pressed on an empty CCP line, ZSDOS restores that length and
enters its existing retype loop, leaving the recalled command editable. On a
non-empty line, and for non-CCP function-10 callers, `^R` retains its standard
retype-current-line behavior. Control-L continues to share the same retype
loop.

No second command buffer is allocated. Consequently, a blank command replaces
the retained text, and a warm boot deliberately loses history when the ROM copy
restores ZCPR2 with a zero command length. Resident commands and transient
programs that return to ZCPR2 with `RET` retain one command. Programs that exit
through WBOOT do not.

The ZSDOS delta is 16 bytes. The saved length lives in the immediate operand of
the recall load instruction, avoiding a separate data byte.

## Provenance and licence

**ZSDOS-GP, Copyright (C) 1986, 1987, 1988 Harold F. Bower and Cameron W.
Cotrill**, released under the **GNU General Public License version 2 or later**.
`src/license.txt` is the full text and must travel with the source.

GPL v2 has a consequence worth stating plainly: a ROM image containing ZSDOS is
a derived work in binary form, so **distributing that ROM obliges you to offer
the corresponding source**. Building it for your own machine carries no such
obligation.

Vendored from RomWBW at commit `29549c1f53680ec8175319d9e8214fe358cb0cc5`:

| Path | What |
|---|---|
| `src/zsdos.z80` | ZSDOS source, with the local changes above marked `[Zephyr-80]` |
| `src/zsdos.lib` | configuration, one line changed |
| `src/license.txt`, `src/readme` | GPL text and the authors' notes |
| `tools/ZMAC.COM` | Al Hawley's Z80 macro assembler |
| `tools/L80.COM` | Microsoft LINK-80 3.44 |
| `tools/LINK.COM` | DRI LINK-80 — kept only to record that it aborts on this input |

`EXIT.COM` and the bootstrap CCPs are shared with `../zcpr2/tools/`.
