# Phase 0 Virtual Drip Storage Restoration

## Result

The BIOS now builds against the proxy's current no-CRC protocol and routes
packetized readiness and storage replies through one shared receive sink.

Static/build validation is complete. Hardware CP/M read/write validation
remains required.

## Source Changes

- Added `src/vdrip_transport.asm`.
- Updated both console backends to use the common sender and receive sink.
- Removed active backend-local CRC senders/parsers.
- Updated VDrip storage to use common decoded reply state.
- Updated `VIDEO_SEND` to preserve its public `A/HL/BC` contract while calling
  the 16-bit sender.
- Updated protocol constants, build inputs, layout definitions, and generated
  map tooling.
- No proxy source was changed.

## Wire Format

Old BIOS format:

```text
A5 5A LEN8 TYPE PAYLOAD CRC8
```

Current format:

```text
A5 5A LEN_LO LEN_HI TYPE PAYLOAD
```

`LEN` counts type plus payload. No CRC/checksum is present.

## Packet Lengths

| Packet | Payload | Declared length |
|---|---:|---:|
| `PROXY_READY` | 0 | 1 |
| `STORAGE_READ_REQ` | 6 | 7 |
| `STORAGE_READ_REPLY` | 130 | 131 |
| `STORAGE_WRITE_REQ` | 134 | 135 |
| `STORAGE_WRITE_REPLY` | 2 | 3 |

All storage records remain exactly 128 bytes. LBA remains four-byte
little-endian `track * 4 + sector`.

## Receive Ownership

`sio_core.asm` is the only SIO0/B hardware reader. It dispatches bytes to the
common `vdrip_rx_sink`.

- Default console idle mode forwards raw bytes to `textq_put_ascii`.
- PTY idle mode parses `TERMINAL_RX` and forwards payload bytes.
- Readiness mode accepts packetized `PROXY_READY`.
- Storage mode validates read/write replies.

Storage no longer registers a private sink.

## Readiness

Cold boot waits for:

```text
A5 5A 01 00 0A
```

Warm boot reuses online state. If the proxy is restarted while Zephyr-80 is
idle, reboot Zephyr-80 to receive the proxy's new one-time readiness frame.

## Sequence and Errors

- Sequence uses all byte values and wraps `FFh` to `00h`.
- Wrong-sequence replies are ignored as stale.
- Matching wrong-length replies fail.
- Nonzero storage status fails.
- `PROTOCOL_ERROR` and SIO receive errors fail and clear online state.
- Storage waits indefinitely after request transmission.

## Memory

Default `vdrip` build:

| Region | Range | Bytes |
|---|---|---:|
| Shared transport | `F680h-F8F8h` | 633 |
| Storage backend | `F900h-FA51h` | 338 |
| Remaining slot-5 slack | `FA52h-FA7Fh` | 46 |
| Transport state | `FE4Bh-FE61h` | 23 |
| Storage state through caller SP | `FE40h-FE69h` | 42 |
| SIO state start | `FE70h` | unchanged |
| Scratch start | `FA80h` | unchanged |

The storage backend remains in slot 5 but moved from `F7EBh` to `F900h` after
explicit lifecycle approval.

## Build Validation

Completed on 2026-06-20:

- Clean `make CONSOLE_DRIVER=pt_vdrip`: PASS.
- Clean default `make` (`CONSOLE_DRIVER=vdrip`): PASS.
- Assembler/linker: PASS.
- Generated image/layout validation: PASS.
- Default generated maps restored after alternate-build verification.
- No slot, scratch, runtime-state, IM2, or stack overlap reported.
- `git diff --check`: PASS.
- Source search confirms only `sio_core.asm` reads SIO0/B data.
- Source search confirms storage does not register a private RX sink.
- Active transport/storage code contains no CRC calculation or comparison.

## Hardware Validation Procedure

Hardware results are not yet confirmed.

1. Start the matching Virtual Drip proxy with the CP/M disk image.
2. Reset or power-cycle Zephyr-80.
3. Confirm the proxy sends `PROXY_READY` and BIOS startup continues.
4. At CP/M, run `DIR` repeatedly.
5. `TYPE` a known text file.
6. Load and run a known COM program.
7. Use PIP to copy a file.
8. Create a new file and write known contents.
9. Close and reopen the file.
10. Compare the contents.
11. Delete the test file.
12. Warm boot and repeat `DIR` and program load.
13. Perform multiple sequential reads.
14. Perform multiple sequential writes.
15. Hold or type keys during directory and file operations; confirm no disk
    corruption or false success.
16. Exercise sequence wrap if practical.
17. Restart the proxy, then reboot Zephyr-80; confirm fresh readiness and repeat
    `DIR`.

## Remaining Limitations

- Runtime storage correctness still requires the hardware procedure above.
- Idle-time proxy restart is not detected without a Zephyr-80 reboot.
- BIOS receive capacity is intentionally 130 payload bytes, sufficient for
  Phase 0 incoming packets but not general 1,024-byte proxy replies.
- This phase does not begin console cleanup, V9958 integration, BIOS
  modularization, banking changes, or screen-buffer removal.
