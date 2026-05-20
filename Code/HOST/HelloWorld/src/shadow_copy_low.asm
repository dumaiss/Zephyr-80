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
