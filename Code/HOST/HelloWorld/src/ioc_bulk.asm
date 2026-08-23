; IOC_BULK.COM — bring up the SIO1/A bulk lane.
;
; Two-lane transport check.  The command lane (SIO1/B, via the IOCALL BIOS
; extension) asks the IO Controller for a bulk transfer; the MCU replies READY
; with a transfer id, direction and length, then streams that many bytes on the
; bulk lane (SIO1/A, ports 30h/31h).  This program drives the bulk read itself
; rather than through the BIOS, so no BIOS patch is needed.
;
;   Z80                         PIC
;    |-- CMD_BULK_TEST(len) ---->|      command lane, via IOCALL
;    |<-- READY(id, dir, len) ---|      command lane
;    |<====== len bytes =========|      bulk lane, this program's read loop
;
; Handshake: the MCU is clock master but waits for this program to assert RTS on
; channel A before clocking a single edge, so there is no race and no guard
; delay.  /DCDA gates this channel's receiver via Auto Enables (WR3 bit 5), so
; the receiver is only live while the MCU is actually sending.  /CTSA is
; asserted for the duration of the bulk phase.
;
; The payload is a 00 01 02 ... FF ramp, so a shifted or dropped byte is
; obvious: the first mismatch index and value are reported.
;
; Frame layout (32 bytes, Z80 -> MCU):
;   byte  0  command class:  CMD_BULK_TEST = 04h
;   byte  1  sequence:       01h
;   byte  2  status/flags:   00h
;   byte  3  payload length: 02h
;   bytes 4-5  requested transfer length, little-endian (0 means 256)
;
; Reply (32 bytes, MCU -> Z80):
;   byte  0  RSP_BULK_TEST = 84h
;   byte  2  status: 00h OK
;   byte  3  payload length: 04h
;   byte  4  transfer id
;   byte  5  direction (00h = MCU -> Z80)
;   bytes 6-7  transfer length, little-endian

	.module ioc_bulk
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F	; BIOS extended entry: IOC fixed-frame transport

CMD_BULK_TEST	= 0x04
RSP_BULK_TEST	= 0x84

BULK_DATA	= 0x30		; SIO1/A data
BULK_CTRL	= 0x31		; SIO1/A control
WR0_RESET_ERROR	= 0x30
WR3_RX_HUNT	= 0xf1		; 8-bit RX, AUTO ENABLES, enter hunt, RX enable
WR5_RTS_ON	= 0xea		; channel A: DTR on, 8-bit TX, TX enable, RTS on
WR5_RTS_OFF	= 0xe8		; same with RTS off
RR0_RX_AVAIL	= 0x01
RR0_CTS		= 0x20		; set while /CTSA is asserted (bulk phase live)

REQ_LEN		= 256		; bytes to ask for

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; Build the request frame.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx:
	ld (hl),a
	inc hl
	djnz zero_rx

	ld a,#CMD_BULK_TEST
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x02
	ld (tx_frame + 3),a		; payload length = 2
	ld a,#<REQ_LEN
	ld (tx_frame + 4),a		; requested length, low
	ld a,#>REQ_LEN
	ld (tx_frame + 5),a		; requested length, high

	; Prime the bulk lane BEFORE the command: Auto Enables on, receiver in
	; hunt.  With Auto Enables the receiver stays gated off until the MCU
	; asserts /DCDA, so nothing can be latched early.
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
	cp #RSP_BULK_TEST
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,ready_err

	; Transfer length from the READY payload.  BC = byte count, HL = buffer.
	ld a,(rx_frame + 6)
	ld c,a
	ld a,(rx_frame + 7)
	ld b,a
	ld (xfer_len),bc
	ld hl,#bulk_buf

	; --- bulk read loop -------------------------------------------------
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

	; Verify the ramp: byte n must equal n modulo 256.
	ld hl,#bulk_buf
	ld bc,(xfer_len)
	ld d,#0				; expected value
verify_loop:
	ld a,(hl)
	cp d
	jr nz,verify_bad
	inc hl
	inc d
	dec bc
	ld a,b
	or c
	jr nz,verify_loop

	ld de,#msg_ok
	ld c,#BDOS_PRINT
	call BDOS
	call report_len
	ret

verify_bad:
	; A = received, D = expected.  HL points at the offending byte.
	push af
	push de
	ld de,#msg_mismatch
	ld c,#BDOS_PRINT
	call BDOS
	pop de
	ld a,d
	call print_hex_byte		; expected
	ld de,#msg_got
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte		; received
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

bulk_timeout:
	ld de,#msg_bulk_timeout
	ld c,#BDOS_PRINT
	call BDOS
	; Report how many bytes were still outstanding.
	ld a,b
	call print_hex_byte
	ld a,c
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

xport_err:
	push af
	ld de,#msg_xport_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

ready_err:
	push af
	ld de,#msg_ready_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

bad_reply:
	push af
	ld de,#msg_bad_reply
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print "id=xx len=xxxx" from the READY payload.
report_len:
	ld de,#msg_id
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 4)
	call print_hex_byte
	ld de,#msg_len
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 7)
	call print_hex_byte
	ld a,(rx_frame + 6)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print the byte in A as two uppercase hex digits.
; Clobbers: AF, BC, DE (via BDOS).
cts_stuck:
	ld de,#msg_cts_stuck
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
	.ascii "IOC BULK - SIO1/A lane"
	.db 0x0d, 0x0a, '$'
msg_ok:
	.ascii "OK - ramp verified "
	.db '$'
msg_id:
	.ascii "id="
	.db '$'
msg_len:
	.ascii " len="
	.db '$'
msg_mismatch:
	.ascii "MISMATCH expected 0x"
	.db '$'
msg_got:
	.ascii " got 0x"
	.db '$'
msg_bulk_timeout:
	.ascii "bulk timeout, bytes left 0x"
	.db '$'
msg_xport_err:
	.ascii "transport error 0x"
	.db '$'
msg_ready_err:
	.ascii "READY status 0x"
	.db '$'
msg_bad_reply:
	.ascii "unexpected reply 0x"
	.db '$'
msg_cts_stuck:
	.ascii "/CTSA still asserted after bulk"
	.db 0x0d, 0x0a, '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'

chunks:
	.ds 1
xfer_len:
	.ds 2
tx_frame:
	.ds 32
rx_frame:
	.ds 32
bulk_buf:
	.ds 512
