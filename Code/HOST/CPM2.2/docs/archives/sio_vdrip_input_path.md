# SIO / Virtual Drip Input Path

## Single Hardware Reader

SIO core owns all SIO0/B data-port reads:

```text
SIO0/B receives byte
-> IM2 ISR or foreground sio_rx_kick
-> read SIO0B_DATA_PORT
-> common vdrip_rx_sink
```

The common sink is registered once by the selected console backend. Storage
changes receive mode but does not replace the sink.

## Default VDrip Console

Cold start:

```text
common sink in readiness mode
-> parse framed PROXY_READY
-> switch to raw mode
```

Idle input:

```text
received byte
-> common sink in raw mode
-> textq_put_ascii
-> textq FIFO
-> CONST / CONIN
```

Every idle byte is enqueued unchanged. Examples include Ctrl-X `18h`, Enter
`0Dh`, ESC `1Bh`, and arrow sequences such as `1Bh 5Bh 41h`.

## PTY VDrip Console

Cold start also waits for framed `PROXY_READY`. Idle input remains packetized:

```text
TERMINAL_RX frame
-> common parser
-> payload bytes
-> PTY textq FIFO
-> CONST / CONIN
```

Both console builds use the same current frame parser and sender.

## Storage Input

Before a storage request:

1. Save console RTS state.
2. Gate keyboard/PTY input through existing proxy and RTS behavior.
3. Enter common storage framed mode.
4. Send one complete read or write frame.
5. Wait on decoded common reply state.
6. Restore the console idle mode and previous RTS state.

Framed storage bytes cannot enter the console queue. Raw keyboard bytes that
arrive during storage are ignored while the parser searches for a valid frame.

## Interrupt Discipline

The common sink performs only bounded byte parsing, payload staging, flag
updates, or queue insertion. It does not:

- block;
- send serial output;
- switch banks;
- copy DMA records;
- perform VDP rendering;
- call BDOS.

Storage record copying remains in foreground BIOS code.

## Readiness Limitation

Phase 0 recognizes `PROXY_READY` at machine cold start and during an active
framed receive mode. It does not recognize a proxy restart while idle raw input
is active. Reboot Zephyr-80 after restarting the proxy.
