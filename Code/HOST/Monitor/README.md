# Zephyr-80 ROM Monitor

First polling-only ROM monitor for the Zephyr-80 homebrew Z80 machine.

## Hardware

- CPU: Z80
- ROM entry: `0000h`
- Console: Z80 SIO channel B
- SIO B data port: `22h`
- SIO B control port: `23h`
- Serial mode: 115200 8N1, 1.8432 MHz SIO clock, x16 async clocking
- SIO WR3 auto-enables: disabled, for FT230-style USB serial wiring without the
  corresponding modem-control input

The monitor uses polling only. Interrupts are disabled at reset. On boot, it
waits silently until Enter is pressed once, then prints the banner and prompt.

## Memory Map Constraints

With the default decoder state, `0000h-5FFFh` reads ROM but writes SRAM. That
range is unsafe for stack, variables, buffers, and default loader output because
code may write SRAM and then read ROM back.

The monitor sets `SP=FFFFh` immediately at reset and keeps workspace in upper
RAM around `F000h-FEFFh`. Writes and Intel HEX loads to `0000h-5FFFh` are
rejected.

## Build

```sh
make
```

The default output is:

- `build/monitor.raw.bin`: assembled binary before CPU-board data-bit fix
- `build/monitor.bin`: final binary after `tools/swapbits.py`

To pad the ROM image:

```sh
make ROM_SIZE=32768
```

## Commands

- `R`: print saved monitor register snapshot. `PC` is reported as `N/A` because
  there is no interrupted user context yet.
- `D <addr> <len>`: dump memory, 16 bytes per line.
- `M <addr> <value>`: write one byte. Rejects `0000h-5FFFh`.
- `I <port>`: read an 8-bit I/O port using `IN A,(C)`.
- `O <port> <value>`: write an 8-bit I/O port using `OUT (C),A`.
- `L`: receive Intel HEX records. Supports type `00` data and type `01` EOF.
- `G <addr>`: call code at `addr`. The monitor pushes a return address first,
  so loaded code can execute `RET` to return to the prompt.
- `X <addr> <len>`: export memory as Intel HEX. The output contains only type
  `00` data records and one type `01` EOF record, so it can be captured with a
  terminal program and later reloaded with `L`.
- `H` or `?`: help.

Direct `I`/`O` access to the console SIO ports (`22h`/`23h`) can disturb monitor
serial I/O. For example, `O 22 55` writes byte `55h` to the console data port.
