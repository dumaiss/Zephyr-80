; MV.COM -- move or rename a file.
;
; Within one drive this is a rename, which both volume types implement through
; BDOS 23 -- so the same command works on a CP/M volume and on the FAT one.
; Across drives it is a copy followed by a delete, because there is nothing
; else it could be: the two volumes share no storage.
;
; A rename on the FAT volume stays inside the current directory.  The
; controller resolves both names against the same path by design, and CP/M's
; command line has no way to express a second directory anyway.
;
; Usage: MV OLD NEW, or MV FILE C:  to move to another drive keeping the name.

	.module mv
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_PRINT = 9
BDOS_OPEN = 15
BDOS_CLOSE = 16
BDOS_DELETE = 19
BDOS_READ_SEQ = 20
BDOS_WRITE_SEQ = 21
BDOS_MAKE = 22
BDOS_RENAME = 23
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
	; "MV FILE C:" names a drive and no file, which is a move that keeps the
	; name -- so an empty second name is only a usage error when no drive
	; came with it either.
	ld a,(FCB2 + 1)
	cp #' '
	jr nz,have_second
	ld a,(FCB2)
	or a
	jp z,usage			; neither a name nor a drive: one argument
have_second:
	; An omitted drive on either side means "the current one", so resolve
	; both before comparing them.
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
	ld hl,#src_drive
	ld a,(dst_drive)
	cp (hl)
	jp nz,mv_copy

; --- same drive: a rename ---------------------------------------------------
	; BDOS 23 wants both names in one FCB: the existing one at +1 and the
	; new one at +17.
	call clear_fcb
	ld hl,#FCB1 + 1
	ld de,#fcb + 1
	ld bc,#11
	ldir
	ld hl,#FCB2 + 1
	ld de,#fcb + 17
	ld bc,#11
	ldir
	ld c,#BDOS_RENAME
	ld de,#fcb
	call BDOS
	cp #4
	jp nc,failed_rename
	ld de,#txt_renamed
	jp report

; --- different drives: copy, then delete ------------------------------------
mv_copy:
	call build_copy_fcbs
	call copy_file
	or a
	jr nz,copy_failed
	; Only now is the copy safe to stand on: the source goes last, so a
	; failure anywhere above leaves the original where it was.
	ld c,#BDOS_DELETE
	ld de,#fcb
	call BDOS
	cp #4
	jp nc,failed_delete
	ld de,#txt_moved
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
	jr report
failed_rename:
	ld de,#txt_no_rename
	jr report
failed_delete:
	ld de,#txt_no_delete
report:
	ld c,#BDOS_PRINT
	call BDOS
	ld sp,(entry_sp)
	ret

; Source from FCB1, destination from FCB2 -- and "MV FILE C:" names no file
; on the far side, so it keeps its own.
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

txt_usage:     .ascii "Usage: MV OLD NEW\r\n$"
txt_renamed:   .ascii "Renamed\r\n$"
txt_moved:     .ascii "Moved\r\n$"
txt_no_rename: .ascii "MV: rename failed (name in use, or no such file)\r\n$"
txt_no_open:   .ascii "MV: cannot open the source file\r\n$"
txt_no_make:   .ascii "MV: cannot create the destination\r\n$"
txt_no_write:  .ascii "MV: write failed; the original is untouched\r\n$"
txt_no_read:   .ascii "MV: read failed; the original is untouched\r\n$"
txt_no_close:  .ascii "MV: cannot close the destination; the original is untouched\r\n$"
txt_no_delete: .ascii "MV: copied, but the original could not be removed\r\n$"

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
