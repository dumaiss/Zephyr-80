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

Install Microchip/Atmel WinCUPL and point the build at `cupl.exe`.

On Linux, the wrapper can run WinCUPL through Wine:

```sh
make CUPL="/path/to/WINCUPL/BIN/CUPL.EXE"
```

On Windows or when `cupl` is already on `PATH`:

```sh
make
```

You can also set `CUPL` permanently in your shell environment.

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
