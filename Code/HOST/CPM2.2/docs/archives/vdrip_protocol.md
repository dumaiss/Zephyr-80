# Virtual Drip Protocol

The active `vdrip` display backend is V9958 GRAPHIC 6. Terminal output uses
`PACKET_COMMAND_STREAM` (`1Ah`) with the V9958 text/cell opcodes documented by
the matching Virtual Drip proxy. Legacy low-level packet values remain stable
for common infrastructure and tests; the BIOS console no longer uses the
TMS9928 name-table, scroll, or proxy-cursor paths.

This note documents the BIOS-side protocol used by the Zephyr-80 CP/M console
and storage drivers.

## Frame Format

```text
Offset  Size  Field
0       1     SYNC0 = A5h
1       1     SYNC1 = 5Ah
2       1     LEN_LO
3       1     LEN_HI
4       1     TYPE
5..     N     PAYLOAD
```

- `LEN` is a 16-bit little-endian count of `TYPE + PAYLOAD`.
- Minimum declared length is 1.
- The proxy supports payloads through 1,024 bytes.
- There is no CRC, checksum, or trailing integrity byte.
- A zero-payload packet has declared length 1.

The Phase 0 BIOS receive parser accepts declared lengths 1 through 131 because
the largest required proxy-to-Z80 packet is a 130-byte storage read payload.
The sender supports the proxy's full 1,024-byte payload limit.

## Receive Ownership

SIO core is the only hardware reader:

```text
SIO0/B byte
-> sio_core ISR or sio_rx_kick
-> common vdrip_rx_sink
-> raw console callback or framed parser
```

Storage does not replace the SIO RX sink and does not read the SIO directly.

## Receive Modes

| Mode | Behavior |
|---|---|
| Raw | Default VDrip console bytes are enqueued unchanged. |
| Packet | PTY console `TERMINAL_RX` packets are parsed and their payload bytes are enqueued. |
| Readiness | Frames are parsed until zero-payload `PROXY_READY` is received. |
| Storage | Frames are parsed until the active storage request succeeds or explicitly fails. |

The default console uses raw mode after startup. The PTY console uses packet
mode after startup.

## Startup Readiness

Cold boot initializes the common receive path and waits for:

```text
A5 5A 01 00 0A
```

This is a zero-payload `PROXY_READY` packet. No normal Virtual Drip output or
storage request is sent before readiness.

Warm boot reuses the online state. Phase 0 does not detect a proxy restart while
the BIOS is idle in raw/PTY input mode. After an idle-time proxy restart, reboot
Zephyr-80 so cold-start readiness consumes the proxy's one-time packet.

## Packet Types

| Type | Name | Direction | Payload |
|---:|---|---|---|
| `01h` | `VDP_CTRL_WRITE` | Z80 to proxy | 1 byte |
| `02h` | `VDP_DATA_WRITE` | Z80 to proxy | 1 byte |
| `05h` | `TERMINAL_INPUT` | Proxy to Z80 | Legacy terminal bytes |
| `06h` | `RESET` | Z80 to proxy | none |
| `07h` | `PING` | Z80 to proxy | none; no reply |
| `08h` | `FRAME_MARK` | Z80 to proxy | none |
| `09h` | `CURSOR_COMMAND` | Z80 to proxy | command-specific |
| `0Ah` | `PROXY_READY` | Proxy to Z80 | none |
| `0Bh` | `VDP_DATA_BLOCK` | Z80 to proxy | 1..1,024 bytes |
| `0Ch` | `VDP_SCROLL` | Z80 to proxy | 1 byte |
| `0Dh` | `STORAGE_READ_REQ` | Z80 to proxy | 6 bytes |
| `0Eh` | `STORAGE_READ_REPLY` | Proxy to Z80 | 130 bytes |
| `0Fh` | `STORAGE_WRITE_REQ` | Z80 to proxy | 134 bytes |
| `10h` | `STORAGE_WRITE_REPLY` | Proxy to Z80 | 2 bytes |
| `11h` | `TERMINAL_TX` | Z80 to proxy | terminal bytes |
| `12h` | `TERMINAL_RX` | Proxy to Z80 | terminal bytes |
| `19h` | `PROTOCOL_ERROR` | Proxy to Z80 | error code |

## Storage Packets

Read request payload:

```text
sequence, drive, LBA0, LBA1, LBA2, LBA3
```

Write request payload:

```text
sequence, drive, LBA0, LBA1, LBA2, LBA3, 128 record bytes
```

Read reply payload:

```text
sequence, status, 128 record bytes
```

Write reply payload:

```text
sequence, status
```

LBA is little-endian. Only a matching sequence, exact payload length, and zero
status complete a request successfully. Wrong-sequence replies are consumed as
stale traffic. A malformed matching reply, nonzero status, SIO error, or
`PROTOCOL_ERROR` fails the active BIOS call.

Storage waits indefinitely after request transmission because the configured
drive depends on the synchronous proxy.

## Parser Recovery

- Bytes before `A5h` are ignored in framed modes.
- `A5 A5 5A` treats the second `A5` as the new first sync byte.
- Declared lengths below 1 or above 131 are rejected.
- Type-only packets dispatch immediately.
- Unknown accepted-size packets are fully consumed and ignored.
- Every complete or rejected frame returns to sync search.
