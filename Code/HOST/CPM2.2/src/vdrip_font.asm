; VDrip CP850 6x8 font ROM image — optional bank payload.
;
; Assembled separately from the main BIOS image to produce build/vdrip_font.bin.
; This standalone image is not currently placed by the builder: no payload
; section references it, and ROM pages 1-3 back drive A:.  The font the VDrip
; console actually uses is assembled into the page-0 firmware image at
; VDRIP_FONT_ROM_BASE by cbios_console_vdrip.asm, and cold boot installs it in
; SRAM bank 0 with the rest of that page.  If a separate font page is ever
; wanted again it needs its own ROM page outside the drive-A range and an
; explicit payload entry in config/banks.ini.

	.module vdrip_font

	.area CODE (ABS)
	.org 0x0100	; VDRIP_FONT_ROM_BASE

	.include "font_cp850_6x8.inc"
