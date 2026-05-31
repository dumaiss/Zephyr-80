# Virtual Drip Protocol

This note documents the BIOS-side Virtual Drip protocol split used by the
Zephyr-80 CP/M 2.2 VDrip console and storage drivers.

## Channel Split

The current build uses one SIO0/B serial link but separates traffic by
direction and transaction state:

```text
Proxy -> Z80, normal console mode:
    raw terminal input bytes

Z80 -> proxy, display/control/storage requests:
    framed Virtual Drip packets

Proxy -> Z80, storage transaction mode:
    framed storage reply packets
```

Keyboard input is raw after startup readiness. Storage replies are framed while
the storage backend owns the receive sink. Display/control packets are always
framed.

## Startup Readiness

The proxy sends a raw terminal readiness response before the BIOS emits normal
VDP display traffic:

```text
ESC [ ? 1 ; 0 c
```

Accepted byte sequence:

```text
1B 5B 3F 31 3B 30 63
```

The BIOS also accepts `ESC [ ? 1 ; 2 c`. These bytes are consumed by the
readiness recognizer and are not enqueued as CP/M console input.

## Frame Format

Framed Virtual Drip packets use:

```text
A5 5A LEN TYPE PAYLOAD... CRC
```

`LEN` is the byte count from `LEN` through `CRC`, inclusive:

```text
LEN = 1 byte LEN + 1 byte TYPE + payload bytes + 1 byte CRC
```

A zero-payload frame therefore has `LEN = 3`.

CRC is the existing `crc8_update` algorithm used by `vdrip_send_packet` and the
storage reply parser. The CRC is accumulated over `LEN`, `TYPE`, and payload
bytes, then compared with the final CRC byte. Do not change the CRC algorithm
or its covered byte range unless both BIOS and proxy change together.

## Packet Types

Existing packet type values are stable ABI between BIOS and proxy.

| Type | Name | Direction | Status |
|---:|---|---|---|
| `01h` | `PACKET_VDP_CTRL_WRITE` | Z80 -> proxy | Active |
| `02h` | `PACKET_VDP_DATA_WRITE` | Z80 -> proxy | Active |
| `03h` | `PACKET_VDP_STATUS_READ` | Historical include value | Not used by current BIOS driver |
| `04h` | `PACKET_VDP_DATA_READ` | Historical include value | Not used by current BIOS driver |
| `05h` | `PACKET_TERMINAL_INPUT` / `PACKET_KEY_EVENT` | Proxy -> Z80 | Obsolete for keyboard input |
| `06h` | `PACKET_RESET` | Z80 -> proxy | Active |
| `07h` | `PACKET_PING` | Z80 -> proxy | Active |
| `08h` | `PACKET_FRAME_MARK` | Z80 -> proxy | Active |
| `09h` | `PACKET_CURSOR_COMMAND` | Z80 -> proxy | Active |
| `0Ah` | `PACKET_PROXY_READY` | Proxy -> Z80 | Obsolete; readiness is raw |
| `0Bh` | `PACKET_VDP_DATA_BLOCK` | Z80 -> proxy | Active |
| `0Ch` | `PACKET_VDP_SCROLL` | Z80 -> proxy | Active |
| `0Dh` | `PACKET_STORAGE_READ_REQ` | Z80 -> proxy | Active |
| `0Eh` | `PACKET_STORAGE_READ_REPLY` | Proxy -> Z80 | Active |
| `0Fh` | `PACKET_STORAGE_WRITE_REQ` | Z80 -> proxy | Active |
| `10h` | `PACKET_STORAGE_WRITE_REPLY` | Proxy -> Z80 | Active |

The obsolete framed keyboard parser remains in `cbios_console_vdrip.asm` as
inactive compatibility/debug source. Normal keyboard input must not depend on
`PACKET_TERMINAL_INPUT`.

## Console Output Packets

The VDrip console driver emits display/control packets through
`vdrip_send_packet`.

Common active packets:

