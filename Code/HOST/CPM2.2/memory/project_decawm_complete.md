---
name: project-decawm-complete
description: DECAWM auto-wrap (ESC [ ? 7 h/l) implemented in cbios_console_vdrip.asm; memory impact and fit strategy.
metadata:
  type: project
---

DECAWM auto-wrap mode added to the VDrip console driver in `src/cbios_console_vdrip.asm`.

**Why:** ESC [ ? 7 h/l needed for VT100-compatible terminal emulation in CP/M applications.

**How to apply:** If further features are needed in the console driver, the slot is now completely full (0 free bytes). An aggressive optimization pass is planned after testing. Primary target: the inactive framed RX parser (`vdrip_parse_rx_byte` and friends), which is explicitly marked obsolete and is estimated at 200+ bytes. Secondary targets: any remaining `call X / ret` tails, redundant reload patterns. Do not attempt the pass until the user has validated the current build on hardware.

## What changed

- New state variable: `term_auto_wrap` at `0xF663` (`.db 0x01` — default enabled).
- `ansi_decset`: added `cp #7 / jr z,ansi_decawm_on` before the existing `cp #25` check.
- `ansi_decrst`: added `cp #7 / jr z,ansi_decawm_off` before the existing `cp #25` check.
- New handlers `ansi_decawm_on` / `ansi_decawm_off` / `ansi_decawm_set` (combined, 9 bytes).
- `text_advance_cursor`: checks `term_auto_wrap` at the right-margin branch; wraps if enabled, clamps to column 79 if disabled.
- `vdrip_console_init`: sets `term_auto_wrap = 1` alongside `vdrip_terminal_ready_flag`.
- `vdrip_reset_display` (ESC c): sets `term_auto_wrap = 1` alongside `vdrip_rx_rts_released`.

## Memory fit

Prior headroom: 32 bytes (F660–F67F). New code + data = +35 bytes. Recovered 3 bytes by converting three `call X / ret` tails to `jp X`:
- `vdrip_cursor_init`
- `ansi_show_cursor`
- `ansi_hide_cursor`

`VDRIP_CONSOLE_CODE_END` moved from `0xF660` to `0xF680` (= IOCALL start). Last console driver byte is `0xF67F`. Zero overlap, zero slack.
