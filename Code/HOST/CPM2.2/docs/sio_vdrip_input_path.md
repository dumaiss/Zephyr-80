# SIO / Virtual Drip Raw Input Path

This note documents the Zephyr-80 SIO0/B keyboard-input path used by the
Virtual Drip console backend after the raw-input protocol change.

## Protocol Split

```text
Proxy -> Z80:
    raw terminal input bytes after VT100-style readiness response

Z80 -> proxy:
    framed Virtual Drip display/control packets
```

Keyboard input now behaves like a normal serial terminal byte stream. The BIOS
still owns output terminal behavior: `CONOUT`, ANSI-lite output parsing, cursor
movement, clear/scroll behavior, the text shadow buffer, and the VDP/Text80
backend remain on the Z80.

Storage and future structured commands should remain framed or use a separate
channel later. This change is only for proxy-to-Z80 keyboard/input bytes.

## Startup Readiness

Before the BIOS emits normal VDP traffic, the proxy sends this raw readiness
response:

```text
ESC [ ? 1 ; 0 c
```

Byte sequence:

```text
1B 5B 3F 31 3B 30 63
```

The BIOS also accepts `ESC [ ? 1 ; 2 c`. The readiness recognizer is deliberately
small and is not a general input parser. It runs only while
`vdrip_terminal_ready_flag` is zero. Recognized readiness bytes are consumed and
are not enqueued into `textq`.

## Intended Input Path

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
-> if not ready: vdrip_terminal_ready_parse_byte
-> if ready: textq FIFO
-> CONST checks textq_count
-> CONIN dequeues oldest byte
```

After readiness, every received byte is enqueued unchanged into `textq`.
Examples: Ctrl-X is `18h`, Enter is `0Dh`, ESC is `1Bh`, and arrow-up may arrive
as `1Bh 5Bh 41h`.

`textq` is the CP/M CONIN FIFO. `CONST` returns `0xff` when `textq_count` is
nonzero and `0x00` when it is empty. `CONIN` blocks until `textq_count` is
nonzero, then consumes the oldest byte from `textq_tail`.

## Obsolete Framed Input

The old proxy-to-Z80 keyboard packet path is no longer active:

```text
A5 5A LEN PACKET_TERMINAL_INPUT PAYLOAD CRC
```

The old parser may remain in source temporarily as inactive code, but
`vdrip_rx_sink` no longer calls it for keyboard input. Successful keyboard input
should not depend on `PACKET_TERMINAL_INPUT` frames or foreground `sio_rx_kick`
calls.

## Output Path

```text
CP/M calls CONOUT
-> vdrip_console_conout
-> ANSI/VT100-light output parser
-> text shadow / VDP name table updates
-> framed Virtual Drip VDP packets to proxy
-> proxy renders display
```

Input and output are separate. Keyboard bytes enqueue raw into `textq`; they do
not draw characters, parse ANSI, move the cursor, or scroll the display.
`CONOUT` may interpret output control sequences, but it must not read keyboard
input.
