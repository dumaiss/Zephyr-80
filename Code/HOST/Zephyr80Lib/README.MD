# Zephyr80Lib

`Zephyr80Lib` is the reusable FTL Modula-2 library for Zephyr-80 programs.
It provides the public `Sound`, `Timer`, and `Player` modules. The current
implementation targets the four
SN76489-compatible PSGs on Afternoon Blend and the Zephyr BIOS-managed CTC0
interrupt service.

All CP/M-visible source and output filenames are 8.3-compatible.

## Public modules

- `Sound` controls 16 logical channels across the four PSGs.
- `Timer` exposes logical ticks from 1 through 180 Hz. CTC0 and the assembly
  callback bridge remain private implementation details.
- `Player` loads a ZTR file and advances complete singleton music playback one
  application-supplied tick at a time.

`CTCLow`, `ZTR`, and `PlyCore` are archive implementation modules, not public
application APIs. See `DOC/API.MD` for the complete public contract and an
embedding example.

## PC build

The library is built with FTL Modula-2 under RunCPM. The repository carries the
RunCPM executable and the ZCPR3 CCP image; the FTL distribution is read from
`../Software/disk1/5`. On the x86-64 Linux development host, only Python 3 and
`make` are required:

```text
make clean
make
```

Objects are written to `BUILD/FTL`, and `BUILD.LOG` holds the full compiler,
assembler and linker output. Tool paths can be overridden through Make
variables; run `make help`.

## Why not Turbo Modula-2

This library was originally built with Turbo Modula-2, and that toolchain has
been removed. TM2's runtime is too large for the machine: once it is linked in,
a hosted application has no room left to run. Since the point of this library is
hosted development on the Zephyr-80 itself, that is disqualifying.

Consequences worth knowing:

- FTL's compilers are line-oriented. LF-only source reads as one enormous line
  and `MD` reports `ERROR 81 end of file reached before program complete`.
  `SRC` and `TEST` are stored CRLF and pinned by `.gitattributes`.
- FTL has no port I/O in the language and no `SYSTEM.OUT`. `SRC/PORTIO.*`
  supplies `In` and `Out`; see `TOOLS/README.MD` for why it is built from
  source rather than imported.
- FTL's `Files` is block-oriented, with no `Open`, `ReadBytes`, `NoTrailer` or
  `EOF`. Use `Lookup`, `SeqReadBlock`, the `eof` field of `FILE`, and `Close`.
  Block transfers move whole 128-byte units even when fewer bytes are asked
  for, so read buffers must be sized in whole blocks.

## Native FTL CTCLow bridge

`SRC/CTCLOW.Z80` targets the FTL `ASM.COM` supplied in `../Software/disk1/5`.
On CP/M, build it with these commands after copying `CTCLOW.DEF` and
`CTCLOW.Z80` to the FTL work disk:

```text
MD CTCLOW.DEF
ASM CTCLOW.Z80 CTCLOW.REL
ML yourprog
```

Keep `OPSASM.DAT` on the logged drive. Both ASM filenames require extensions.
Compile the definition first; ASM replaces the definition's stub `.REL`.
Its bare `LABEL` directives export procedures in `CTCLOW.DEF` order.
The syntax follows the supplied FTL assembly examples and the
[FTL manual, chapter 7](https://www.cpcwiki.eu/imgs/9/92/Hisoft_FTL_Modula-2_Z80_User_Guide_%28Hisoft%29_Manual.pdf).

`FTLTEST.COM` is a hosted regression, not a hardware timer test; running it
needs a C++ compiler and `libqkz80` via `tests/ftl_bridge.cpp`.

Callback placement remains `E3C0h-E3F6h`, with state at `E3F8h-E3FEh`.
FTL consumers must reserve that region against code, data, heap and stack;
the bridge does not change the FTL runtime's memory allocator. It still
requires the Zephyr BIOS registration API.
