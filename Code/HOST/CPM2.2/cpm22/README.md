# Stock CP/M 2.2 CCP + BDOS, with Zephyr-80 patches

`cpm22.asm` is the DRI CP/M 2.2 CCP and BDOS source, vendored here with local
changes. It is the `CCP=stock BDOS=stock` half of the build; `../zcpr2/` and
`../zsdos/` are the replacements, vendored the same way.

## Provenance

Taken from [Z80-Retro/cpm-2.2](https://github.com/Z80-Retro/cpm-2.2) at commit
`5a90af6e9268e558b05abcc36f31c663ae3d4d03`, which remains a submodule at
`../cpm-2.2/` for its manuals and stock `.COM` files. Nothing in the build reads
that submodule any more.

Licensed under the DRI agreement in `DRI-LicenseAgreement.txt`.

## Why this is a copy and not a submodule edit

The patches below cannot be pushed -- the upstream repository belongs to someone
else -- so for four sessions the parent repo recorded a pointer at stock upstream
while the working tree built from a patched file that existed on exactly one
machine. A fresh clone silently produced a different CP/M. Copying the file into
this repository ends that class of problem; the submodule is now pinned at the
commit the parent already records and never needs a push.

## The local delta

Three patches, preserved verbatim in `patches/` and as the `zephyr80-local`
branch in the submodule:

| Patch | Change |
|---|---|
| `0001` | Prompt shows drive **and user number** (`A0>`), not just the drive |
| `0002` | Up-arrow single-command history recall, and Control-L clear-and-redraw |
| `0003` | Don't stall the retry loop on a bad sector |

To see the delta against stock at any time:

```sh
diff -u cpm-2.2/src/cpm22.asm cpm22/cpm22.asm
```

Both `0002` features are **stock-CCP-resident and are lost under ZCPR2** -- the
history length lives at `NBYTES` (`CBF1h`), inside the CCP slot. Control-L was
reinstated inside ZSDOS. One-line recall is available under ZCPR2+ZSDOS as
empty-line `^R`, rather than literal up-arrow; see `../zsdos/README.md`.
