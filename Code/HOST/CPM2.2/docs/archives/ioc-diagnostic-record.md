# IOC Link Failure Record

Status: **implemented.** The BIOS fills this record as described, at
`ZBIOS_XPORT_LEVEL` `08h`. The 36-byte block under "Superseded layout" is what
levels up to `07h` wrote.

This is the shared contract between the BIOS and the CP/M diagnostic tools for
the fixed-address record that says why the IO Controller link last failed.

## Authorities

| File | Role |
|---|---|
| `src/cbios_defs.inc` | **Authority.** Offsets, sizes, lane codes, reason codes. |
| `../HelloWorld/src/ioc_diag_record.inc` | Mirror for CP/M tools. Absolute addresses derived from the same layout. |
| This document | Rationale and the rules a reader must follow. |

## Why the record exists at a fixed address

`PING.COM` asks the controller for its health over the link. When the link
itself is broken, that reply never arrives, and the question "why" has no other
answer. The record is written by the BIOS into a fixed RAM address on the
failure path, so a `.COM` can read it with `ld a,(nnnn)` and report it without
any working transport.

That property constrains everything else: the record must never move without a
version bump, must never require a reply to read, and must stay small enough
that a tool can print it in a few lines when nothing else works.

## Scope

The record describes **the last transport failure, on either lane, whichever
happened most recently.** It is not a history, not a counter set, and not a
running log.

Two rules follow, and a reader that breaks either will misreport:

1. **No field means anything without `STATUS` and `LANE`.** `RR0`/`RR1` come
   from the lane named at `+01h`. `IOC_XPORT_BAD_CRC` is reachable from both
   lanes, so the status code alone cannot tell you which SIO those register
   values describe.
2. **`STATUS` = `00h` means no failure has been recorded**, not "a failure with
   status zero". Every other field is stale in that state and must not be
   printed as current.

## Layout

Sixteen bytes at `CBIOS_IOC_DIAG_BASE` (`DCC0h`). One row of a hex dump, and it
leaves `DCD1h-DD0Fh` — 63 contiguous bytes, after `ioc_bulk_synced` at
`DCD0h` — free for the core-BIOS repack in W5.

| Offset | Field | Meaning |
|---:|---|---|
| `+00h` | `STATUS` | Last `IOC_XPORT_*` status. `00h` = none recorded. |
| `+01h` | `LANE` | `00h` command (SIO1/B), `01h` bulk (SIO1/A). Names the source of `RR0`/`RR1`. |
| `+02h` | `BULK_REASON` | `IOC_BULK_REASON_*` rejection stage; `00h` if the failure was not a bulk packet rejection. |
| `+03h` | `RR0` | Failing lane's RR0. **Bit 4 is Sync/Hunt: 1 = still hunting**, i.e. the MCU's falling `/SYNC` edge never landed. |
| `+04h` | `RR1` | Failing lane's RR1 (receive error latches). |
| `+05h` | `READY` | `ioc_link_ready`. |
| `+06h` | `SYNCED` | `ioc_rx_synced` — command lane character sync. |
| `+07h` | `BULK_SYNCED` | `ioc_bulk_synced` — the bulk lane has completed at least one CRC-verified transfer, the only evidence its character boundary was ever established. Sticky state, so it is meaningful on a command failure too. |
| `+08h` | `SEQ` | `ioc_seq` at failure. |
| `+09h` | `BULK_TYPE` | `ioc_bulk_rx_type` — transfer identity the data phase was bound to. |
| `+0Ah` | `BULK_SEQ` | `ioc_bulk_rx_seq`. |
| `+0Bh` | `BULK_STATUS` | STATUS byte of the rejected bulk header; `00h` if never read. |
| `+0Ch`-`+0Fh` | reserved | Read as zero. Assign no meaning. |

### Field order is load-bearing

Two pairs are adjacent because the capture code writes them as 16-bit stores,
and slot 3 had no bytes to spare for the byte-at-a-time form:

- **`LANE` + `BULK_REASON`** — the command lane sets both to zero with one
  `ld (nn),hl`. Clearing `BULK_REASON` is what stops an older bulk rejection
  standing beside a command failure as though it belonged to it.
- **`READY` + `SYNCED`** — in the same order as `ioc_link_ready` /
  `ioc_rx_synced` in BIOS memory, so both copy with one `ld hl,(nn)` and one
  `ld (nn),hl`.

Both adjacencies, and the record's total size, are asserted at assembly time in
`src/cbios_bank.asm` and `src/cbios_ioc_command.asm`. Breaking one is a build
failure, not a silently wrong report.

`BULK_TYPE`/`BULK_SEQ` are kept as a pair because together they are what stops a
delayed data phase being accepted by a newer command. `BULK_STATUS` is kept
because on a write it is the only evidence the card committed — receiving the
bytes is not.

### Bulk rejection stages

