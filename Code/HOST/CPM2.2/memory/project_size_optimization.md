---
name: project-size-optimization
description: BIOS size optimization pass; 341 bytes reclaimed in console driver slot; new end at 0xF52B
metadata:
  type: project
---

Aggressive dead-code removal pass on `src/cbios_console_vdrip.asm`.

**Why:** The driver slot was 100% full (VDRIP_CONSOLE_CODE_END = 0xF680, IOCALL starts at F680h, zero slack). Needed headroom for future terminal features.

**How to apply:** The slot now has 341 bytes free (0xF52B–0xF67F inclusive). The primary targets (framed RX parser, dead pace function, diagnostic counters) have been removed. Remaining call/ret→jp conversions (~12+ instances) were intentionally left in place for readability. Next feature additions can proceed without needing another size pass first.

## What changed

- Removed: inactive framed proxy→Z80 RX parser (`vdrip_parse_rx_byte` and all helpers, ~238 bytes of code).
- Removed: `vdrip_tx_pace` function (0 callers, 11 bytes).
- Removed: diagnostic counters `crc_fail_count`, `packet_ok_count`, `key_echo_count` (dead), `rts_assert_count`, `rts_release_count`, `textq_drop_count` (21 bytes code + 6 bytes data + 18 bytes init).
- Removed: associated state variables `vdrip_parse_state`, `vdrip_packet_body`, `terminal_payload_ptr/count` (26 bytes data).
- Removed: constants `VDRIP_TX_PACE_DELAY`, `VDRIP_PACKET_BODY_MAX` (equates, 0 BIOS bytes, but cleaned up).
- Restored: `VDRIP_PACKET_PAYLOAD_MAX` (still used by VIDEO_SEND validation in cbios_bios_ext.asm).
- Peepholes: 7× call/ret→jp in CSI/ED/EL dispatchers; xor a/ld b,a for text_init_vdp R0 init (9 bytes).

## Memory impact

| Symbol | Before | After |
|---|---:|---:|
| `VDRIP_CONSOLE_CODE_END` | `F680h` | `F52Bh` |
| Free bytes before IOCALL | 0 | **341** |
