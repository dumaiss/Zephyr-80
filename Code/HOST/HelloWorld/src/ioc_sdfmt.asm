; IOC_SDFMT.COM — initialise the CP/M directory on the SD volume.
;
; A fresh card holds whatever it held before.  CP/M decides a directory entry is
; free by finding E5h in its first byte, so an uninitialised volume presents
; random bytes as live entries: garbage filenames, absurd extents, and an
; allocation vector built from them that will happily hand out blocks already
; claimed by the noise.  The directory has to be written before the volume is
; mounted, not after something has gone wrong.
;
; Scope is the directory only, which for this geometry is AL0 = F0h -> four
; 4096-byte blocks = 16 KiB = records 0..127.  File data blocks are left alone:
; CP/M never reads a block that the directory does not reference, so zeroing
; 8 MiB would buy nothing and cost an hour of card writes.
;
; Talks to the controller directly rather than through the BIOS storage driver.
; That is deliberate -- this is the tool that has to work before the driver can
; be trusted, so it must not depend on it.
;
; DESTRUCTIVE: every file on the SD CARD becomes unreachable.  The VDrip volume
; is never touched -- this tool has no drive concept at all.  It addresses the
; controller directly with CMD_SD_WRITE_REC, so it reaches the card and nothing
; else, whatever CP/M letters the two backends currently answer to.
;
; This block used to read "erases A:, does not touch B:", which was true only
; while the SD card was the boot volume.  The letters were later swapped in
; cbios_defs.inc and this was not, leaving a destructive tool advertising the
; exact opposite of what it does.  Name the BACKEND here, never the letter:
; SD_STORAGE_DRIVE is a constant anyone can change in one line, and no edit to
; it should be able to make this text wrong.

	.module ioc_sdfmt
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
BDOS_CONIN	= 0x01
IOCALL		= 0xDA3F
IOCBULKW	= 0xDA48

ZBIOS_XPORT_LEVEL      = 5
ZBIOS_XPORT_LEVEL_ADDR = 0xDF7A

CMD_SD_WRITE_REC = 0x09
RSP_SD_WRITE_REC = 0x89
CMD_SD_FLUSH	 = 0x0A
RSP_SD_FLUSH	 = 0x8A
CMD_XFER_STATUS	 = 0x06
RSP_XFER_STATUS	 = 0x86

REC_SIZE	= 128
DIR_RECORDS	= 128		; AL0 = F0h: 4 blocks x 4096 = 16 KiB

start:
	ld sp,#stack_top

	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jr z,level_ok
	ld de,#msg_stale
	ld c,#BDOS_PRINT
	call BDOS
	ret
level_ok:

	; Confirm, because this is not reversible.
	ld de,#msg_confirm
	ld c,#BDOS_PRINT
	call BDOS
	ld c,#BDOS_CONIN
	call BDOS
	cp #'Y'
	jr z,go
	cp #'y'
	jr z,go
	ld de,#msg_abort
	ld c,#BDOS_PRINT
	call BDOS
	ret
go:
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	; E5h across the whole record: one buffer serves every write.
	ld hl,#rec_buf
	ld b,#REC_SIZE
	ld a,#0xe5
fill:
	ld (hl),a
	inc hl
	djnz fill

	ld hl,#0
	ld (cur_rec),hl
dir_loop:
	call wr_rec
	or a
	jp nz,fail
	ld hl,(cur_rec)
	inc hl
	ld (cur_rec),hl
	ld a,l
	cp #DIR_RECORDS
	jr nz,dir_loop
	ld a,h
	or a
	jr nz,dir_loop

	call do_flush
	or a
	jp nz,fail

	ld de,#msg_done
	ld c,#BDOS_PRINT
	call BDOS
	ret

; ---------------------------------------------------------------------------
; Write rec_buf to cur_rec.  A = 0 on success.
; DONE is mandatory: bytes reaching the MCU says nothing about the card.
; ---------------------------------------------------------------------------
wr_rec:
	call zero_frames
	ld a,#CMD_SD_WRITE_REC
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a
	ld hl,(cur_rec)
	ld a,l
	ld (tx_frame + 4),a
	ld a,h
	ld (tx_frame + 5),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,wr_xport
	ld a,(rx_frame + 0)
	cp #RSP_SD_WRITE_REC
	jr nz,wr_class
	ld a,(rx_frame + 2)
	or a
	jr nz,wr_sd

	; The MCU echoes the record it decoded.  Checking it before any data
	; moves is what stops a mis-decoded request from writing E5h over a
	; sector nobody asked for.
	ld a,(rx_frame + 8)
	ld hl,#cur_rec
	cp (hl)
	jr nz,wr_echo
	ld a,(rx_frame + 9)
	inc hl
	cp (hl)
	jr nz,wr_echo

	ld hl,#rec_buf
	ld de,#REC_SIZE
	call IOCBULKW
	or a
	jr nz,wr_bulk

	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,wr_xport
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jr nz,wr_class
	ld a,(rx_frame + 5)
	or a
	jr nz,wr_done
	xor a
	ret

wr_xport:
	ld (fail_info),a
	ld a,#0x11
	ret
wr_class:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#0x12
	ret
wr_sd:
	ld (fail_info),a
	ld a,#0x13
	ret
wr_echo:
	ld a,#0x14
	ret
wr_bulk:
	ld (fail_info),a
	ld a,#0x15
	ret
wr_done:
	ld (fail_info),a
	ld a,#0x17
	ret

do_flush:
	call zero_frames
	ld a,#CMD_SD_FLUSH
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,fl_bad
	ld a,(rx_frame + 0)
	cp #RSP_SD_FLUSH
	jr nz,fl_class
	ld a,(rx_frame + 2)
	or a
	jr nz,fl_bad
	xor a
	ret
fl_class:
	ld a,(rx_frame + 0)
fl_bad:
	ld (fail_info),a
	ld a,#0x21
	ret

zero_frames:
	ld hl,#tx_frame
	ld b,#64
	xor a
zf_loop:
	ld (hl),a
	inc hl
	djnz zf_loop
	ret

fail:
	ld (fail_code),a
	ld de,#msg_fail
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_code)
	call print_hex_byte
	ld de,#msg_rec
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(cur_rec + 1)
	call print_hex_byte
	ld a,(cur_rec)
	call print_hex_byte
	ld de,#msg_info
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_info)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call print_hex_nibble
	pop af
print_hex_nibble:
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

msg_banner:	.ascii "SDFMT: initialise the CP/M directory on the SD card"
		.db 13,10,'$'
msg_stale:	.ascii "BIOS transport level mismatch -- re-flash ROM"
		.db 13,10,'$'
msg_confirm:	.ascii "This ERASES the SD card directory.  Proceed (y/N)? $"
msg_abort:	.ascii "aborted"
		.db 13,10,'$'
msg_done:	.ascii "directory initialised, 128 records"
		.db 13,10,'$'
msg_fail:	.ascii "FAIL code $"
msg_rec:	.ascii " rec $"
msg_info:	.ascii " info $"
msg_crlf:	.db 13,10,'$'

cur_rec:	.ds 2
fail_code:	.ds 1
fail_info:	.ds 1
tx_frame:	.ds 32
rx_frame:	.ds 32
rec_buf:	.ds 128
		.ds 64
stack_top:
