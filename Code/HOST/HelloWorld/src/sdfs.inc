; sdfs.inc — shared support for the /SHARED/ folder tools.
;
; SDDIR, SDGET, SDPUT and SDDEL all talk to the IO Controller the same way, and
; that way is entirely user space: the published extended-BIOS entries IOCALL,
; IOCBULK and IOCBULKW, exactly as IOC_SDREC.COM and HIDSTAT.COM already use
; them.  Nothing here needs a BIOS change, a jump-table entry or a drive letter.
;
;   Z80                          PIC
;    |-- CMD_FS_OPEN(name) ----->|  f_open under /SHARED/
;    |<-- handle, size ----------|
;    |-- CMD_FS_READ(h,off,len) >|  f_read into the controller's chunk buffer
;    |<-- READY(id, dir, len) ---|  the bytes are already in SRAM
;    |======= len bytes ========>|
;    |-- CMD_FS_CLOSE(h,size) -->|  f_truncate, f_close, flush
;
; NAMES ARE PACKED 8.3, which is why these tools are short: that is the FCB
; layout, so the name CP/M has already parsed into FCB1 at 005Ch is byte for
; byte the name the controller wants.  No parsing happens on the Z80 at all.
;
; CHUNKS ARE 128 BYTES.  The protocol carries the length and the controller
; will serve up to 512, but a CP/M record is 128 and matching it means every
; chunk goes straight to or from a BDOS sequential call with no buffer of our
; own and no partial-record bookkeeping.

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
BDOS_OPEN	= 0x0f
BDOS_CLOSE	= 0x10
BDOS_DELETE	= 0x13
BDOS_READ	= 0x14
BDOS_WRITE	= 0x15
BDOS_MAKE	= 0x16
BDOS_DMA	= 0x1a

FCB1		= 0x005c
TAIL		= 0x0080
DEFAULT_DMA	= 0x0080

IOCALL		= 0xDA3F	; ZBIOS_EXT_BASE + 0Ch
IOCBULK		= 0xDA45	; ZBIOS_EXT_BASE + 12h: bulk receive
IOCBULKW	= 0xDA48	; ZBIOS_EXT_BASE + 15h: bulk transmit

CMD_XFER_STATUS	= 0x06
RSP_XFER_STATUS	= 0x86

CMD_FS_OPENDIR	= 0x20
RSP_FS_OPENDIR	= 0xA0
CMD_FS_READDIR	= 0x21
RSP_FS_READDIR	= 0xA1
CMD_FS_OPEN	= 0x22
RSP_FS_OPEN	= 0xA2
CMD_FS_READ	= 0x23
RSP_FS_READ	= 0xA3
CMD_FS_WRITE	= 0x24
RSP_FS_WRITE	= 0xA4
CMD_FS_CLOSE	= 0x25
RSP_FS_CLOSE	= 0xA5
CMD_FS_STAT	= 0x26
RSP_FS_STAT	= 0xA6
CMD_FS_DELETE	= 0x27
RSP_FS_DELETE	= 0xA7

FS_MODE_READ	= 0x00
FS_MODE_WRITE	= 0x01

CHUNK		= 128

; ---------------------------------------------------------------------------
; One command transaction.
;
; In:  A  = expected response class
;      tx_frame already built (class, length, payload)
; Out: A  = 0 on success, non-zero on failure with fail_kind/fail_info set so
;           print_fail can say what went wrong without every caller carrying
;           its own error text.
; ---------------------------------------------------------------------------
fs_xact:
	ld (exp_class),a
	ld a,#1
	ld (tx_frame + 1),a		; sequence; IOCALL stamps the wire copy
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,fx_frame
	ld (fail_info),a
	ld a,#1				; transport
	ld (fail_kind),a
	or a
	ret
fx_frame:
	ld a,(rx_frame + 0)
	ld hl,#exp_class
	cp (hl)
	jr z,fx_status
	ld (fail_info),a
	ld a,#2				; wrong response class
	ld (fail_kind),a
	or a
	ret
fx_status:
	ld a,(rx_frame + 2)
	or a
	ret z
	ld (fail_info),a
	ld a,#3				; controller reported a status
	ld (fail_kind),a
	or a
	ret

; ---------------------------------------------------------------------------
; Zero both mailboxes.  .ds space is not cleared by the CP/M loader, so a field
; this command does not set would otherwise hold whatever the last program
; wrote there -- and the controller reads several fields conditionally.
; ---------------------------------------------------------------------------
zero_frames:
	ld hl,#tx_frame
	ld b,#64
zf_loop:
	ld (hl),#0
	inc hl
	djnz zf_loop
	ret

