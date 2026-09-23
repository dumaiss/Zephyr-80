; LS.COM -- list a directory, including the subdirectories a FAT volume has.
;
; The CCP's resident DIR lists CP/M files and cannot show a directory, because
; a fixed-geometry CP/M volume has none.  The FAT-backed drive does, so this
; marks them and shows file sizes alongside, and falls back to an ordinary
; CP/M SEARCH on the conventional drives so the same command works anywhere.
;
; Sizes are shown only on the FAT volume.  READDIR returns the size with the
; entry, so it costs nothing there; on a CP/M volume it would mean a BDOS 35
; per name, and function 35 between a SEARCH FIRST and its SEARCH NEXT breaks
; the enumeration.  Names alone is what DIR gives on those drives anyway.
;
; Usage: LS, or LS *.COM to filter.

	.module ls
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_SEARCH_FIRST = 17
BDOS_SEARCH_NEXT = 18
BDOS_GET_DRIVE = 25
BDOS_SETDMA = 26
BDOS_RESET_DRIVE = 37
FCB1 = 0x005c
CMDTAIL = 0x0080

FAT_DRIVE = 1				; B:, zero-based as BDOS 25 reports it
FAT_DRIVE_BIT = 0x0002			; function 37 vector bit for B:
FS2_ATTR_DIR = 0x10			; as ZREADDIR reports it in ZN_FLAGS

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call build_pattern
	ld c,#BDOS_GET_DRIVE
	call BDOS
	cp #FAT_DRIVE
	jr z,ls_fat
	jp ls_cpm

; ---------------------------------------------------------------------------
; FAT volume: real directories, and a size with every entry.
; ---------------------------------------------------------------------------
ls_fat:
	call op_begin
	ld a,#ZN_OPENDIR
	call do_op
	jp nz,failed
ls_fat_loop:
	call op_begin
	ld a,#ZN_READDIR
	call do_op
	jr z,ls_fat_entry
	cp #ZN_ERR_END
	jr z,ls_fat_done
	push af
	call release_dir
	pop af
	jp failed
ls_fat_entry:
	ld hl,#desc + ZN_NAME
	call match_pattern
	jr nz,ls_fat_loop
	ld hl,#desc + ZN_NAME
	call print_name
	ld a,(desc + ZN_FLAGS)
	and #FS2_ATTR_DIR
	jr z,ls_fat_file
	ld de,#txt_dir
	call print
	ld hl,#dir_count
	inc (hl)
	jr ls_fat_loop
ls_fat_file:
	ld hl,(desc + ZN_POSITION)
	ld de,(desc + ZN_POSITION + 2)
	call print_size
	ld hl,#file_count
	inc (hl)
	jr ls_fat_loop
ls_fat_done:
	call release_dir
	jp summary

; There is no native CLOSEDIR, and the controller has a single directory slot
; that CP/M's own SEARCH also uses.  Leaving it open makes the next DIR on
; this drive fail with "no handle".  Function 37 resets the drive, which the
; FAT backend answers by dropping every open context, this one included.
release_dir:
	ld de,#FAT_DRIVE_BIT
	ld c,#BDOS_RESET_DRIVE
	jp BDOS

; ---------------------------------------------------------------------------
; Conventional CP/M volume: names only, one per file rather than per extent.
; ---------------------------------------------------------------------------
ls_cpm:
	ld de,#dmabuf
	ld c,#BDOS_SETDMA
	call BDOS
	ld hl,#fcb
	ld b,#36
	xor a
ls_cpm_clear:
	ld (hl),a
	inc hl
	djnz ls_cpm_clear
	ld hl,#pattern
	ld de,#fcb + 1
	ld bc,#11
	ldir
	ld c,#BDOS_SEARCH_FIRST
	ld de,#fcb
	call BDOS
ls_cpm_check:
	cp #0xff
	jr z,summary
	; The reply names a 32-byte slot in the DMA: entry = dmabuf + A * 32.
	and #3
	ld l,a
	ld h,#0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,#dmabuf
	add hl,de
	push hl
	ld de,#12
	add hl,de			; EX
	ld a,(hl)
	and #0x1f
	pop hl
	or a
	jr nz,ls_cpm_next		; a later extent of a file already listed
	inc hl				; the packed name
	call print_name
	ld de,#txt_crlf
	call print
	ld hl,#file_count
	inc (hl)
