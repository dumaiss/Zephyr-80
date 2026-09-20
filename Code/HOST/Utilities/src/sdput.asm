; SDPUT.COM — copy a CP/M file into the controller's /SHARED/ folder.
;
;   SDPUT NAME.EXT        copy verbatim, padded to a record boundary
;   SDPUT NAME.EXT /T     trim the trailing 1Ah padding from the last record
;   SDPUT *.MOD /T        every match on the current drive and user
;
; /T applies to the whole run, so do not mix text and binary in one pattern.
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
	call save_pattern

	call name_is_ambiguous
	jr c,put_many

	call put_one
	ret

; ---------------------------------------------------------------------------
; A wildcard run.
;
; collect_cpm walks the directory first and fills a table, because FCB1 is the
; search FCB: nothing may touch it or the DMA buffer between F_SFIRST and the
; last F_SNEXT, and copying a file does both.
;
; The tail at 0080h is already spent by then -- scan_switch and
; user_switch_apply read it above, and F_SFIRST writes the first directory
; entry straight over it.
; ---------------------------------------------------------------------------
put_many:
	call crlf
	call collect_cpm

	ld a,(match_count)
	or a
	jr nz,pm_go
	ld de,#msg_nomatch
	call puts
	ld a,#1
	ret
pm_go:
	ld b,a
	ld c,#0
pm_loop:
	push bc
	ld a,c
	call match_entry
	push hl
	call set_fcb_name
	pop hl
	call print_name_col
	call put_one
	pop bc
	or a
	ret nz
	inc c
	djnz pm_loop

	ld a,(match_over)
	or a
	jr z,pm_tally
	ld de,#msg_cut
	call puts
pm_tally:
	ld a,(match_count)
	ld (dec_val + 0),a
	xor a
	ld (dec_val + 1),a
	ld (dec_val + 2),a
	ld (dec_val + 3),a
	call print_dec32
	ld de,#msg_files
	call puts
	xor a
	ret

; ---------------------------------------------------------------------------
; Copy the one file FCB1 names.  A = 0 on success, non-zero after the failure
; has been reported.
; ---------------------------------------------------------------------------
put_one:
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
	jp nz,done_fail

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

; ---------------------------------------------------------------------------
; Raw wire capture (diagnostic)
; ---------------------------------------------------------------------------
;
; What the CONTROLLER actually received, before de-shifting.  For a Z80 -> MCU
; bulk write that is a recording of what this machine's SIO put on the wire,
; which is the only way to see what its CRC hardware emits: RR1 reports pass or
; fail and never a value, so a wrong CRC is otherwise indistinguishable from a
; wrong coverage or a wrong position.
;
; The chunk is 128 bytes and the preamble sits at raw byte 2, so the payload
; ends near 0x84 and the trailer follows it.  The walk covers 0x78-0xA0, the
; same tail range IOC_SDREC.COM uses, and the head as well so a transfer that
; never started is distinguishable from one that ended wrong.
;
; NEEDS DIAGNOSTIC CONTROLLER FIRMWARE: a normal build leaves these reply bytes
; zero.  Build it with `make IOC_PROFILE=diagnostic`.
;
; Diagnostic only -- remove with the CRC investigation it exists for.
RAW_HEAD_END	= 0x18
RAW_TAIL_START	= 0x78
RAW_TAIL_END	= 0xa0

dump_raw_window:
	xor a
	ld (raw_off),a
draw_slice:
	ld de,#msg_wire
	call puts
	ld a,(raw_off)
	call print_hex_byte
	ld e,#':'
	ld c,#BDOS_CONOUT
	call BDOS
	call fetch_raw
	or a
	jr z,draw_ok
	; Say WHY rather than stopping silently.  A walk that dies without a word
	; is how the first attempt at this wasted a flash: "wire 00:" and nothing
	; after it is indistinguishable from a tool that never ran.
	ld de,#msg_wfail
	call puts
	ld a,(fetch_io)
	call print_hex_byte
	ld de,#msg_wcls
	call puts
	ld a,(rx_frame + 0)
	call print_hex_byte
	ld de,#msg_crlf
	call puts
	ret
draw_ok:
	ld hl,#rx_frame + 14		; IOC_OFF_DONE_RAW
	ld b,#8
draw_bytes:
	ld e,#' '
	push bc
	push hl
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz draw_bytes
	ld de,#msg_crlf
	call puts
	ld a,(raw_off)
	add a,#8
	ld (raw_off),a
	cp #RAW_HEAD_END
	jr c,draw_slice
	cp #RAW_TAIL_START
	jr nc,draw_tail
	ld a,#RAW_TAIL_START
	ld (raw_off),a
	jr draw_slice
draw_tail:
	cp #RAW_TAIL_END
	jr c,draw_slice
	ret

; One XFER_STATUS asking for the eight raw bytes at raw_off.  A = 0 on success.
fetch_raw:
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#1
	ld (tx_frame + 3),a		; one payload byte: the raw offset
	ld a,(raw_off)
	ld (tx_frame + 4),a		; IOC_OFF_STATUS_RAW_OFF
	ld a,#1
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	ld (fetch_io),a			; keep it: the caller reports it
	or a
	ret nz
	; No class check.  IOC_SDREC.COM does not make one either, and the handler
	; always answers RSP_XFER_STATUS with STATUS_OK -- so a check here can only
	; throw away bytes that were worth seeing.
	xor a
	ret

; A DONE that reports a bulk CRC failure is the case the wire dump exists for:
; the bytes reached the controller and were rejected on their check, so what is
; wanted is what the controller actually saw.  This is fail_kind 4, NOT 5 --
; kind 5 is IOCBULKW giving up, which leaves nothing to look at.
done_fail:
	call print_fail
	call dump_raw_window
	ld a,#1
	ret

bulk_fail:
	ld (fail_info),a
	ld a,#5
	ld (fail_kind),a
	call print_fail
	call dump_raw_window		; diagnostic: what the controller really saw
	ld a,#1
	ret
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

msg_wire:	.ascii "  wire $"
msg_wfail:	.ascii " XFER_STATUS failed, io=$"
msg_wcls:	.ascii " cls=$"
fetch_io:	.ds 1
raw_off:	.ds 1

	.include "sdfs.inc"
	.include "zbdos.inc"		; IOCALL/IOCBULK/IOCBULKW, which sdfs.inc calls
	.include "sdwild.inc"		; LAST: its match table must end the image
