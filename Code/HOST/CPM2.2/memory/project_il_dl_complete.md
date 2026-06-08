---
name: project-il-dl-complete
description: CSI L/M Insert/Delete Line and font-to-bank0 move completed and verified
metadata:
  type: project
---

Both CSI n L (Insert Line) and CSI n M (Delete Line) are implemented in src/cbios_console_vdrip.asm and verified working with Turbo Pascal 3.

Font data moved from inline driver code to bank-0 TPA at 0x8000 (VDRIP_FONT_ROM_BASE) in the firmware binary to make room. restore_font_from_rom (called from wboot_resident) uses COPY_LATCH0 to refresh the TPA font from ROM before warm-boot console init.

ROM image simplified to 2 banks (IMAGE_BANK_COUNT=2); no ROM bank payloads (monitor and BBC BASIC are on VDrip proxy storage image). build_zephyr_image.py now accepts zero payloads.

**Why:** Turbo Pascal 3 required IL/DL for its screen editor. The driver had no room until the font was relocated.

**How to apply:** If adding more terminal sequences, there are now ~395 bytes free before the VDrip storage backend (F660h vs F7EBh). The text_redraw_rows helper exists for partial-screen redraws.
