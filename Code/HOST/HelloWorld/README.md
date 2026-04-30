# Z80 Hello World

Small Z80ASM skeleton project for bringing up the Zephyr-80 SIO console path.

The sample initializes one Z80 SIO channel in asynchronous 8N1 mode and prints
`Hello, World!` through:

- Data port: `0x20`
- Control port: `0x22`

The SIO is configured for x16 async clocking. For 115200 bps, the channel must
be fed a 1.8432 MHz TX/RX clock.

The SIO setup uses the channel control pins:

- `CTS` and `DCD` gate the channel through SIO auto-enables.
- `RTS` and `DTR` are asserted while the channel is active.

## Build

```sh
make
```

Override the assembler if needed:

```sh
make Z80ASM=/path/to/z80asm
```

The binary is emitted as `build/hello.bin`.
