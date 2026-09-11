# RunCPM (vendored)

RunCPM 6.9, upstream commit `642d01d1961abc984a0709d71394f752e263d027`
(2026-05-22), MIT licensed — see `LICENSE`.

## Why it is here

Two parts of this build run under a CP/M emulator, because their sources are
Z80 assembler for CP/M-hosted assemblers that no host tool reads:

- `../../zcpr2/build-zcpr2.sh` assembles ZCPR2 with DRI `MAC.COM`;
- `../../zsdos/build-zsdos.sh` assembles ZSDOS with Al Hawley's `ZMAC.COM` and
  links it with Microsoft `L80.COM`.

Every CP/M-side tool those scripts need is already carried in the tree —
`MAC.COM`, `MLOAD.COM`, `EXIT.COM`, `ZMAC.COM`, `L80.COM`, and even the RunCPM
CCP binaries under `../../zcpr2/tools/runcpm-ccp/`. The emulator was the one
piece left outside it, resolved from `PATH` or an `RUNCPM=` override pointing
somewhere on the developer's disk. That made the build depend on a binary the
repository had no copy of and no control over.

## The patch, and why it is the whole point

Upstream ships with `CCP_INTERNAL` selected. This copy selects `CCP_ZCPR3`
instead, in `src/globals.h`:

```c
//#define CCP_INTERNAL
#define CCP_ZCPR3
```

Both build scripts identify the emulator's CCP from its banner and then supply a
matching binary from `zcpr2/tools/runcpm-ccp/`. With the internal CCP there is no
such file to supply, and the scripts stop. So the build has never worked against
an unmodified RunCPM — it worked against one developer's patched checkout, and
nothing recorded that. A `git clean` in the wrong directory would have taken the
toolchain with it.

## Building it

The parent Makefile builds `build/tools/RunCPM` from `src/main.c` — RunCPM is a
single translation unit, so no separate configure or object list is needed — and
passes it to both scripts. `RUNCPM=` still overrides, for anyone who wants to
test against a different emulator build.

`src/Makefile.posix` is upstream's, kept for provenance. It is not what the
build uses, and it builds in place.

## Updating it

Copy `RunCPM/*.c`, `RunCPM/*.h` and `RunCPM/Makefile.posix` from an upstream
checkout into `src/`, reapply the `CCP_ZCPR3` selection above, rebuild, and
record the new version and commit at the top of this file. Check `VERSION` in
`src/globals.h` against what the scripts expect to see in the banner.
