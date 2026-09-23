; PWD.COM -- print the working directory.
;
; A fixed-geometry CP/M volume has no directories, so there the drive letter
; and user number ARE the whole location and that is all this prints.  The
; FAT-backed drive has a real path, read back a component at a time: the
; descriptor carries one name field and the path can be sixteen deep, so the
; native call answers with the depth and one component per request.

	.module pwd
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
BDOS_USER = 32
FAT_DRIVE = 1				; B:, zero-based as BDOS 25 reports it

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld e,#0xff
	ld c,#BDOS_USER
	call BDOS
	and #0x1f
	ld (user),a
	ld c,#BDOS_GET_DRIVE
	call BDOS
	ld (drive),a
	add a,#'A'
	ld e,a
	call conout
	ld a,(user)
	call print_dec
	ld e,#':'
	call conout
	ld a,(drive)
	cp #FAT_DRIVE
	jr nz,done			; nothing further exists to print
	; Ask for component zero: the answer carries the depth whether or not
	; there is a component to go with it.
	xor a
	call cwd_fetch
	jr nz,failed
	ld e,#'/'
	call conout
	ld a,(desc + ZN_RESULT)
	ld (depth),a
	or a
	jr z,done
	xor a
	ld (index),a
pwd_loop:
	ld a,(index)
	call cwd_fetch
	jr nz,failed
	ld hl,#desc + ZN_NAME
	call print_trim
	ld hl,#index
	inc (hl)
	ld a,(hl)
	ld hl,#depth
	cp (hl)
	jr nc,done
	ld e,#'/'
	call conout
	jr pwd_loop
done:
	ld de,#txt_crlf
	call print
	jr finish
failed:
	push af
	ld de,#txt_failed
	call print
	pop af
	call print_hex
	ld de,#txt_crlf
	call print
finish:
	ld sp,(entry_sp)
	ret

; A = component index.  Out: A = status; the descriptor holds the depth in
; ZN_RESULT and the component, when the index names one, in ZN_NAME.
cwd_fetch:
	ld c,a
	ld hl,#desc
	ld b,#ZN_DESC_BYTES
	xor a
cwd_clear:
	ld (hl),a
	inc hl
	djnz cwd_clear
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	ld a,c
	ld (desc + ZN_FLAGS),a
	ld a,#ZN_CWD
	ld (desc + ZN_OP),a
	ld de,#desc
	jp zb_native

; HL = packed 8.3.  Prints it without the padding, and without a bare dot
; when there is no extension -- directories usually have none.
print_trim:
	ld b,#8
	call print_field
	ld a,(hl)
	cp #' '
	ret z
	ld e,#'.'
	call conout
	ld b,#3
print_field:
	ld a,(hl)
	cp #' '
	jr z,print_field_next
	push hl
	push bc
	ld e,a
	call conout
	pop bc
	pop hl
print_field_next:
	inc hl
	djnz print_field
	ret

conout:
	push hl
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ret

print:
	ld c,#BDOS_PRINT
	jp BDOS

; A = 0..31, printed without padding.
print_dec:
	ld b,#0
print_dec_tens:
	cp #10
	jr c,print_dec_out
	sub #10
	inc b
	jr print_dec_tens
print_dec_out:
	ld c,a
	ld a,b
	or a
	jr z,print_dec_ones
	add a,#'0'
	ld e,a
	push bc
	call conout
	pop bc
print_dec_ones:
	ld a,c
	add a,#'0'
	ld e,a
	jp conout

print_hex:
	push af
	rra
	rra
	rra
	rra
	call print_nibble
	pop af
print_nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
	ld e,a
	jp conout

txt_crlf:   .ascii "\r\n$"
txt_failed: .ascii " (path unavailable: $"

entry_sp: .dw 0
drive:    .db 0
user:     .db 0
depth:    .db 0
index:    .db 0
desc:     .ds 32
	.ds 96
stack_top:

	.include "zbdos.inc"
