; Shared body for MKDIR.COM and RMDIR.COM.
;
; The two differ only in the native op they issue and the words they print, so
; the body lives here instead of in two files that would drift apart the first
; time one of them was fixed.  The including file defines DIR_OP and the three
; message labels, and provides dir_op as a data byte -- an equate would need
; the value during pass 1, and zbdos.inc is not included until the end.

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld a,(CMDTAIL)
	or a
	jr z,usage
	ld c,#BDOS_GET_DRIVE
	call BDOS
	cp #FAT_DRIVE
	jr nz,wrong_volume
	ld hl,#desc
	ld b,#ZN_DESC_BYTES
	xor a
clear_desc:
	ld (hl),a
	inc hl
	djnz clear_desc
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	ld hl,#FCB1 + 1
	ld de,#desc + ZN_NAME
	ld bc,#11
	ldir
	ld a,(dir_op)
	ld (desc + ZN_OP),a
	ld de,#desc
	call zb_native
	jr nz,failed
	ld de,#txt_ok
	jr report
usage:
	ld de,#txt_usage
	jr report
wrong_volume:
	ld de,#txt_no_dirs
report:
	ld c,#BDOS_PRINT
	call BDOS
	jr finish
failed:
	push af
	ld de,#txt_failed
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	push af
	rra
	rra
	rra
	rra
	call print_nibble
	pop af
	call print_nibble
	ld de,#txt_crlf
	ld c,#BDOS_PRINT
	call BDOS
finish:
	ld sp,(entry_sp)
	ret

print_nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
	ld e,a
	ld c,#2
	jp BDOS

txt_no_dirs: .ascii "Not a FAT volume: CP/M drives have no directories\r\n$"
txt_crlf:    .ascii "\r\n$"

entry_sp:  .dw 0
desc:      .ds 32
	.ds 96
stack_top:

; The including file supplies its messages and then includes zbdos.inc: a
; nested .include does not resolve here, so it has to be the outer file that
; pulls the BDOS shim in.