ls_cpm_next:
	ld c,#BDOS_SEARCH_NEXT
	ld de,#fcb
	call BDOS
	jr ls_cpm_check

; ---------------------------------------------------------------------------
summary:
	ld a,(file_count)
	call print_dec
	ld de,#txt_files
	call print
	ld a,(dir_count)
	or a
	jr z,summary_end
	call print_dec
	ld de,#txt_dirs
	call print
summary_end:
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

; ---------------------------------------------------------------------------
; A bare LS lists everything.  So does a command whose tail parsed to an empty
; name -- "LS B:" names a drive, not a file.
; ---------------------------------------------------------------------------
build_pattern:
	ld a,(CMDTAIL)
	or a
	jr z,pattern_all
	ld hl,#FCB1 + 1
	ld de,#pattern
	ld bc,#11
	ldir
	ld hl,#pattern
	ld b,#11
pattern_scan:
	ld a,(hl)
	cp #' '
	jr nz,pattern_done
	inc hl
	djnz pattern_scan
pattern_all:
	ld hl,#pattern
	ld b,#11
	ld a,#'?'
pattern_fill:
	ld (hl),a
	inc hl
	djnz pattern_fill
pattern_done:
	ret

; HL = packed 8.3 name.  Z when it matches; '?' matches anything.
match_pattern:
	ld de,#pattern
	ld b,#11
match_loop:
	ld a,(de)
	cp #'?'
	jr z,match_next
	ld c,a
	ld a,(hl)
	and #0x7f			; attribute bits are not part of the name
	cp c
	ret nz
match_next:
	inc hl
	inc de
	djnz match_loop
	xor a
	ret

; HL = packed 8.3 name.  Prints "NAME    .EXT".
print_name:
	ld b,#8
	call print_run
	ld e,#'.'
	call conout
	ld b,#3
print_run:
	ld a,(hl)
	and #0x7f
	push hl
	push bc
	ld e,a
	call conout
	pop bc
	pop hl
	inc hl
	djnz print_run
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

; DE:HL = byte size.  Prints it right-aligned in KiB, rounded up.
print_size:
	ld bc,#1023
	add hl,bc
	jr nc,size_no_carry
	inc de
size_no_carry:
	ld b,#10
size_shift:
	srl d
	rr e
	rr h
	rr l
	djnz size_shift
	ld a,d
	or e
	jr z,size_ready
	ld hl,#0xffff			; larger than this program can render
size_ready:
	call print_dec5
	ld de,#txt_kb
	jp print

; HL = value.  Five columns, leading zeros suppressed.
print_dec5:
	xor a
	ld (dec_started),a		; per number, or only the first is padded
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
	jp conout_a
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
	ld a,(dec_started)
	or a
	jr nz,print_digit_out
	ld e,#' '
	jr conout_a
print_digit_out:
	ld a,#1
	ld (dec_started),a
	ld a,b
	add a,#'0'
	ld e,a
conout_a:
	push hl
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ret

; A = 0..255, printed without padding.
print_dec:
	ld l,a
	ld h,#0
	xor a
	ld (dec_started),a
	push hl
	ld de,#100
	call print_digit
	ld de,#10
	call print_digit
	ld a,l
	add a,#'0'
	ld e,a
	call conout_a
	pop hl
	ret

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
	jp conout_a

; ---------------------------------------------------------------------------
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

txt_dir:    .ascii "  <DIR>\r\n$"
txt_kb:     .ascii "K\r\n$"
txt_files:  .ascii " file(s)$"
txt_dirs:   .ascii " dir(s)$"
txt_crlf:   .ascii "\r\n$"
txt_failed: .ascii "LS failed: $"

entry_sp:    .dw 0
file_count:  .db 0
dir_count:   .db 0
dec_started: .db 0
pattern:     .ds 11
fcb:         .ds 36
desc:        .ds 32
dmabuf:      .ds 128
	.ds 128
stack_top:

	.include "zbdos.inc"
