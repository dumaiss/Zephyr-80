# WinCUPL Toolchain Notes

The build wrapper expects the WinCUPL command-line compiler.

## Linux With Wine

Install WinCUPL somewhere accessible and run:

```sh
make CUPL="/path/to/WINCUPL/BIN/CUPL.EXE"
```

If your installation path has spaces, keep the quotes.

Extra WinCUPL compiler switches can be passed through `CUPLFLAGS`.

## Windows

Run from a shell where WinCUPL's `BIN` directory is on `PATH`, or pass the path
explicitly:

```bat
make CUPL="C:\Wincupl\Shared\cupl.exe"
```

Without Make, run:

```bat
scripts\build_wincupl.bat src\template_atf22v10.pld build\template_atf22v10
```

## Output

WinCUPL writes generated files next to the source file it compiles. The wrapper
copies those files into:

```text
build/<design>/
```

Common generated files include JEDEC (`.jed`), listing (`.lst`), and compiler
documentation files, depending on the WinCUPL installation and device target.
