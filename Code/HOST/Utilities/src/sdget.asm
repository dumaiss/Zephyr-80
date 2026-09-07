; SDGET.COM — copy a file out of the controller's /SHARED/ folder into CP/M.
;
;   SDGET NAME.EXT        writes to the current drive and user
;   SDGET B:NAME.EXT      writes to drive B
;
; The name is not parsed here.  The CCP has already dropped it into FCB1 at
; 005Ch in packed 8.3 -- which is byte for byte the form the controller wants
; on the wire and the form BDOS wants for F_MAKE, so the same eleven bytes serve
; both ends of the copy.
;
;   OPEN(name) -> handle, size
;   READ(handle, offset, 128) -> READY(len) then len bytes on the bulk lane
;   ... until the file is consumed
;   CLOSE(handle, size)
;
; The offset is explicit on every read rather than implied by a file position.
; That is what makes a retry safe: this link does retry, and with an implicit
; position a repeated transaction would advance twice and lose 128 bytes out of
; the middle of the copy.

	.module sdget
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
	jr nz,got_name
	ld de,#msg_noname
	call puts
	ld a,#1
	ret
got_name:

	; /U<n> BEFORE anything touches the DMA buffer at 0080h, which is where
	; the command tail lives and where the first record will land.
	call user_switch_apply

	; ---- OPEN on the controller ----
	call zero_frames
	ld a,#CMD_FS_OPEN
	ld (tx_frame + 0),a
	ld a,#12
	ld (tx_frame + 3),a		; mode + 11 name bytes
	ld a,#FS_MODE_READ
	ld (tx_frame + 4),a
	ld e,#5
	call put_fcb_name
	ld a,#RSP_FS_OPEN
	call fs_xact
	jp nz,fail

	ld a,(rx_frame + 4)
	ld (handle),a
	ld hl,#rx_frame + 5
	ld de,#remaining
	ld bc,#4
	ldir

	; Report the size before moving anything, so an obviously wrong number
	; is visible before the disk is written to.
	ld hl,#remaining
	ld de,#dec_val
	ld bc,#4
	ldir
	call print_dec32
	ld de,#msg_bytes
	call puts

	; ---- create the CP/M file ----
	; Delete first: F_MAKE on an existing name fails, and the alternative --
	; refusing the copy -- is the wrong default for a tool whose whole job is
	; to fetch a fresh copy of something.
	call reset_fcb
	ld de,#FCB1
	ld c,#BDOS_DELETE
	call BDOS

	call reset_fcb
	ld de,#FCB1
	ld c,#BDOS_MAKE
	call BDOS
	inc a				; FFh means no directory space
	jr nz,made
	ld de,#msg_nomake
	call puts
	ld a,#1
	ret
made:

	xor a
	ld (dword + 0),a
	ld (dword + 1),a
	ld (dword + 2),a
	ld (dword + 3),a

copy_loop:
	call remaining_zero
	jr z,copy_done

	; ---- READ one record ----
	call zero_frames
	ld a,#CMD_FS_READ
	ld (tx_frame + 0),a
	ld a,#7
	ld (tx_frame + 3),a		; handle + offset + length
	ld a,(handle)
	ld (tx_frame + 4),a
	ld e,#5
	call put_dword
	ld a,#CHUNK
	ld (tx_frame + 9),a
	xor a
	ld (tx_frame + 10),a
	ld a,#RSP_FS_READ
	call fs_xact
	jp nz,fail

	; The length comes from READY, never assumed.  A short read at end of
	; file is normal; zero means the controller has nothing to send and this
	; program must not enter the bulk phase at all.
	ld a,(rx_frame + 6)
	ld l,a
	ld a,(rx_frame + 7)
	ld h,a
	ld a,h
	or l
	jr z,copy_done
	push hl

	; Any tail short of a full record is padded with 1Ah, the CP/M end of
	; file convention, because a CP/M file cannot be anything but a whole
	; number of records.
	ld hl,#DEFAULT_DMA
	ld b,#CHUNK
	ld a,#0x1a
pad_rec:
	ld (hl),a
	inc hl
	djnz pad_rec

	pop de				; length the controller promised
	ld hl,#DEFAULT_DMA
	call IOCBULK
	or a
	jp nz,bulk_fail

	ld de,#FCB1
	ld c,#BDOS_WRITE
	call BDOS
	or a
	jr z,wrote
	ld de,#msg_nowrite
	call puts
	ld a,#1
	ret
wrote:

	call advance_dword
	call remaining_sub
	jr copy_loop

copy_done:
	ld de,#FCB1
	ld c,#BDOS_CLOSE
	call BDOS

	; ---- CLOSE on the controller ----
	call zero_frames
	ld a,#CMD_FS_CLOSE
	ld (tx_frame + 0),a
	ld a,#5
	ld (tx_frame + 3),a
	ld a,(handle)
	ld (tx_frame + 4),a
	; Size zero: nothing was written on the controller's side, so there is
	; nothing to truncate.  The field is only meaningful after a write.
	ld a,#RSP_FS_CLOSE
	call fs_xact
	jp nz,fail

	ld de,#msg_done
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

; Clear the fields the CCP does not: extent, record count and current record.
; The loader leaves them holding whatever was in memory, and BDOS believes
; them.
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

; Z if `remaining` is zero.
remaining_zero:
	ld a,(remaining + 0)
	ld hl,#remaining + 1
	or (hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	ret

; remaining -= CHUNK, clamped at zero so the final short record does not wrap
; the counter into another four gigabytes of copying.
remaining_sub:
	ld a,(remaining + 0)
	cp #CHUNK
	jr nc,rs_full
	ld a,(remaining + 1)
	ld hl,#remaining + 2
	or (hl)
	inc hl
	or (hl)
	jr nz,rs_full
	xor a
	ld (remaining + 0),a
	ret
rs_full:
	ld hl,#remaining
	ld a,(hl)
	sub #CHUNK
	ld (hl),a
	ret nc
	inc hl
	dec (hl)
	ld a,(hl)
	inc a
	ret nz
	inc hl
	dec (hl)
	ld a,(hl)
	inc a
	ret nz
	inc hl
	dec (hl)
	ret

msg_banner:	.ascii "SDGET: $"
msg_bytes:	.ascii " bytes"
		.db 13,10,'$'
msg_done:	.ascii "done"
		.db 13,10,'$'
msg_nomake:	.ascii "no directory space"
		.db 13,10,'$'
msg_nowrite:	.ascii "disk full"
		.db 13,10,'$'

handle:		.ds 1
remaining:	.ds 4

	.include "sdfs.inc"