| Value | Name | Stage |
|---:|---|---|
| `00h` | `IOC_BULK_REASON_NONE` | Not a bulk rejection. |
| `01h` | `IOC_BULK_REASON_INPUT` | Invalid caller length. |
| `02h` | `IOC_BULK_REASON_MARKER` | `A5 5A` never found within the scan. |
| `03h` | `IOC_BULK_REASON_LEN` | Header LEN mismatch. |
| `04h` | `IOC_BULK_REASON_TYPE` | Header TYPE mismatch. |
| `05h` | `IOC_BULK_REASON_SEQ` | Header SEQ mismatch. |
| `06h` | `IOC_BULK_REASON_STATUS` | Header carried a nonzero status. |
| `07h` | `IOC_BULK_REASON_CRC` | CRC mismatch. |

These values are already emitted by the `IOCBULK` reject paths. Freezing them
here promotes them from literals in a source comment to protocol.

## Versioning

The record carries **no version byte**. `ZBIOS_XPORT_LEVEL`, readable from ROM
at `ZBIOS_XPORT_LEVEL_ADDR` (`DF7Ah`), governs it.

A tool **must** check that the running BIOS reports at least
`IOC_DIAG_RECORD_MIN_XPORT_LEVEL` (`08h`) before decoding these offsets, and
must say plainly that it cannot decode the record otherwise. Printing fields it
cannot vouch for is the failure mode this whole document exists to prevent.

The record's arrival was an incompatible layout change, so it bumped
`ZBIOS_XPORT_LEVEL` from `07h` to `08h` in the same commit, updating
`src/cbios_defs.inc` and `../HelloWorld/src/ioc_levels.inc` together. Any future
change to these offsets must do the same.

## Superseded layout

The 36-byte block at `DCC0h`-`DCE3h` written by `ZBIOS_XPORT_LEVEL` `07h` and
earlier. Recorded here so a tool meeting an older BIOS can still be understood.

```
+00      RR0 at failure (bit 4 = still hunting)
+01      RR1
+02      ioc_rx_synced
+03      ioc_link_ready
+04      command reply scan budget REMAINING
+05..0Ch command marker history, eight bytes
+0Dh     marker history index
+0Eh     bulk rejection stage
+0Fh     bulk marker-scan count on exhaustion
+10h     last bulk marker-scan byte
+11h..17h reserved
+18h..1Ch decoded bulk LEN/TYPE/SEQ/STATUS header
+1Dh..1Fh bulk RR0, RR1, verified-sync flag
+20h..23h expected bulk LEN, TYPE, SEQ
```

### The marker history has no writer

`+05h`-`+0Dh` — the eight-byte command marker history and its index — is
**never written by any code in the BIOS.** The scan loop that once filled it was
rewritten and the storage was left behind.

`PING.COM` read those nine bytes unconditionally and printed them under a label
saying they were the bytes the reply scan saw. They were zeros. On the one
report consulted when the link is dead, that is not a harmless stale field: it
is fabricated evidence, and it read as "the line was silent" regardless of what
actually happened on the wire.

This is why the field was deleted rather than retained, and it is worth
remembering as the reason the replacement is a *last-failure* record with an
explicit "nothing recorded" state, rather than a set of always-printed slots.

## What each dropped field cost, and why it goes

| Dropped | Reason |
|---|---|
| Command marker history `+05h`-`+0Ch` | No writer. See above. |
| Marker history index `+0Dh` | No writer; indexes nothing. |
| Scan budget remaining `+04h` | Redundant. It separated "the reply never came" from "the reply came and the marker was missed" — and `IOC_XPORT_TIMEOUT_REPLY_MARKER` (`11h`) versus `IOC_XPORT_TIMEOUT_REPLY_BODY` (`12h`) already carry exactly that distinction in the status byte. |
| Bulk marker-scan count and last scanned byte | Question answered: the lane's character alignment is established, and `BULK_REASON` names the rejecting stage. |
| Decoded bulk LEN/TYPE/SEQ header | The mismatching field is what `BULK_REASON` already names. Only STATUS is retained. |
| Expected bulk LEN/TYPE/SEQ tuple | Recoverable from `BULK_TYPE`/`BULK_SEQ` and the request the caller issued. |

## Consumers

Four tools open-coded this layout privately. All four now include
`ioc_diag_record.inc` and were changed in the same commit as the BIOS.

| Tool | Was | Now |
|---|---|---|
| `ioc_ping.asm` | Private `IOC_DIAG_BASE = 0xDCC0`; read `+0`-`+4`, looped `+5`-`+12`, read `+13` | Reports `STATUS` first and prints nothing else when it is `00h`; bulk fields only when `BULK_REASON` is nonzero. |
| `ioc_bulk.asm` | Nine hard-coded absolutes, `0xDCCE`-`0xDCE3` | Reason, RR0/RR1, bulk-sync, transfer type/seq/status. |
| `ioc_sdrec.asm` | Same nine absolutes | Same. |
| `ioc_sdsoak.asm` | Same nine absolutes | Same. |

Four private copies of one layout is how a field moves and three of the four
keep printing the old meaning. The mirror include exists to end that.

`ioc_ping.asm` also carried the expected transport level as literal text in its
mismatch message — "(need 07)" — which `ioc_levels.inc` exists specifically to
prevent. It now prints `ZBIOS_XPORT_LEVEL_HEX_HI`/`_LO` from that file.
