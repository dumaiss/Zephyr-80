# Zephyr-80 Test Programs

Small Z80 assembly programs for exercising the various parts of the Zephyr-80
machine during hardware bring-up. Each file in `src/` is built independently so
individual tests can be burned to ROM or loaded through the monitor.

## Programs

- `helloworld.asm`: initializes SIO channel B and repeatedly prints
  `Hello, World!`.
- `echo.asm`: initializes SIO channel B and echoes received serial characters.
- `ctctest.asm`: samples CTC channel 0 into a small RAM buffer.
- `testiorq.asm`: repeatedly writes `55h` to I/O port `80h`.
- `testlatchport.asm`: repeatedly reads I/O port `00h` with short delay loops.

`main.asm` was the original hello-world source name. The current source file is
`helloworld.asm`, and the Makefile builds whatever `.asm` files are present in
`src/`.

## Walkthroughs

### `helloworld.asm`

This ROM-style test starts at `0000h`, disables interrupts, sets the stack to
`FFFFh`, and initializes Z80 SIO channel B on data port `22h` and control port
`23h`.

The SIO initialization resets the channel, selects x16 asynchronous serial mode
with one stop bit and no parity, enables 8-bit receive with auto-enables, and
enables 8-bit transmit while asserting RTS and DTR. Interrupts are left disabled,
so all serial I/O is polled.

After initialization, the main loop loads `HL` with `hello_message`, calls
`sio_puts`, and jumps back to print it again. `sio_puts` walks the
null-terminated string one byte at a time. `sio_putc` polls RR0 until the SIO
reports transmit-buffer-empty, then writes the character to the SIO data port.

### `echo.asm`

This serial echo test also starts at `0000h`, disables interrupts, sets the stack
to `FFFFh`, and initializes SIO channel B on ports `22h` and `23h`.

The SIO setup resets the channel, selects x16 asynchronous 8N1 operation, writes
WR3 with `0C1h` for 8-bit receive plus receive-enable, writes WR5 with `0EAh`
for 8-bit transmit plus transmit-enable, RTS, and DTR, then disables SIO
interrupts.

After setup, the program waits for one received character before printing the
banner. This keeps the banner from being lost while the terminal is being
opened. The main loop then waits for a byte with `sio_getc`, sends that same byte
back with `sio_putc`, and sends an extra line-feed after carriage-return so a
terminal moves to the next line cleanly.

### `ctctest.asm`

This is a small monitor-loadable CTC sampling test.

The file starts with `org 8000h`, so the code is intended to be loaded and run
from RAM at `8000h`, not burned as reset-vector ROM code. `CTC0` names I/O port
`40h`, which is the CTC channel being sampled. `SAMPLE_BUF` names RAM address
`8100h`, where the captured bytes will be stored.

At `start`, the program loads `HL` with `8100h`; `HL` is used as the write
pointer into the sample buffer. It then loads `B` with `32`, making `B` the loop
counter.

Each pass through `sample_loop` executes `in a,(CTC0)` to read the current byte
from CTC port `40h`. The value in `A` is stored at the current buffer address
with `ld (hl),a`, then `HL` is incremented so the next sample goes to the next
RAM byte. `djnz sample_loop` decrements `B` and repeats until 32 samples have
been written to `8100h` through `811Fh`.

After the last sample, `ret` returns to the caller. When run from the monitor,
the captured CTC values can be inspected by dumping memory starting at `8100h`.

### `testiorq.asm`

This ROM-style I/O request test starts at `0000h`, disables interrupts, and
loads `A` with the fixed pattern `55h`.

The loop continuously writes `A` to I/O port `80h` with `OUT ($80),A`, then jumps
back to repeat forever. It is useful for checking I/O decode, IORQ activity, and
external hardware connected to that port.

### `testlatchport.asm`

This ROM-style input-port test starts at `0000h`, disables interrupts, and sets
the stack pointer to `FFFFh`.

The loop repeatedly reads I/O port `00h` into `A`. It then runs two delay loops
by loading `B` with `0` and executing `DJNZ`; on Z80 this counts through 256
iterations before falling through. After both delays, it jumps back and reads the
port again. This gives a slow, repeated input cycle for observing latch or port
behavior on the bus.

## Build

```sh
make
```

The default build emits two outputs for every `src/*.asm` file:

- `build/<name>.bin`: binary for EPROM burning, with the data-bit swap fix
  applied by `tools/swapbits.py`.
- `build/<name>.hex`: Intel HEX for loading without the bit swap fix. These HEX
  files are assembled to run at address `8000h`.

Build only one output family if needed:

```sh
make bins
make hex
```

Override tools from the command line when needed:

```sh
make Z80ASM=/path/to/z80asm
make PYTHON=/path/to/python3
```

Remove generated outputs:

```sh
make clean
```
