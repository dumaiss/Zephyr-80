; CP.COM -- copy a file.
;
; The same copy MV performs, without the delete at the end.  It works within a
; drive and between drives, and between the two volume types in either
; direction, because it moves the file through ordinary BDOS record calls that
; both of them answer.
;
; Usage: CP OLD NEW, or CP FILE C:  to copy to another drive keeping the name.

	.module cp
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_PRINT = 9
BDOS_OPEN = 15
BDOS_CLOSE = 16
BDOS_READ_SEQ = 20
BDOS_WRITE_SEQ = 21
BDOS_MAKE = 22
BDOS_GET_DRIVE = 25
BDOS_SETDMA = 26
FCB1 = 0x005c
FCB2 = 0x006c
CMDTAIL = 0x0080

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld a,(CMDTAIL)
	or a
	jp z,usage
	; "CP FILE C:" names a drive and no file, which keeps the name -- so an
	; empty second name is only a usage error when no drive came with it.
	ld a,(FCB2 + 1)
	cp #' '
	jr nz,have_second
	ld a,(FCB2)
	or a
	jp z,usage
have_second:
	ld c,#BDOS_GET_DRIVE
	call BDOS
	inc a				; FCB drives are one-based
	ld (current),a
	ld a,(FCB1)
	or a
	jr nz,src_have
	ld a,(current)
src_have:
	ld (src_drive),a
	ld a,(FCB2)
	or a
	jr nz,dst_have
	ld a,(current)
dst_have:
	ld (dst_drive),a
	; Copying a file onto itself would truncate it through the MAKE and then
	; read back what it had just emptied.
	ld hl,#src_drive
	ld a,(dst_drive)
	cp (hl)
	jr nz,build
	ld a,(FCB2 + 1)
	cp #' '
	jr z,same_file			; no second name, so it is the same name
	ld hl,#FCB1 + 1
	ld de,#FCB2 + 1
	ld b,#11
same_scan:
	ld a,(de)
	cp (hl)
	jr nz,build
	inc hl
	inc de
	djnz same_scan
same_file:
	ld de,#txt_same
	jr report
build:
	call build_copy_fcbs
	call copy_file
	or a
	jr nz,copy_failed
	ld de,#txt_copied
	jr report
copy_failed:
	ld hl,#copy_messages
	dec a
	add a,a
	ld e,a
	ld d,#0
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	jr report
usage:
	ld de,#txt_usage
report:
	ld c,#BDOS_PRINT
	call BDOS
	ld sp,(entry_sp)
	ret

; Source from FCB1, destination from FCB2 -- and an empty second name means
; the copy keeps the source's own.
build_copy_fcbs:
	call clear_fcb
	ld a,(src_drive)
	ld (fcb),a
	ld hl,#FCB1 + 1
	ld de,#fcb + 1
	ld bc,#11
	ldir
	call clear_fcb2
	ld a,(dst_drive)
	ld (fcb2),a
	ld hl,#FCB2 + 1
	ld a,(hl)
	cp #' '
	jr nz,dst_named
	ld hl,#FCB1 + 1
dst_named:
	ld de,#fcb2 + 1
	ld bc,#11
	ldir
	ret

copy_messages:
	.dw txt_no_open, txt_no_make, txt_no_write, txt_no_read, txt_no_close

clear_fcb:
	ld hl,#fcb
	ld b,#36
	jr clear_run
clear_fcb2:
	ld hl,#fcb2
	ld b,#36
clear_run:
	xor a
clear_loop:
	ld (hl),a
	inc hl
	djnz clear_loop
	ret

txt_usage:    .ascii "Usage: CP OLD NEW\r\n$"
txt_copied:   .ascii "Copied\r\n$"
txt_same:     .ascii "CP: source and destination are the same file\r\n$"
txt_no_open:  .ascii "CP: cannot open the source file\r\n$"
txt_no_make:  .ascii "CP: cannot create the destination\r\n$"
txt_no_write: .ascii "CP: write failed (disk full?)\r\n$"
txt_no_read:  .ascii "CP: read failed\r\n$"
txt_no_close: .ascii "CP: cannot close the destination\r\n$"

entry_sp:   .dw 0
current:    .db 0
src_drive:  .db 0
dst_drive:  .db 0
fcb:        .ds 36
fcb2:       .ds 36
recbuf:     .ds 128
	.ds 128
stack_top:

	.include "copyfile.inc"

	.include "zbdos.inc"