; Copy the eleven-byte packed name from FCB1 into tx_frame at offset E.
; The command tail is already parsed into FCB1 by the CCP, so this is the whole
; of the argument handling.
put_fcb_name:
	ld hl,#tx_frame
	ld d,#0
	add hl,de
	ex de,hl
	ld hl,#FCB1 + 1
	ld b,#11
pfn_loop:
	ld a,(hl)
	ld (de),a
	inc hl
	inc de
	djnz pfn_loop
	ret

; True (Z set) if FCB1 holds no name at all, so a missing argument is reported
; rather than sent to the controller as eleven spaces.
have_name:
	ld a,(FCB1 + 1)
	cp #' '
	ret

; Store the 32-bit value in (dword) at tx_frame + E, little endian.
put_dword:
	ld hl,#tx_frame
	ld d,#0
	add hl,de
	ex de,hl
	ld hl,#dword
	ld b,#4
pd_loop:
	ld a,(hl)
	ld (de),a
	inc hl
	inc de
	djnz pd_loop
	ret

; dword += CHUNK
advance_dword:
	ld hl,#dword
	ld a,(hl)
	add a,#CHUNK
	ld (hl),a
	ret nc
	inc hl
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret

; Remember the transfer id READY just issued, so DONE can be checked against
; it.  Call immediately after the READY reply and before the bulk phase.
save_xfer_id:
	ld a,(rx_frame + 4)		; IOC_OFF_READY_XFER_ID
	ld (ready_id),a
	ret

; ---------------------------------------------------------------------------
; The DONE query.
;
; Mandatory after every write.  Bytes arriving on the bulk lane says nothing
; about whether the controller stored them, and DONE is the only thing that
; reports either a bulk CRC failure or the filesystem's own verdict.
; ---------------------------------------------------------------------------
fs_done:
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#RSP_XFER_STATUS
	call fs_xact
	ret nz

	; A DONE carrying an id other than the one READY reported means a
	; transfer was lost or overlapped -- which is the entire reason the id
	; exists, and the one failure that would otherwise look like success.
	ld a,(rx_frame + 4)		; IOC_OFF_DONE_XFER_ID
	ld hl,#ready_id
	cp (hl)
	jr z,fd_status
	ld (fail_info),a
	ld a,#6				; DONE id mismatch
	ld (fail_kind),a
	or a
	ret
fd_status:
	ld a,(rx_frame + 5)		; IOC_OFF_DONE_STATUS
	or a
	ret z
	ld (fail_info),a
	ld a,#4				; commit failed after the transfer
	ld (fail_kind),a
	or a
	ret

; ---------------------------------------------------------------------------
; Command-tail switches
;
; Look for /<letter> in the command tail and return the character after it.
; In:  A = letter, upper case.
; Out: carry set = not present; carry clear = found, A = the following char.
;
; MUST be called before anything writes to the default DMA address: the tail
; lives at 0080h, which IS that buffer, so the first record read lands on top of
; it.  This is not tidiness, it is the only moment the switch still exists.
; ---------------------------------------------------------------------------
find_switch:
	ld (fsw_want),a
	ld hl,#TAIL
	ld a,(hl)
	or a
	jr z,fsw_none
	ld b,a
	inc hl
fsw_loop:
	ld a,(hl)
	cp #'/'
	jr z,fsw_slash
fsw_cont:
	inc hl
	djnz fsw_loop
fsw_none:
	scf
	ret
fsw_slash:
	; "/X n" needs the slash, the letter and the argument still to come.
	ld a,b
	cp #3
	jr c,fsw_none
	inc hl
	ld a,(hl)
	and #0xdf			; fold case
	ld c,a
	ld a,(fsw_want)
	cp c
	jr nz,fsw_back
	inc hl
	ld a,(hl)
	or a				; clears carry
	ret
fsw_back:
	dec hl
	jr fsw_cont

; ---------------------------------------------------------------------------
; CP/M user area
;
; There is no B8: in CP/M 2.2 -- the user number is a global BDOS setting, not
; part of a filename.  Changing it with the CCP's USER command has a trap: the
; CCP then looks for the .COM in that user area too, and the ROM disk keeps its
; tools in user 0, so `USER 8` makes these programs unfindable.
;
; /U<n> sets it around the transfer instead, and puts it back on the way out.
; ---------------------------------------------------------------------------
BDOS_USERNUM	= 0x20

