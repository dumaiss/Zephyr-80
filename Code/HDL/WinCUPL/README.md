# WinCUPL HDL Projects

Skeleton project for building programmable logic designs with WinCUPL.

This folder is intended for GAL/ATF logic source files such as ATF22V10 address
decoders. The build flow only generates output files such as JEDEC, list, and
documentation files; it does not program chips.

## Layout

```text
WinCUPL/
  Makefile              Build entry points
  src/                  WinCUPL source files
  scripts/              Build helper scripts
  build/                Generated output copied here
  docs/                 Project notes
```

## Toolchain

On Linux, `make` runs WinCUPL under Wine from its default install location in
the Wine prefix, `~/.wine/drive_c/WinCUPL/Shared/cupl.exe`, with
`CUPLFLAGS = -jaxf -u C:\WinCUPL\Shared\cupl.dl` (JEDEC, absolute, expanded
product terms, fuse plot; device library by its Windows path).  Nothing needs
to be set.

For another install, or a native `cupl` on `PATH`:

```sh
make CUPL="/path/to/WINCUPL/Shared/cupl.exe" CUPLFLAGS="-jaxf -u C:\\path\\cupl.dl"
make CUPL=cupl
```

A `CUPL` ending in `.exe` always runs under Wine.  The build fails if CUPL
produces no JED, since CUPL can report errors and still exit 0.  The JED is
named after the source's `Name` field (`MEM_DECODER.pld` gives
`Z80_MEM_DECODE.jed`).

## Build

Build every `.pld` file in `src/`:

```sh
make
```

Build one design:

```sh
make DESIGN=template_atf22v10
```

Generated artifacts are copied to `build/<design>/`.

Optional WinCUPL command-line flags can be passed through `CUPLFLAGS`:

```sh
make CUPL="/path/to/WINCUPL/BIN/CUPL.EXE" CUPLFLAGS="-j"
```

On Windows without Make, use the batch helper:

```bat
scripts\build_wincupl.bat src\template_atf22v10.pld build\template_atf22v10
```

## Clean

```sh
make clean
```

## Adding A New PLD

1. Copy `src/template_atf22v10.pld` to a new file in `src/`.
2. Update the WinCUPL header fields, pin names, and equations.
3. Run `make DESIGN=<file-name-without-.pld>`.

The template is intentionally simple and should be treated as a compileable
starting point, not final board logic.
