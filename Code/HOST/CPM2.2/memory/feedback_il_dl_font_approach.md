---
name: feedback-il-dl-font-approach
description: IL/DL implementation worked; font-in-bank0-TPA approach confirmed correct
metadata:
  type: feedback
---

IL/DL (CSI L / CSI M insert/delete line) was implemented and confirmed working, including with Turbo Pascal 3.

Font move to bank-0 TPA (0x8000) is the correct approach for this system. Bank-1 switching was abandoned because the bank port encoding for bank-1 selection was more complex than expected (COPY_LATCH formula vs simple bit fields). The proven pattern — COPY_LATCH0 for low-area ROM reads, matching restore_ccp_from_rom — is the right idiom.

**Why:** IL/DL needed 352 bytes but only 9 bytes were free before the VDrip storage backend. Moving the 768-byte font freed 768 bytes, giving 395 bytes of headroom.

**How to apply:** For any future need to read from bank-0 low area (0x0000-0xBFFF) in ROM: use COPY_LATCH0 = SHADOW_BIT = 0x08. For common area (C000h+): use ROM_VISIBLE_BANK0 = 0x00. Do not try to derive bank-1 ROM-visible values without checking the IOController hardware encoding first.