; Parse /U<digit>, apply it, and remember what to restore.  0-15 accepted;
; a second digit is honoured so /U12 works.
user_switch_apply:
	ld a,#0xff
	ld (saved_user),a
	ld a,#'U'
	call find_switch
	ret c
	sub #'0'
	cp #10
	ret nc				; not a digit: ignore the switch
	ld c,a
	; A second digit?  /U1 and /U12 are both legal.
	inc hl
	ld a,(hl)
	sub #'0'
	cp #10
	jr nc,us_one
	ld b,a
	ld a,c
	add a,a
	add a,a
	add a,c
	add a,a				; c * 10
	add a,b
	ld c,a
us_one:
	ld a,c
	cp #16
	ret nc				; out of range: ignore rather than guess
	push bc
	ld e,#0xff
	ld c,#BDOS_USERNUM
	call BDOS			; A = current user
	pop bc
	ld (saved_user),a
	ld e,c
	ld c,#BDOS_USERNUM
	jp BDOS

; Put the user number back.  Safe to call unconditionally.
user_restore:
	ld a,(saved_user)
	cp #0xff
	ret z
	ld e,a
	ld c,#BDOS_USERNUM
	jp BDOS

; ---------------------------------------------------------------------------
; Reporting
; ---------------------------------------------------------------------------
print_fail:
	ld de,#msg_fail
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_kind)
	call print_hex_byte
	ld de,#msg_info
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_info)
	call print_hex_byte
	jr crlf

puts:
	ld c,#BDOS_PRINT
	jp BDOS

crlf:
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	jp BDOS

; Eleven packed bytes at HL as NAME.EXT, no padding.
print_name:
	push hl
	ld b,#8
pn_base:
	ld a,(hl)
	cp #' '
	jr z,pn_base_done
	call conout
	inc hl
	djnz pn_base
pn_base_done:
	pop hl
	push hl
	ld de,#8
	add hl,de
	ld a,(hl)
	cp #' '
	jr z,pn_done
	ld a,#'.'
	call conout
	ld b,#3
pn_ext:
	ld a,(hl)
	cp #' '
	jr z,pn_done
	call conout
	inc hl
	djnz pn_ext
pn_done:
	pop hl
	ret

conout:
	push hl
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	pop hl
	ret

; Print the unsigned 32-bit value in dec_val, in decimal, no leading zeroes.
; The value is CONSUMED -- repeated division by ten leaves it zero.
print_dec32:
	ld hl,#dec_buf + 11
	ld (dec_ptr),hl
pd32_loop:
	call div10_32
	add a,#'0'
	ld hl,(dec_ptr)
	dec hl
	ld (hl),a
	ld (dec_ptr),hl
	ld a,(dec_val)
	ld hl,#dec_val + 1
	or (hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	jr nz,pd32_loop
	ld hl,(dec_ptr)
pd32_out:
	ld de,#dec_buf + 11
	ld a,l
	cp e
	jr nz,pd32_emit
	ld a,h
	cp d
	ret z
pd32_emit:
	ld a,(hl)
	inc hl
	push hl
	call conout
	pop hl
	jr pd32_out

; dec_val /= 10, remainder returned in A.
;
; Restoring division, most significant byte first: shift the dividend left one
; bit at a time into a running remainder, subtract ten when it fits, and the
; bit that decision produces is the quotient bit.
div10_32:
	xor a				; running remainder
	ld hl,#dec_val + 3
	ld b,#4
d10_byte:
	ld c,(hl)
	ld d,#8
d10_bit:
	sla c				; MSB of this byte out into carry
	rla				; remainder = remainder * 2 + that bit
	cp #10
	jr c,d10_keep
	sub #10
	inc c				; quotient bit; sla left bit 0 clear
d10_keep:
	dec d
	jr nz,d10_bit
	ld (hl),c
	dec hl
	djnz d10_byte
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
	jp conout

msg_fail:	.ascii "failed, kind $"
msg_info:	.ascii " info $"
msg_crlf:	.db 13,10,'$'
msg_noname:	.ascii "usage: give a filename"
		.db 13,10,'$'

exp_class:	.ds 1
fsw_want:	.ds 1
saved_user:	.ds 1
ready_id:	.ds 1
fail_kind:	.ds 1
fail_info:	.ds 1
dword:		.ds 4
dec_val:	.ds 4
dec_ptr:	.ds 2
dec_buf:	.ds 12
tx_frame:	.ds 32
rx_frame:	.ds 32

; Private stack.  CP/M enters a .COM on the CCP's own sixteen-byte stack, and
; the BIOS transport plus BDOS nesting plus an interrupt frame do not fit in
; it.  Reserved, not emitted: the .COM image ends at the last byte above.
entry_sp:	.ds 2
	.ds 128
stack_top:
