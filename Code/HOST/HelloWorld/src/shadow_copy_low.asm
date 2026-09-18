; ==========================================================================
; HISTORICAL -- targets MEM_DECODER.pld revision 11 or earlier.
;
; This code uses the pre-revision-12 latch semantics, where D3 (RAM_SHADOW) and
; D4 (ROM_DIS) were feature flags and shadow/copy mode left C000h-FFFFh as SRAM
; bank 0.  Revision 12 replaced them with two mode-selector bits: D4:D3 = 01 is
; now a flat SRAM bank with no ROM mapped at all, so the copy sequence here
; reads SRAM instead of ROM and will not populate RAM.
;
; Kept as a record of the earlier hardware.  Do not run it on revision 12.
; See Memory Management.md for the current four-mode model.
; ==========================================================================
; Standalone assembly wrapper for shadow_copy_low.inc.
;
; This is mainly a build check and reference for including the low-memory
; routine. Real users should include shadow_copy_low.inc at 0000h and place
; their RAM-resident continuation immediately after it.

	.module shadow_copy_low
	.area CODE (ABS)
	.org 0x0000

	.include "src/shadow_copy_low.inc"

shadow_copy_low_hold:
	jr shadow_copy_low_hold
