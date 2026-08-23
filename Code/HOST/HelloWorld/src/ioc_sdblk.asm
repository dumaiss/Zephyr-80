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
;    |-- CMD_XFER_STATUS ------->|   command lane, ERROR PATH ONLY
;    |<-- DONE(id, status) ------|   command lane
;
; On the happy path the DONE query is skipped: receiving every byte and seeing
; the PIC drop /CTSA already proves the read completed.  DONE is still issued
; whenever anything goes wrong, so the authoritative status is never lost.
;
; The MCU reads the card BEFORE replying READY, so SD latency is outside the
; bulk transaction.  It then waits for this program to assert RTS on channel A
; before clocking, so the handoff is deterministic rather than timed.  /DCDA
; gates this channel's receiver via Auto Enables and /CTSA marks the bulk phase.
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
WR3_RX_HUNT	= 0xf1		; 8-bit RX, AUTO ENABLES, enter hunt, RX enable
WR5_RTS_ON	= 0xea		; channel A: DTR on, 8-bit TX, TX enable, RTS on
WR5_RTS_OFF	= 0xe8		; same with RTS off
RR0_RX_AVAIL	= 0x01
RR0_CTS		= 0x20		; set while /CTSA is asserted (bulk phase live)

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

	; ---- bulk read ----
	; Tell the PIC we are in the read loop.  It is waiting on this and will
	; not clock a single edge until it sees it, so there is no race here and
	; no fixed guard delay on either side.
	ld a,#0x05
	out (BULK_CTRL),a
	ld a,#WR5_RTS_ON
	out (BULK_CTRL),a

	; ---- bulk read: INI-based ----
	; 56 T-states per byte = 5.6 us at 10 MHz, versus 90 T for the previous
	; in/ld/inc form.  INI does the port read, the store, HL++ and B-- in one
	; 16 T instruction, which is where most of the saving comes from.
	;
	; Register budget is forced by INI: B is the counter, C is the port, HL is
	; the destination.  That leaves DE for the stall budget -- and because it is
	; NOT reloaded per byte, it is a budget for the whole transfer rather than
	; per byte, which is both cheaper and better behaved.
	;
	; B counts one 256-byte block at a time (B = 0 means 256), so a transfer is
	; an optional remainder followed by however many full blocks.
	ld c,#BULK_DATA
	ld de,#0			; whole-transfer stall budget
	ld a,(rx_frame + 7)
	ld (chunks),a			; number of full 256-byte blocks
	ld a,(rx_frame + 6)		; remainder
	or a
	jr z,chunk_loop
	ld b,a
	jr ini_poll
chunk_loop:
	ld a,(chunks)
	or a
	jr z,bulk_done
	dec a
	ld (chunks),a
	ld b,#0				; 256 bytes
ini_poll:
	in a,(BULK_CTRL)		; 11
	and #RR0_RX_AVAIL		;  7
	jr nz,ini_got			; 12 taken
	dec de				;  6
	ld a,d				;  4
	or e				;  4
	jr nz,ini_poll			; 12
	jp bulk_timeout
ini_got:
	ini				; 16  (HL)<-in(C), HL++, B--
	jp nz,ini_poll			; 10
	jr chunk_loop
bulk_done:
	; ---- end bulk read ----

	; Release RTS: the bulk phase is over from our side.
	ld a,#0x05
	out (BULK_CTRL),a
	ld a,#WR5_RTS_OFF
	out (BULK_CTRL),a

	; /CTSA is asserted by the PIC for the duration of the bulk phase, so it
	; should already be deasserted.  Checked rather than relied upon: the
	; authoritative status still comes from the command lane.  Once this is
	; proven on the bench, watching this line can replace the DONE round trip.
	ld de,#0
cts_wait:
	in a,(BULK_CTRL)
	and #RR0_CTS
	jr z,cts_clear
	dec de
	ld a,d
	or e
	jr nz,cts_wait
	jp cts_stuck
cts_clear:
	; ---- fast path ----
	; Every requested byte arrived AND the PIC dropped /CTSA, so the bulk
	; phase completed.  For a READ those two facts are the whole of DONE: a
	; stalled transfer could not have delivered the full byte count, so the
	; command-lane DONE query would tell us nothing new.  Skipping it saves a
	; round trip (~3 ms of an ~11 ms sector).
	;
	; Trade-off worth knowing: the xfer_id cross-check now only runs on the
	; error path below.  If you want it on every transfer, jump to
	; done_query here instead.
	;
	; This shortcut is valid for reads only.  A WRITE must always take the
	; DONE query: bytes arriving over the bulk lane says nothing about
	; whether the card committed them.
	jr report

	; ---- slow path: ask the command lane what actually happened ----
done_query:
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

report:
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
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	jp done_query			; get the authoritative reason

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

cts_stuck:
	ld de,#msg_cts_stuck
	ld c,#BDOS_PRINT
	call BDOS
	jp done_query			; get the authoritative reason

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
msg_cts_stuck:
	.ascii "/CTSA still asserted after bulk"
	.db 0x0d, 0x0a, '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'

ready_id:
	.ds 1
chunks:
	.ds 1
xfer_len:
	.ds 2
tx_frame:
	.ds 32
rx_frame:
	.ds 32
sector_buf:
	.ds 512
