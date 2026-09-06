# Zephyr-80 Monitor

Interactive monitor application for the Zephyr-80 CP/M environment.

## Runtime Model

Monitor is assembled as a CP/M-style application at `0100h`. The resident
Zephyr-80 CP/M BIOS has already initialized the machine before Monitor starts.
Monitor therefore does not initialize RAM, relocate ROM, configure banking, or
initialize the SIO.

At startup, Monitor initializes only its own command-line state, prints the
banner, and displays the prompt immediately.

Console input and output use the resident BIOS jump table:

- `CONST` at `DA06h`
- `CONIN` at `DA09h`
- `CONOUT` at `DA0Ch`
- `LAUNCH` at `DA3Fh`

BIOS owns SIO channel B initialization and polling. Monitor owns command
parsing, line editing/history, Intel HEX load/export, memory and port commands,
and the `G` trampoline.

## Build

```sh
make
```

The default output is:

- `build/zephyr80_monitor.bin`: non-bit-swapped Monitor binary for later ROM
  image integration. This payload is stripped so its first byte is loaded at
  runtime address `0100h`.
- `build/zephyr80_monitor.padded.bin`: intermediate `makebin` output that
  still includes address padding before `0100h`
- `build/zephyr80_monitor.ihx`: linked Intel HEX output
- `build/zephyr80_monitor.lst`: assembler listing
- `build/zephyr80_monitor.sym`: symbol table

Clean generated files with:

```sh
make clean
```

## Commands

- `R`: print saved monitor register snapshot. `PC` is reported as `NA`
  because there is no interrupted user context.
- `D <addr> <len>`: dump memory, 16 bytes per line.
- `DB <bank> <addr> <len>`: dump memory from RAM bank `0` through `7` using
  the resident BIOS `XMOVE`/`MOVE` extension entries.
- `M <addr> <value>`: write one byte.
- `I <port>`: read an 8-bit I/O port using `IN A,(C)`.
- `O <port> <value>`: write an 8-bit I/O port using `OUT (C),A`.
- `APP <bank>`: launch application bank `0` through `7` by calling BIOS
  `LAUNCH`.
- `L`: receive Intel HEX records. Supports type `00` data and type `01` EOF.
- `G <addr>`: call code at `addr`. The monitor pushes a return address first,
  so loaded code can execute `RET` to return to the prompt.
- `X <addr> <len>`: export memory as Intel HEX. The output contains type `00`
  data records and one type `01` EOF record.
- `H` or `?`: help.

## Notes

Direct `I` and `O` commands can access any requested Z80 I/O port. They are
operator-requested diagnostics and are separate from Monitor's own console path,
which always uses BIOS console calls.
