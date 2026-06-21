; VDrip CP850 6x8 font ROM image — optional bank payload.
;
; Assembled separately from the main BIOS image to produce build/vdrip_font.bin.
; The image builder places this binary in ROM bank 1 at address 0x0000;
; the font data begins at VDRIP_FONT_ROM_BASE (0x0100), leaving page zero
; (0x0000-0x00FF) as zero padding so LDIR restores cannot corrupt reset vectors.
;
; The boot shadow copy writes all ROM banks to SRAM on cold boot, so the font
; is available in SRAM bank 1 at VDRIP_FONT_ROM_BASE without any explicit copy.
; restore_font_from_rom (cbios_console_vdrip.asm) refreshes the SRAM copy
; before the G6 atlas upload is performed.

	.module vdrip_font

	.area CODE (ABS)
	.org 0x0100	; VDRIP_FONT_ROM_BASE

	.include "font_cp850_6x8.inc"
