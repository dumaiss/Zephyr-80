; SDDIR.COM — list the controller's /SHARED/ folder.
;
; The simplest of the four tools and the one to run first: it needs no bulk
; transfer at all, so it separates "the filesystem commands work" from "the
; bulk lane works" when something is wrong.
;
;   OPENDIR, then READDIR until the MORE flag comes back zero.
;
; One entry per reply is deliberate on the controller's side: hid_host_task()
; only runs on the idle branch of its main loop, so a command that walked a
; whole directory would hold USB off for the duration and drop keystrokes.

	.module sddir
	.area CODE (ABS)
	.org 0x0100

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	; ---- OPENDIR ----
	call zero_frames
	ld a,#CMD_FS_OPENDIR
	ld (tx_frame + 0),a
	ld a,#RSP_FS_OPENDIR
	call fs_xact
	jp nz,fail

	ld hl,#0
	ld (file_count),hl

	; ---- READDIR until the listing is exhausted ----
dir_loop:
	call zero_frames
	ld a,#CMD_FS_READDIR
	ld (tx_frame + 0),a
	ld a,#RSP_FS_READDIR
	call fs_xact
	jp nz,fail

	; MORE is the end-of-directory flag: zero means this reply carries no
	; entry and the name field is blank.
	ld a,(rx_frame + 4 + 16)
	or a
	jr z,dir_done

	ld hl,#rx_frame + 4
	call print_name

	; Pad the name out to a column, so sizes line up without a format
	; routine.  print_name emitted at most twelve characters.
	ld hl,#rx_frame + 4
	call name_width
	ld a,#14
	sub b
	ld b,a
pad_loop:
	ld a,#' '
	call conout
	djnz pad_loop

	; Size, four bytes little endian.
	ld hl,#rx_frame + 4 + 12
	ld de,#dec_val
	ld bc,#4
	ldir
	call print_dec32
	call crlf

	ld hl,(file_count)
	inc hl
	ld (file_count),hl
	jr dir_loop

dir_done:
	ld de,#msg_total
	call puts
	ld hl,#file_count
	ld de,#dec_val
	ld bc,#2
	ldir
	xor a
	ld (dec_val + 2),a
	ld (dec_val + 3),a
	call print_dec32
	ld de,#msg_files
	call puts
	xor a
	ret

fail:
	call print_fail
	ld a,#1
	ret

; Characters print_name would emit for the packed name at HL, returned in B.
; Counting them is cheaper than a cursor query and does not depend on the
; console driver.
name_width:
	push hl
	ld b,#0
	ld c,#8
nw_base:
	ld a,(hl)
	cp #' '
	jr z,nw_ext
	inc b
	inc hl
	dec c
	jr nz,nw_base
nw_ext:
	pop hl
	push hl
	ld de,#8
	add hl,de
	ld a,(hl)
	cp #' '
	jr z,nw_done
	inc b				; the dot
	ld c,#3
nw_ext_loop:
	ld a,(hl)
	cp #' '
	jr z,nw_done
	inc b
	inc hl
	dec c
	jr nz,nw_ext_loop
nw_done:
	pop hl
	ret

msg_banner:	.ascii "SDDIR: /SHARED/"
		.db 13,10,'$'
msg_total:	.ascii "$"
msg_files:	.ascii " file(s)"
		.db 13,10,'$'

file_count:	.ds 2

	.include "sdfs.inc"
