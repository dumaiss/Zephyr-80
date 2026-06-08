# Zephyr-80 BIOS Size Optimization Report

## Summary

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| `VDRIP_CONSOLE_CODE_END` | `F680h` | `F52Bh` | −341 bytes |
| Free bytes before IOCALL | 0 | **341** | +341 |

The resident console driver slot (E000h–F67Fh, 5760 bytes) was at **100% capacity**. After this pass it holds **341 bytes of headroom** before the IOCALL code at F680h.

---

## Baseline (before)

- `VDRIP_CONSOLE_CODE_END` = `F680h` (= IOCALL start; zero slack).
- Driver slot 0–4+tail: `E000h–F67Fh` fully occupied.
- Build: clean, all validation checks passing.

---

## What was removed

### Stage 2/4 — Obsolete framed RX parser (primary target)

The proxy-to-Z80 keyboard path switched from framed `PACKET_TERMINAL_INPUT` packets to raw terminal bytes. The old framed parser was explicitly marked inactive in the source but never deleted.

| Removed | Bytes |
|---|---:|
| `vdrip_parse_rx_byte` + all state-machine helpers | ~228 |
| `vdrip_parse_apply_terminal_input` + `vdrip_terminal_enqueue_loop` | included above |
| `vdrip_parse_crc_failed` (stray stub near `crc8_update`) | 10 |
| State variables: `vdrip_parse_state`, `_len_store`, `_remaining`, `_payload_index` | 4 |
| `vdrip_packet_body` buffer (`.ds VDRIP_PACKET_BODY_MAX`) | 19 |
| Obsolete payload iterator: `terminal_payload_ptr`, `terminal_payload_count` | 3 |
| Init overhead in `vdrip_rx_init` for above vars | 12 |

**Parser subtotal: ~276 bytes**

### Stage 2 — Dead function: `vdrip_tx_pace`

Zero callers. The pacing delay function was never called after the scroll path was refactored.

| Removed | Bytes |
|---|---:|
| `vdrip_tx_pace` + loop | 11 |
| Constant `VDRIP_TX_PACE_DELAY` | 0 (equate) |

**Pace subtotal: 11 bytes**

### Stage 2 — Diagnostic counters (fully dead)

Three counters were incremented only from the now-removed framed parser. Two RTS transition counters were active but purely diagnostic with no behavioral effect. The textq overflow counter was similarly diagnostic-only.

| Removed | Code | Data | Init |
|---|---:|---:|---:|
| `crc_fail_count`, `packet_ok_count`, `key_echo_count` | 0 | 3 | 9 |
| `rts_assert_count`, `rts_release_count` (from assert/release functions) | 14 | 2 | 6 |
| `textq_drop_count` (from `textq_full`) | 7 | 1 | 3 |

**Counter subtotal: 21 bytes code + 6 bytes data + 18 bytes init = 45 bytes**

### Stage 6 — Selective peephole optimizations

Only clear structural cases were converted; mass-converting the many `call vdrip_cursor_set_position_current / ret` patterns throughout the cursor movement handlers was intentionally skipped to preserve readability.

| Change | Bytes |
|---|---:|
| 2 × `call / ret` → `jp` in CSI param accumulator / dispatch | 2 |
| 5 × `call / ret` → `jp` in ED/EL clear dispatchers | 5 |
| `ld b,#0x00 / ld a,#0x00` → `xor a / ld b,a` in `text_init_vdp` R0 | 2 |

**Peephole subtotal: 9 bytes**

---

## Stage 3 — RAM disk

`cbios_storage_ramdisk.asm` already excluded from the Makefile (not linked). No changes needed; file left in place for reference.

---

## Removed symbols

All removed symbols were **module-internal** (lower-case, no external `.globl` export). No public ABI changed.

| Symbol | Reason |
|---|---|
| `vdrip_parse_rx_byte` and helpers | Framed RX parser — inactive since raw-input switch |
| `vdrip_parse_crc_failed` | Only called from above |
| `vdrip_parse_apply_terminal_input` | Only called from above |
| `vdrip_tx_pace` / `vdrip_tx_pace_loop` | Zero callers |
| `crc_fail_count`, `packet_ok_count`, `key_echo_count` | Only written by dead code |
| `rts_assert_count`, `rts_release_count` | Diagnostic-only; no behavioral effect |
| `textq_drop_count` | Diagnostic-only; no behavioral effect |
| `vdrip_parse_state` (and _len_store, _remaining, _payload_index) | Parser state — no live reader |
| `vdrip_packet_body` buffer | Parser buffer — no live reader |
| `terminal_payload_ptr`, `terminal_payload_count` | Payload iterator — no live reader |

---

## Preserved public ABI

All CP/M BIOS jump table entries preserved at original addresses (`DA00h`–`DA30h`).

All extended BIOS entries preserved:

| Entry | Address |
|---|---:|
| `MOVE` | `DA33h` |
| `XMOVE` | `DA36h` |
| `SELMEM` | `DA39h` |
| `SETBNK` | `DA3Ch` |
| `IOCALL` | `DA3Fh` / `F680h` |
| `VIDEO_SEND` | `DA42h` / `DF50h` |

All public console driver exports preserved:

- `vdrip_console_driver` (dispatch table)
- `vdrip_console_init`, `vdrip_console_const`, `vdrip_console_conin`, `vdrip_console_conout`
- `vdrip_rx_sink`, `vdrip_send_packet`, `vdrip_rts_assert_raw`, `crc8_update`
- `vdrip_reset_display`, `vdrip_data_write_block`, `restore_font_from_rom`

`VDRIP_PACKET_PAYLOAD_MAX` constant retained (used by `VIDEO_SEND` validation in `cbios_bios_ext.asm`).

---

## Known remaining size targets (deferred)

These were identified but left for a future pass:

- Many `call vdrip_cursor_set_position_current / ret` tail-calls scattered through cursor movement handlers (~12+ instances, ~12 bytes). Left intact for readability.
- `call app_maybe_resume_rts / ret` tail calls in IL/DL handlers (2 instances, 2 bytes). Left intact.
- `text_init_vdp` R1–R7 register writes could use a table-driven loop, but this is a structural change, not a peephole.
- Stale comment `rts_assert_count and rts_release_count` already removed in this pass.

---

## Validation

- Build: **PASS** (clean, no warnings, no undefined symbols).
- Layout validation: **PASS** — no overlaps, all constraints met.
- BIOS jump table: intact, unchanged.
- DPH/DPB: unchanged.
- VDrip packet constants: unchanged.
- Console driver start address: `E000h` (unchanged).
- Console driver end address: `F52Bh` (was `F67Fh`).
- Free bytes before IOCALL: **341**.
