; NOWRAP.ASM
; CP/M .COM utility to disable VT100 auto-wrap:
;   ESC [ ? 7 l
;
; Returns to CCP with RET, avoiding an explicit warm boot.

	.module nowrap
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_PRINT	= 0x09		; print '$'-terminated string; DE = address

start:
	ld de,#msg
	ld c,#BDOS_PRINT
	call BDOS
	ret			; return to CCP

msg:
	.db 0x1b
	.ascii "[?7l$"
