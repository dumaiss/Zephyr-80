; ZephyrShell CCP compatibility shim.
;
; Both traditional CCP entries reload ZSH.COM from the read-only recovery
; volume.  The shell proper is an ordinary C transient and is never constrained
; by this 2 KiB slot.  Warm boot restores this shim before entering it.

	.module zephyr_shell_ccp

CBASE                  = 0xe400
CCP_LIMIT              = 0xec00
TPA                     = 0x0100
DEFAULT_DMA             = 0x0080
NATIVE_DRIVE            = 0x01          ; B:, transitional FS2 drive
BDOS                    = 0x0005
BDOS_PRINT              = 9
BDOS_OPEN               = 15
BDOS_CLOSE              = 16
BDOS_READ_SEQ           = 20
BDOS_SELECT_DISK        = 14
BDOS_SET_DMA            = 26

	.area CODE (ABS)
	.org CBASE

	jp zshell_boot
	jp zshell_boot

zshell_boot:
	ld sp,#CCP_LIMIT
	ld de,#zshell_fcb
	ld c,#BDOS_OPEN
	call BDOS
	cp #0xff
	jr z,zshell_missing

	ld hl,#TPA
zshell_load_loop:
	; Refuse an image that would overwrite the compatibility shim while it is
	; still loading.  The C shell is expected to be comfortably smaller.
	ld de,#0x0080
	add hl,de
	ld a,h
	cp #(CBASE >> 8)
	jr nc,zshell_too_large
	push hl
	or a
	sbc hl,de
	ex de,hl
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#zshell_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	pop hl
	or a
	jr z,zshell_load_loop

	ld de,#zshell_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	ld de,#DEFAULT_DMA
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#NATIVE_DRIVE
	ld c,#BDOS_SELECT_DISK
	call BDOS
	ld sp,#0xb000
	ld hl,#0x0000
	push hl
	jp TPA

zshell_missing:
	ld de,#missing_message
	jr zshell_fatal
zshell_too_large:
	ld de,#large_message
zshell_fatal:
	ld c,#BDOS_PRINT
	call BDOS
	di
zshell_halt:
	halt
	jr zshell_halt

missing_message:
	.ascii "\r\nZephyrShell: A:ZSH.COM is missing$"
large_message:
	.ascii "\r\nZephyrShell: ZSH.COM overlaps its bootstrap$"

zshell_fcb:
	.db 1
	.ascii "ZSH     COM"
	.ds 24

CCP_CODE_END:
	.ifgt (CCP_CODE_END - zshell_boot) - (CCP_LIMIT - (CBASE + 6))
	.error 1
	.endif
