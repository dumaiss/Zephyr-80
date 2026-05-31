; VDrip font ROM image — bank 1 payload.
;
; Assembled separately from the main BIOS image to produce build/vdrip_font.bin.
; The image builder places this binary in ROM bank 1 at address 0x0000;
; the font data begins at VDRIP_FONT_ROM_BASE (0x0100), leaving page zero
; (0x0000-0x00FF) as zero padding so LDIR restores cannot corrupt reset vectors.
;
; The boot shadow copy writes all ROM banks to SRAM on cold boot, so the font
; is available in SRAM bank 1 at VDRIP_FONT_ROM_BASE without any explicit copy.
; restore_font_from_rom (cbios_console_vdrip.asm) uses ROM_VISIBLE_BANK1 to
; refresh SRAM bank 1 from ROM at warm boot before text_load_font is called.

	.module vdrip_font

	.area CODE (ABS)
	.org 0x0100	; VDRIP_FONT_ROM_BASE

	.include "msxfont.inc"
