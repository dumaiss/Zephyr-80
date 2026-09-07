; SDPUT.COM — copy a CP/M file into the controller's /SHARED/ folder.
;
;   SDPUT NAME.EXT        copy verbatim, padded to a record boundary
;   SDPUT NAME.EXT /T     trim the trailing 1Ah padding from the last record
;
; THE /T SWITCH IS WHY CMD_FS_CLOSE TAKES A LENGTH.
;
; A CP/M file is a whole number of 128-byte records and carries no true byte
; length; a text editor marks the end with 1Ah and leaves the rest of the last
; record as whatever it was.  Copied verbatim, that padding arrives on the host
; too.  With /T the last record is scanned for the first 1Ah and the file is
; closed at that byte, so a text file lands on the host at the length the user
; meant.  Without it nothing is trimmed, which is the only safe default for a
; binary -- 1Ah is an ordinary byte in a .COM.
;
; The DONE query after every chunk is mandatory, not diligence: bytes arriving
; on the bulk lane says nothing about whether the controller stored them, and
; DONE is the only thing that reports either a bulk CRC failure or a full card.

	.module sdput
	.area CODE (ABS)
	.org 0x0100

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	push af
	call user_restore
	pop af
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	call have_name
	jr nz,put_named
	ld de,#msg_noname
	call puts
	ld a,#1
	ret
put_named:

	; Scan the command tail for /T BEFORE anything else.
	;
	; The tail lives at 0080h, which is also the default DMA address -- the
	; first record read below lands on top of it.  Reading the switch here is
	; not tidiness, it is the only moment it still exists.
	call scan_switch
	call user_switch_apply

	; ---- open the CP/M file ----
	call reset_fcb
	ld de,#FCB1
	ld c,#BDOS_OPEN
	call BDOS
	inc a				; FFh means no such file
	jr nz,opened
	ld de,#msg_nofile
	call puts
	ld a,#1
	ret
opened:

	; ---- open the destination on the controller ----
	call zero_frames
	ld a,#CMD_FS_OPEN
	ld (tx_frame + 0),a
	ld a,#12
	ld (tx_frame + 3),a
	ld a,#FS_MODE_WRITE
	ld (tx_frame + 4),a
	ld e,#5
	call put_fcb_name
	ld a,#RSP_FS_OPEN
	call fs_xact
	jp nz,fail

	ld a,(rx_frame + 4)
	ld (handle),a

	xor a
	ld (dword + 0),a
	ld (dword + 1),a
	ld (dword + 2),a
	ld (dword + 3),a

put_loop:
	ld de,#FCB1
	ld c,#BDOS_READ
	call BDOS
	or a
	jr nz,put_done			; non-zero is end of file

	call note_trim

	; ---- WRITE one record ----
	call zero_frames
	ld a,#CMD_FS_WRITE
	ld (tx_frame + 0),a
	ld a,#7
	ld (tx_frame + 3),a
	ld a,(handle)
	ld (tx_frame + 4),a
	ld e,#5
	call put_dword
	ld a,#CHUNK
	ld (tx_frame + 9),a
	xor a
	ld (tx_frame + 10),a
	ld a,#RSP_FS_WRITE
	call fs_xact
	jp nz,fail
	call save_xfer_id

	ld hl,#DEFAULT_DMA
	ld de,#CHUNK
	call IOCBULKW
	or a
	jp nz,bulk_fail

	call fs_done
	jp nz,fail

	call advance_dword
	jr put_loop

put_done:
	; ---- CLOSE, with the length the file really is ----
	call zero_frames
	ld a,#CMD_FS_CLOSE
	ld (tx_frame + 0),a
	ld a,#5
	ld (tx_frame + 3),a
	ld a,(handle)
	ld (tx_frame + 4),a

	ld a,(text_mode)
	or a
	jr z,close_full
	ld hl,#trim_pos
	ld de,#dword
	ld bc,#4
	ldir
close_full:
	ld e,#5
	call put_dword
	ld a,#RSP_FS_CLOSE
	call fs_xact
	jp nz,fail

	ld de,#FCB1
	ld c,#BDOS_CLOSE
	call BDOS

	ld hl,#dword
	ld de,#dec_val
	ld bc,#4
	ldir
	call print_dec32
	ld de,#msg_bytes
	call puts
	xor a
	ret

bulk_fail:
	ld (fail_info),a
	ld a,#5
	ld (fail_kind),a
fail:
	call print_fail
	ld a,#1
	ret

; Note where this record would be trimmed: its own offset plus the position of
; the first 1Ah in it, or plus 128 if there is none.
;
; Overwritten every record on purpose.  Only the LAST record's value survives
; the loop, which is exactly the byte a trimmed close should stop at -- a 1Ah
; earlier in the file is the user's data or an editor's mark, and either way
; the records after it were still written.
note_trim:
	ld hl,#dword
	ld de,#trim_pos
	ld bc,#4
	ldir

	ld hl,#DEFAULT_DMA
	ld b,#CHUNK
	ld c,#0
nt_scan:
	ld a,(hl)
	cp #0x1a
	jr z,nt_found
	inc hl
	inc c
	djnz nt_scan
	ld c,#CHUNK
nt_found:
	ld a,(trim_pos)
	add a,c
	ld (trim_pos),a
	ret nc
	ld hl,#trim_pos + 1
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret

; Look for "/T" anywhere in the command tail.  Case insensitive, and it does not
; care where the switch sits relative to the filename -- the CCP has already
; taken the name into FCB1, so the tail is only being read for this.
scan_switch:
	xor a
	ld (text_mode),a
	ld a,(TAIL)
	or a
	ret z
	ld b,a
	ld hl,#TAIL + 1
ss_loop:
	ld a,(hl)
	cp #'/'
	jr nz,ss_next
	dec b
	ret z				; a trailing slash with nothing after it
	inc hl
	ld a,(hl)
	and #0xdf			; fold case
	cp #'T'
	jr nz,ss_next
	ld a,#1
	ld (text_mode),a
	ret
ss_next:
	inc hl
	djnz ss_loop
	ret

; Clear the fields the CCP does not.  The loader leaves them holding whatever
; was in memory, and BDOS believes them.
reset_fcb:
	xor a
	ld (FCB1 + 12),a		; EX
	ld (FCB1 + 13),a		; S1
	ld (FCB1 + 14),a		; S2
	ld (FCB1 + 15),a		; RC
	ld (FCB1 + 32),a		; CR

	; Bytes 16-31 are the allocation map, and F_MAKE copies the FCB straight
	; into the new directory entry.  The CCP does not clear them -- it parses
	; only the drive and name -- so whatever the previous program left in
	; memory would be written as this file's block list.  That is a directory
	; entry claiming blocks it does not own.
	ld hl,#FCB1 + 16
	ld b,#16
rf_map:
	ld (hl),#0
	inc hl
	djnz rf_map
	ret

msg_banner:	.ascii "SDPUT: $"
msg_bytes:	.ascii " bytes"
		.db 13,10,'$'
msg_nofile:	.ascii "no such file"
		.db 13,10,'$'

handle:		.ds 1
text_mode:	.ds 1
trim_pos:	.ds 4

	.include "sdfs.inc"
