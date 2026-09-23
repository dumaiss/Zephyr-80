; FSTAT.COM -- STAT for the FAT-backed volume.
;
; STAT reports a CP/M volume in terms of its fixed geometry.  That geometry is
; a compatibility fiction on the FAT drive: BDOS 27's free-space answer is
; clamped to the synthetic 8 MiB disk and says nothing true about the card.
; This asks the controller instead.
;
; Usage: FSTAT for the volume, or FSTAT NAME for one file.

	.module fstat
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
FCB1 = 0x005c
CMDTAIL = 0x0080
FAT_DRIVE = 1				; B:, zero-based as BDOS 25 reports it
FS2_ATTR_DIR = 0x10

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld c,#BDOS_GET_DRIVE
	call BDOS
	cp #FAT_DRIVE
	jr z,fstat_go
	ld de,#txt_use_stat
	call print
	jp finish
fstat_go:
	ld a,(CMDTAIL)
	or a
	jr z,fstat_volume

; --- one file ---------------------------------------------------------------
	call op_begin
	ld hl,#FCB1 + 1
	ld de,#desc + ZN_NAME
	ld bc,#11
	ldir
	ld a,#ZN_STAT
	call do_op
	jr nz,failed
	ld hl,#FCB1 + 1
	call print_name
	ld a,(desc + ZN_FLAGS)
	and #FS2_ATTR_DIR
	jr z,fstat_file_size
	ld de,#txt_dir
	call print
	jr done
fstat_file_size:
	ld de,#txt_bytes_is
	call print
	ld hl,(desc + ZN_POSITION)
	ld de,(desc + ZN_POSITION + 2)
	call print_kb
	jr done

; --- the volume -------------------------------------------------------------
fstat_volume:
	call op_begin
	ld a,#ZN_SPACE
	call do_op
	jr nz,failed
	ld de,#txt_free
	call print
	ld hl,(desc + ZN_POSITION)
	ld de,(desc + ZN_POSITION + 2)
	call print_kb
	ld de,#txt_of
	call print
	ld hl,(desc + ZN_TOTAL)
	ld de,(desc + ZN_TOTAL + 2)
	call print_kb
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

op_begin:
	ld hl,#desc
	ld b,#ZN_DESC_BYTES
	xor a
op_begin_loop:
	ld (hl),a
	inc hl
	djnz op_begin_loop
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	ret

do_op:
	ld (desc + ZN_OP),a
	ld de,#desc
	jp zb_native

; HL = packed 8.3.
print_name:
	ld b,#8
	call print_field
	ld e,#'.'
	call conout
	ld b,#3
print_field:
	ld a,(hl)
	and #0x7f
	push hl
	push bc
	ld e,a
	call conout
	pop bc
	pop hl
	inc hl
	djnz print_field
	ret

; DE:HL = byte count.  Printed in KiB, or in MiB once that would overflow the
; sixteen bits the decimal printer handles -- a card's free space is millions
; of KiB, and "512M" is the readable answer anyway.
print_kb:
	ld a,d
	or a
	jr nz,size_in_mb
	ld a,e
	cp #0x10			; 1 MiB and up reads better in MiB
	jr nc,size_in_mb
	ld bc,#1023
	add hl,bc
	jr nc,kb_no_carry
	inc de
kb_no_carry:
	ld b,#10
	call size_shift
	call print_dec16
	ld de,#txt_kb
	jp print
size_in_mb:
	ld bc,#0xffff			; round up to the next whole MiB
	add hl,bc
	jr nc,mb_no_carry
	inc de
mb_no_carry:
	ld bc,#15
	add hl,bc
	jr nc,mb_no_carry2
	inc de
mb_no_carry2:
	ld b,#20
	call size_shift
	call print_dec16
	ld de,#txt_mb
	jp print
size_shift:
	srl d
	rr e
	rr h
	rr l
	djnz size_shift
	ret

; HL = 0..65535, printed without padding.
print_dec16:
	xor a
	ld (started),a
	ld de,#10000
	call print_digit
	ld de,#1000
	call print_digit
	ld de,#100
	call print_digit
	ld de,#10
	call print_digit
	ld a,l
	add a,#'0'
	ld e,a
	jp conout
print_digit:
	ld b,#0
print_digit_loop:
	or a
	sbc hl,de
	jr c,print_digit_done
	inc b
	jr print_digit_loop
print_digit_done:
	add hl,de
	ld a,b
	or a
	jr nz,print_digit_out
	ld a,(started)
	or a
	ret z				; suppress a leading zero entirely
print_digit_out:
	ld a,#1
	ld (started),a
	ld a,b
	add a,#'0'
	ld e,a
	jp conout

conout:
	push hl
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ret

print:
	ld c,#BDOS_PRINT
	jp BDOS

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

txt_use_stat: .ascii "Not a FAT volume: use STAT on CP/M drives\r\n$"
txt_free:     .ascii "Free $"
txt_of:       .ascii " of $"
txt_kb:       .ascii "K$"
txt_mb:       .ascii "M$"
txt_bytes_is: .ascii "  $"
txt_dir:      .ascii "  <DIR>$"
txt_crlf:     .ascii "\r\n$"
txt_failed:   .ascii "FSTAT failed: $"

entry_sp: .dw 0
started:  .db 0
desc:     .ds 32
	.ds 96
stack_top:

	.include "zbdos.inc"
