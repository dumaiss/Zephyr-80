---
name: project-il-dl-complete
description: CSI L/M Insert/Delete Line and font-to-bank0 move completed and verified
metadata:
  type: project
---

Both CSI n L (Insert Line) and CSI n M (Delete Line) are implemented in src/cbios_console_vdrip.asm and verified working with Turbo Pascal 3.

Font data moved from inline driver code to bank-0 TPA at 0x8000 (VDRIP_FONT_ROM_BASE) in the firmware binary to make room. restore_font_from_rom (called from wboot_resident) refreshes the TPA font from ROM before warm-boot console init; as of decoder revision 12 it uses `MEM_MODE_ROM`, not the old `COPY_LATCH0`.

ROM image was simplified to 2 banks (IMAGE_BANK_COUNT=2) at the time. It is now 8 pages: page 0 and page 7 are boot images, pages 1-3 back drive A:, pages 4-6 are unused.

**Why:** Turbo Pascal 3 required IL/DL for its screen editor. The driver had no room until the font was relocated.

**How to apply:** If adding more terminal sequences, there are now ~395 bytes free before the VDrip storage backend (F660h vs F7EBh). The text_redraw_rows helper exists for partial-screen redraws.