| Packet | Payload |
|---|---|
| `PACKET_RESET` | none |
| `PACKET_PING` | none |
| `PACKET_FRAME_MARK` | none |
| `PACKET_VDP_CTRL_WRITE` | one VDP control byte |
| `PACKET_VDP_DATA_WRITE` | one VDP data byte |
| `PACKET_VDP_DATA_BLOCK` | up to 240 bytes in the current BIOS chunking |
| `PACKET_VDP_SCROLL` | one row-count byte |
| `PACKET_CURSOR_COMMAND` | command-specific cursor payload |

The console driver owns ANSI/VT100-light output parsing, the text shadow
buffer, cursor state, scroll behavior, and VDP packet emission.

## Console Input

After readiness, proxy-to-Z80 console input is a raw byte stream:

```text
proxy terminal byte
-> SIO0/B RX
-> vdrip_rx_sink
-> textq FIFO
-> CONST / CONIN
```

Input bytes are not interpreted by the output parser. ESC sequences from the
keyboard, such as arrow-key sequences, are queued byte-for-byte for CP/M
software to consume.

## Storage Packets

Storage packets use the same frame format and CRC semantics. Payload sizes are
larger than the obsolete small keyboard packet buffer.

### Read Request

Packet type: `PACKET_STORAGE_READ_REQ` (`0Dh`)

Payload length: 6 bytes.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | sequence byte |
| 1 | 1 | drive number |
| 2 | 1 | LBA byte 0, least significant |
| 3 | 1 | LBA byte 1 |
| 4 | 1 | LBA byte 2 |
| 5 | 1 | LBA byte 3, most significant |

### Read Reply

Packet type: `PACKET_STORAGE_READ_REPLY` (`0Eh`)

Payload length: 130 bytes.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | sequence byte |
| 1 | 1 | status |
| 2 | 128 | record data |

On success, status is `00h` and exactly 128 data bytes follow.

### Write Request

Packet type: `PACKET_STORAGE_WRITE_REQ` (`0Fh`)

Payload length: 134 bytes.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | sequence byte |
| 1 | 1 | drive number |
| 2 | 1 | LBA byte 0, least significant |
| 3 | 1 | LBA byte 1 |
| 4 | 1 | LBA byte 2 |
| 5 | 1 | LBA byte 3, most significant |
| 6 | 128 | record data |

On success, the proxy writes exactly 128 bytes.

### Write Reply

Packet type: `PACKET_STORAGE_WRITE_REPLY` (`10h`)

Payload length: 2 bytes.

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | sequence byte |
| 1 | 1 | status |

Status `00h` means success. Any nonzero status is an error.

## Storage Transaction Rules

The current BIOS backend supports only drive A (`drive=0`). Other drive values
are errors at the proxy protocol level and are not selected by the CP/M BIOS
facade.

The LBA field is unsigned little-endian. The current image uses valid LBAs
`0..65535`.

The BIOS sequence byte skips zero when it allocates a new transaction sequence.
Reply parsing requires:

- valid frame sync
- valid CRC
- expected packet type
- expected payload length
- matching sequence byte
- status byte equal to `00h`

Any mismatch sets the transaction error flag and returns CP/M BIOS error.

During storage transactions, the backend temporarily replaces the normal
console RX sink with the storage reply parser. After completion or error it
restores the console sink and the saved RTS state.

## Size Requirements

The proxy and parser must accept at least:

| Packet | Payload bytes | Framed bytes including sync |
|---|---:|---:|
| Read request | 6 | 11 |
| Read reply | 130 | 135 |
| Write request | 134 | 139 |
| Write reply | 2 | 7 |

The BIOS uses `MOVE_BUFFER` as transaction scratch. It is currently 192 bytes,
which covers the largest current storage request payload.

## Maintenance Notes

Protocol changes must be synchronized across:

- `src/cbios_console_vdrip.asm`
- `src/cbios_storage_vdrip.asm`
- `src/virtual_drip_protocol.inc`
- the Virtual Drip proxy implementation

Do not reuse existing packet type values. Append new values after the current
range unless there is an explicit compatibility plan.
