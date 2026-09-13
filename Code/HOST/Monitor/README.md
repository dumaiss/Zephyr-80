# Zephyr-80 Monitor

Interactive monitor application for the Zephyr-80 CP/M environment.

## Runtime Model

Monitor is assembled as a CP/M-style application at `0100h`. The resident
Zephyr-80 CP/M BIOS has already initialized the machine before Monitor starts.
Monitor therefore does not initialize RAM, relocate ROM, configure banking, or
initialize the SIO.

At startup, Monitor initializes only its own command-line state, prints the
banner, and displays the prompt immediately.

Console input and output use the CP/M BIOS jump table. Monitor finds the table
through page zero's `JP WBOOT`, whose target is the table's second entry, and
calls `CONST`, `CONIN` and `CONOUT` through it. It uses no fixed BIOS address.

Bank access uses the Zephyr BDOS functions, through
`../Utilities/src/zbdos.inc`.

BIOS owns console initialization and input. Monitor owns command parsing, line
editing/history, Intel HEX load/export, memory and port commands, and the `G`
trampoline.

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
- `D <addr> <len>`: dump memory, 16 bytes per line. Addresses below `E000h`
  are Monitor's own bank; `E000h-FFFFh` is common memory.
- `DB <bank> <addr> <len>`: dump memory from RAM bank `0` through `6`, using
  the `XMOVE` and `MOVE` services (BDOS functions 211 and 210). Bank 7 holds the
  operating system and is refused.
- `M <addr> <value>`: write one byte.
- `I <port>`: read an 8-bit I/O port using `IN A,(C)`.
- `O <port> <value>`: write an 8-bit I/O port using `OUT (C),A`.
- `L`: receive Intel HEX records. Supports type `00` data and type `01` EOF.
- `G <addr>`: call code at `addr`. The monitor pushes a return address first,
  so loaded code can execute `RET` to return to the prompt.
- `X <addr> <len>`: export memory as Intel HEX. The output contains type `00`
  data records and one type `01` EOF record.
- `H` or `?`: help.

`APP <bank>` is retired: the BIOS `LAUNCH` entry it called no longer exists. The
help text still lists it, and it reports a command error.

## Notes

Direct `I` and `O` commands can access any requested Z80 I/O port. They are
operator-requested diagnostics and are separate from Monitor's own console path,
which always uses BIOS console calls. Writing the banking latch at port `00h`
with `O` changes Monitor's own memory under it.
