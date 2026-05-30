# SIO / Virtual Drip Input Path

This note documents the Zephyr-80 SIO0/B keyboard-input path used by the
Virtual Drip console backend. It is trace documentation only; it does not define
new protocol behavior.

## Intended Interrupt-Fed Input Path

```text
SIO0/B receives byte
-> Z80 IM2 interrupt
-> sio_core_isr
-> check RR0 RX_READY
-> read SIO0B_DATA_PORT
-> C = received byte
-> A = SIO_CH_CONSOLE
-> sio_core_dispatch_rx
-> vdrip_rx_sink
-> vdrip_parse_rx_byte
-> validated PACKET_TERMINAL_INPUT payload
-> textq FIFO
-> CONST checks textq_count
-> CONIN dequeues oldest byte
```

`textq` is the CP/M CONIN FIFO. `CONST` should be a cheap availability check:
return `0xff` when `textq_count` is nonzero and `0x00` when it is empty.
`CONIN` blocks until `textq_count` is nonzero, then consumes the oldest byte from
`textq_tail`.

Terminal input bytes are raw. Examples: Ctrl-X is `18h`, Enter is `0Dh`, and
arrow-up may arrive as `1Bh 5Bh 41h`.

## Foreground Kick Path

```text
caller calls sio_rx_kick
-> check RR0 RX_READY
-> read SIO0B_DATA_PORT
-> C = received byte
-> A = SIO_CH_CONSOLE
-> sio_core_dispatch_rx
-> vdrip_rx_sink
-> vdrip_parse_rx_byte
-> textq FIFO
```

The kick path and ISR path share the same dispatch/sink/parser/FIFO tail. That
is useful for isolating failures, but it also means successful input through
`sio_rx_kick` does not prove the hardware interrupt path works. It only proves
the parser and queue can process bytes once foreground code pulls them out of
the SIO.

The intended final model is that hot `CONST` loops do not call `sio_rx_kick`.
The startup proxy READY handshake may use it as a bring-up fallback.

## Output Path

```text
CP/M calls CONOUT
-> vdrip_console_conout
-> ANSI/VT100-light output parser
-> text shadow / VDP name table updates
-> Virtual Drip VDP packets to proxy
-> proxy renders display
```

Input and output are separate. Keyboard packet handlers enqueue raw bytes into
`textq`; they do not draw characters or move the screen cursor. `CONOUT` may
interpret output control sequences, but it must not read keyboard packets.

## Current Debugging Focus

The known issue during bring-up is that keyboard input appears to require
foreground `sio_rx_kick` calls. If input works only with kicks, likely fix areas
are:

- SIO0/B WR1 receive interrupt mode.
- SIO0/B WR2 / Z80 IM2 vector setup.
- SIO0 WR9 master interrupt enable.
- Bounded ISR RX handling.
- Reset Highest IUS acknowledgement.
- One-time post-IUS-reset RX_READY race check.
- Removing kicks from `CONST` once interrupt-fed input is proven.
