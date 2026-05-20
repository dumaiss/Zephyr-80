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

The monitor uses polling only. Interrupts are disabled at reset. On boot, the
reset vector at `0000h` jumps to high ROM code at `E000h`. That code copies the
ROM image into SRAM banks with the memory decoder's shadow/copy mode, disables
ROM, then continues running from high common RAM. It then waits silently until
Enter is pressed once before printing the banner and prompt.

## Memory Map Constraints

At reset, normal mode reads `0000h-5FFFh` and `E000h-FFFFh` from ROM while
writes go to SRAM underneath. The startup relocation first copies the high safe
window, `E000h-FFFFh`, from ROM page 0 into hidden SRAM bank 0. It then enables
shadow/copy mode, where `E000h-FFFFh` is a safe SRAM execution window and
`0000h-DFFFh` reads selected ROM pages while writing matching SRAM banks.

After pages 0-7 are copied, the monitor writes `10h` to the banking latch to
disable ROM and select RAM bank 0. The top 8 KiB of RAM banks 1-7 is sacrificed
under this common-area model; `E000h-FFFFh` always maps to SRAM bank 0 in
RAM-only mode. The monitor sets `SP=FFFFh` after relocation and keeps workspace
in high common RAM around `F000h-FEFFh`.

In RAM-only mode:

- `0000h-DFFFh`: selected SRAM bank
- `E000h-FFFFh`: fixed/common SRAM bank 0 for monitor/BIOS/stack

This is more CP/M-friendly because CP/M page zero and the TPA can live in the
selected low bank while monitor/BIOS code and stack remain in high common RAM.

Because ROM is disabled before the command loop starts, monitor memory reads,
writes, and Intel HEX loads operate on RAM across the full 64 KiB address space.
Writing over the monitor's own RAM image can still disrupt the running monitor.

The command line editor supports Backspace/Delete and one-line recall with the
Up arrow.

## Build

```sh
make
```

The default output is:

- `build/monitor.raw.bin`: assembled binary before CPU-board data-bit fix
- `build/monitor.bin`: final binary after `tools/swapbits.py`

The default build emits a 64 KiB ROM image because code is intentionally placed
at `E000h`. `ROM_SIZE` should only be changed if the target ROM layout still
contains the `E000h-FFFFh` window.

```sh
make ROM_SIZE=65536
```

## Commands

- `R`: print saved monitor register snapshot. `PC` is reported as `N/A` because
  there is no interrupted user context yet.
- `D <addr> <len>`: dump memory, 16 bytes per line.
- `M <addr> <value>`: write one byte.
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
