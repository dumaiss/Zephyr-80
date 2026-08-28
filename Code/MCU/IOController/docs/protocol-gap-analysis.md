# Proposed versus implemented IOC transport

The proposal in `Zephyr-80_IOCALL_Simplified_Two-Lane_Transport.md` was used as
architecture input, not as executable instructions. This matrix records the
implementation choices so future work does not confuse proposed and shipped
behavior.

| Proposal | Implemented | Reason |
|---|---|---|
| one protocol on both lanes | yes | shared A5/5A packet, metadata and CRC |
| persistent External Sync | yes | `/SYNC` held low; Hunt once; RX retained |
| Auto Enables off | yes | `/DCD` cannot disable RX and destroy sync |
| `A5 5A` packet marker | yes | scanned as a pair on every receive path |
| 16-bit LEN | yes | counts TYPE+SEQ+STATUS+DATA |
| TYPE and 8-bit SEQ | yes | bulk metadata bound to its READY reply |
| STATUS | explicit fixed byte | lossless mapping to existing mailbox byte 2 |
| CRC-16-CCITT | yes, software | isolates packet correctness from SIO CRC timing |
| command payload 32 | 26 DATA bytes | preserves 32-byte BIOS mailbox ABI |
| bulk payload 256 | 512 DATA bytes | one SD sector per packet |
| remove 32-byte wire quantum | yes | wire packet length is declared |
| remove READY/DONE | no | retained for storage ABI and commit semantics |
| parser starts at byte zero | no | bounded marker scan handles SIO pipeline and TX phase |
| asynchronous event lane | not implemented here | current traffic remains solicited/polled |

The remaining work is performance or feature work, not a known framing gap:

- optional hardware CRC after proving it produces the identical wire FCS;
- bounded bursts if interrupt blackout during 512-byte Bulk streams becomes
  unacceptable; and
- asynchronous event dispatch if a future packet type needs it.

Current paired versions are BIOS transport `07h` and controller firmware
`13h`. See [two-lane-transport.md](two-lane-transport.md) for the authoritative
contract.
