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
; The MCU is the synchronous clock master and there is no ready signal from the
; Z80 on the bulk lane, so the MCU waits a fixed guard time after READY before
; it starts clocking.  This program must therefore enter its read loop promptly
; once IOCALL returns -- do not print anything in between.
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
WR3_RX_HUNT	= 0xd1		; 8-bit RX, enter hunt, RX enable
RR0_RX_AVAIL	= 0x01

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

	; Prime the bulk lane BEFORE the command, so the receiver is already in
	; hunt when the MCU starts clocking after its guard delay.
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
	; No printing above this point once IOCALL has returned: the MCU is
	; already counting down its guard delay before it starts clocking.
bulk_next:
	ld de,#0			; per-byte timeout counter
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
	; --- end bulk read --------------------------------------------------

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
msg_crlf:
	.db 0x0d, 0x0a, '$'

xfer_len:
	.ds 2
tx_frame:
	.ds 32
rx_frame:
	.ds 32
bulk_buf:
	.ds 512
