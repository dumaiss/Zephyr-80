---
name: feedback-il-dl-font-approach
description: IL/DL implementation worked; font-in-bank0-TPA approach confirmed correct
metadata:
  type: feedback
---

IL/DL (CSI L / CSI M insert/delete line) was implemented and confirmed working, including with Turbo Pascal 3.

Font move to bank-0 TPA (0x8000) is the correct approach for this system. Bank-1 switching was abandoned because the bank port encoding for bank-1 selection was more complex than expected. Note that ROM page 1 now backs drive A:, so a font page there is no longer available at all.

**Why:** IL/DL needed 352 bytes but only 9 bytes were free before the VDrip storage backend. Moving the 768-byte font freed 768 bytes, giving 395 bytes of headroom.

**How to apply:** The constant names in this note are obsolete as of MEM_DECODER.pld revision 12. `COPY_LATCH0`/`SHADOW_BIT` = 0x08 is now `MEM_MODE_FLAT`, a flat SRAM bank with **no ROM mapped at all** — using it for a ROM read would read SRAM. To read ROM page `p` while writing SRAM bank `b`, use `MEM_MODE_ROM` (0x00) with `(p << ROM_PAGE_SHIFT) | b`; that works across the whole address space, with no split and no forced region. Constants are in `src/memory_modes.inc`. Remember that mode 00 reads ROM for instruction fetches and stack reads too, so such a window must be stackless and must execute where ROM and SRAM hold identical bytes.
