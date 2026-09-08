# ZSDOS for Zephyr-80

An optional replacement for the CP/M 2.2 BDOS, assembled into the ROM in place
of the stock one.

```sh
make zsdos RUNCPM=/path/to/RunCPM/RunCPM   # assemble -> build/bdos-zsdos.bin
make BDOS=zsdos                            # ROM carrying it
make CCP=zcpr2 BDOS=zsdos                  # with ZCPR2 as well
make                                       # unchanged: stock CCP and BDOS
```

`CCP` and `BDOS` are independent — ZSDOS runs under the stock CCP, and ZCPR2
runs over the stock BDOS. `make` with neither is byte-identical to a tree
without any of this.

## It fits, but only just

```
Total Code Size 0DEFH     = 3567 bytes
Data  CC00  DA00  < 3584> = the whole CC00h-D9FFh slot
```

The assembled code ends at offset `0DEFh`. ZSDOS's fixed high-data block begins
at `0DF1h` and occupies the rest of the 3584-byte BDOS slot, leaving two bytes
between code and data. There is no room to enable further options without
something else coming out.

## Addresses

`zsdos.lib` sets `ZRL EQU FALSE`, which makes the module standalone and defines
`BIOS EQU ZSDOS+0E00H`. Linked at `CC00h` that gives **DA00h** — `CBIOS_BASE`
exactly, the same coincidence that made ZCPR2 drop in cleanly. Zephyr-80 is a
textbook 56K CP/M and period software keeps landing on it without adjustment.

The module opens with six bytes of `'ZSDOS '` occupying CP/M's serial-number
slot, then `START: JP ENTRY` — so `FBASE` lands at `CC06h` as CP/M requires.
Unlike the CCP patch, the BDOS patch **does** replace those six serial bytes,
because a BDOS supplies its own.

## Build chain, and three things that bite

ZSDOS is Z80 source for Al Hawley's ZMAC or SLR's assemblers. Nothing in the
host toolchain reads it, so it is built the way RomWBW builds it — under a CP/M
emulator. RunCPM stands in for RomWBW's ZXCC.

**DRI's `LINK.COM` aborts on ZMAC's output.** Even bare, with no options.
Microsoft's `LINK-80` (`L80.COM`) reads the same `.REL` fine, so that is what is
used. L80 writes a `.COM`-style image beginning at `0100h` whatever the link
origin, so linking at `CC00h` produces a 55 KiB file that is almost all zeros;
`tools/l80_slice.py` cuts out the real 3.5 KiB.

**ZMAC swallows the console input that follows it**, so `EXIT.COM` never runs in
the same session and RunCPM idles until killed. Rather than pay a fixed
timeout, the build watches the log for ZMAC's completion line and stops as soon
as it appears — 1.8 seconds instead of two minutes.

**CP/M tools need CRLF.** A source file with Unix line endings makes ZMAC report
`INPUT LINE TOO LONG`, because the whole file looks like one line. That is not a
hypothetical: three lines edited into `zsdos.lib` with `\n` instead of `\r\n`
produced exactly that, and the error names neither the file nor the line. The
build script checks both sources before assembling.

## Configuration

One line differs from RomWBW's:

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

## Verified on hardware

Running as of 2026-09-07 with ZCPR2, including the Control-L handler below,
which clears the screen, redraws the prompt correctly, and retypes the line in
progress.

An earlier note here claimed ZSDOS was "noticeably faster". **That claim was
made against a stock ROM** and is withdrawn — performance has not been
characterised. Builds are now stamped `zephyr80-<ccp>-<bdos>.bin` so that
cannot recur, and `SYSID.COM` reports what is actually executing.

Not exercised on hardware: datestamping (`ZS=TRUE` expects a clock driver this
machine does not have), empty-line `^R` recall, and ZSDOS's internal path.

## Control-L, and the trap in reusing the BIOS helper

The stock BDOS carried a local patch giving Control-L a clear-and-redraw. It was
gated on the caller being the DRI CCP's buffer, so it died the moment ZCPR2
arrived — before ZSDOS was ever involved.

Reinstated here, entirely inside ZSDOS. The first attempt called the BIOS's
`ccp_clear_redraw`, as the stock patch did, and that was wrong: **that routine
reads and writes stock-BDOS addresses.**

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

Together with empty-line `^R` recall, this leaves two bytes between the main
code and ZSDOS's fixed high-data block. The space is paid for with
`UPATH=FALSE`.

## Empty-line Control-R recall

Literal up-arrow recall still cannot reuse the old BIOS hook: `NBYTES`, the
stock history length, is at `CBF1h` inside the CCP slot and has unrelated
contents under ZCPR2. ZSDOS instead gives `^R` a second, CCP-only meaning.

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
the recall load instruction, avoiding a separate data byte in the nearly full
BDOS slot.

## Provenance and licence

**ZSDOS-GP, Copyright (C) 1986, 1987, 1988 Harold F. Bower and Cameron W.
Cotrill**, released under the **GNU General Public License version 2 or later**.
`src/license.txt` is the full text and must travel with the source.

GPL v2 has a consequence worth stating plainly: a ROM image containing ZSDOS is
a derived work in binary form, so **distributing that ROM obliges you to offer
the corresponding source**. Building it for your own machine carries no such
obligation. The stock BDOS carries no equivalent condition.

Vendored from RomWBW at commit `29549c1f53680ec8175319d9e8214fe358cb0cc5`:

| Path | What |
|---|---|
| `src/zsdos.z80` | ZSDOS source, unmodified |
| `src/zsdos.lib` | configuration, one line changed |
| `src/license.txt`, `src/readme` | GPL text and the authors' notes |
| `tools/ZMAC.COM` | Al Hawley's Z80 macro assembler |
| `tools/L80.COM` | Microsoft LINK-80 3.44 |
| `tools/LINK.COM` | DRI LINK-80 — kept only to record that it aborts on this input |

RunCPM is a toolchain dependency, not vendored. `EXIT.COM` and the bootstrap
CCPs are shared with `../zcpr2/tools/`.
