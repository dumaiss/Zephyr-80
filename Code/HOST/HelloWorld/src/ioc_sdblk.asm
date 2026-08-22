; IOC_SDBLK.COM — read a whole 512-byte sector over the two-lane transport.
;
; Full READY -> BULK -> DONE lifecycle, driven from user mode so no BIOS patch
; is needed:
;
;   Z80                         PIC
;    |-- CMD_SD_READ_BULK(LBA) ->|   command lane (IOCALL, SIO1/B)
;    |                           |-- read sector into MCU SRAM
;    |<-- READY(id, dir, 512) ---|   command lane
;    |<====== 512 bytes =========|   bulk lane (SIO1/A, ports 30h/31h)
;    |-- CMD_XFER_STATUS ------->|   command lane
;    |<-- DONE(id, status) ------|   command lane
;
; The MCU reads the card BEFORE replying READY, so SD latency is outside the
; bulk transaction.  It then waits a fixed guard before clocking, because there
; is no ready signal from the Z80 on the bulk lane -- so this program must not
; print anything between IOCALL returning and its read loop.
;
; Verification: reports the first 16 bytes, and checks the 55 AA signature at
; offset 510.  Getting both right means the whole 512-byte transfer landed in
; the right order, not just the beginning.
;
; The DONE id must match the READY id.  A mismatch means a transfer was lost or
; overlapped, which is exactly what the id is there to catch.

	.module ioc_sdblk
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F

CMD_SD_READ_BULK = 0x05
RSP_SD_READ_BULK = 0x85
CMD_XFER_STATUS	= 0x06
RSP_XFER_STATUS	= 0x86

BULK_DATA	= 0x30
BULK_CTRL	= 0x31
WR0_RESET_ERROR	= 0x30
WR3_RX_HUNT	= 0xd1
RR0_RX_AVAIL	= 0x01

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; ---- build SD_READ_BULK(LBA 0) ----
	call zero_frames
	ld a,#CMD_SD_READ_BULK
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a		; payload length = 4 (32-bit LBA)
	; bytes 4-7 stay zero => LBA 0

	; Prime the bulk receiver into hunt before the command is issued.
	ld a,#WR0_RESET_ERROR
	out (BULK_CTRL),a
	ld a,#0x03
	out (BULK_CTRL),a
	ld a,#WR3_RX_HUNT
	out (BULK_CTRL),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_err

	ld a,(rx_frame + 0)
	cp #RSP_SD_READ_BULK
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,sd_err			; card failed; no bulk phase was staged

	ld a,(rx_frame + 4)
	ld (ready_id),a			; remember for the DONE check
	ld a,(rx_frame + 6)
	ld c,a
	ld a,(rx_frame + 7)
	ld b,a
	ld (xfer_len),bc
	ld hl,#sector_buf

	; ---- bulk read: no printing above this line once IOCALL returned ----
bulk_next:
	ld de,#0
bulk_wait:
	in a,(BULK_CTRL)
	and #RR0_RX_AVAIL
	jr nz,bulk_got
	dec de
	ld a,d
	or e
	jr nz,bulk_wait
	jp bulk_timeout
bulk_got:
	in a,(BULK_DATA)
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,bulk_next
	; ---- end bulk read ----

	; ---- DONE query ----
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_err
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jp nz,bad_reply

	; DONE id must match the READY id.
	ld a,(rx_frame + 4)
	ld hl,#ready_id
	cp (hl)
	jp nz,id_mismatch
	ld a,(rx_frame + 5)
	or a
	jp nz,done_err

	; ---- report ----
	call dump_head
	call check_signature
	ret

; First 16 bytes of the sector, hex then ASCII.
dump_head:
	ld de,#msg_hex
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#sector_buf
	ld b,#16
dh_hex:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz dh_hex
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Offset 510/511 must be 55 AA on a partitioned or FAT-formatted card.
; This is the real proof the tail of the transfer arrived intact.
check_signature:
	ld a,(sector_buf + 510)
	cp #0x55
	jr nz,sig_bad
	ld a,(sector_buf + 511)
	cp #0xaa
	jr nz,sig_bad
	ld de,#msg_sig_ok
	ld c,#BDOS_PRINT
	call BDOS
	ret
sig_bad:
	ld de,#msg_sig_bad
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(sector_buf + 510)
	call print_hex_byte
	ld a,(sector_buf + 511)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

zero_frames:
	xor a
	ld hl,#tx_frame
	ld b,#32
zf_tx:
	ld (hl),a
	inc hl
	djnz zf_tx
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zf_rx:
	ld (hl),a
	inc hl
	djnz zf_rx
	ret

bulk_timeout:
	ld de,#msg_bulk_timeout
	ld c,#BDOS_PRINT
	call BDOS
	ld a,b
	call print_hex_byte
	ld a,c
	call print_hex_byte
	jr crlf_ret

xport_err:
	push af
	ld de,#msg_xport_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

sd_err:
	push af
	ld de,#msg_sd_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

done_err:
	push af
	ld de,#msg_done_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

id_mismatch:
	push af
	ld de,#msg_id_mismatch
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(ready_id)
	call print_hex_byte
	ld de,#msg_got
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

bad_reply:
	push af
	ld de,#msg_bad_reply
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
crlf_ret:
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
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
print_hex_nibble:
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

msg_banner:
	.ascii "IOC SD BULK - sector 0 via SIO1/A"
	.db 0x0d, 0x0a, '$'
msg_hex:
	.ascii "HEX:"
	.db '$'
msg_sig_ok:
	.ascii "signature 55AA OK - full sector received"
	.db 0x0d, 0x0a, '$'
msg_sig_bad:
	.ascii "signature BAD at 510: 0x"
	.db '$'
msg_bulk_timeout:
	.ascii "bulk timeout, bytes left 0x"
	.db '$'
msg_xport_err:
	.ascii "transport error 0x"
	.db '$'
msg_sd_err:
	.ascii "SD error 0x"
	.db '$'
msg_done_err:
	.ascii "DONE status 0x"
	.db '$'
msg_id_mismatch:
	.ascii "XFER ID mismatch: READY 0x"
	.db '$'
msg_got:
	.ascii " DONE 0x"
	.db '$'
msg_bad_reply:
	.ascii "unexpected reply 0x"
	.db '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'

ready_id:
	.ds 1
xfer_len:
	.ds 2
tx_frame:
	.ds 32
rx_frame:
	.ds 32
sector_buf:
	.ds 512
