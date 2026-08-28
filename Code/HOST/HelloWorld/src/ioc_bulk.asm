; IOC_BULK.COM — bring up the SIO1/A bulk lane.
;
; Two-lane transport check.  The command lane (SIO1/B, via the IOCALL BIOS
; extension) asks the IO Controller for a bulk transfer; the MCU replies READY
; with a transfer id, direction and length, then streams that many bytes on the
; bulk lane (SIO1/A).  Both lanes go through the BIOS transport so this test
; exercises the same persistent-sync and common-packet implementation as the
; storage diagnostics.
;
;   Z80                         PIC
;    |-- CMD_BULK_TEST(len) ---->|      command lane, via IOCALL
;    |<-- READY(id, dir, len) ---|      command lane
;    |<====== len bytes =========|      bulk lane, via IOCBULK
;
; IOCBULK owns RTS, software admission through /DCDA, the A5 5A packet marker,
; TYPE/SEQ/STATUS validation and CRC verification.  The test never writes an
; SIO register, so it cannot accidentally disable RX or issue Enter Hunt.
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
;   byte  3  payload length: 08h
;   byte  4  transfer id
;   byte  5  direction (00h = MCU -> Z80)
;   bytes 6-7  transfer length, little-endian

	.module ioc_bulk
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F	; BIOS extended entry: IOC compatibility transport
IOCBULK		= 0xDA45	; BIOS extended entry: common-packet bulk receive

IOC_BULK_DIAG_REASON	= 0xDCCE
IOC_BULK_DIAG_COUNT	= 0xDCCF
IOC_BULK_DIAG_SCAN	= 0xDCD0
IOC_BULK_DIAG_HEADER	= 0xDCD8
IOC_BULK_DIAG_RR0	= 0xDCDD
IOC_BULK_DIAG_RR1	= 0xDCDE
IOC_BULK_DIAG_SYNCED	= 0xDCDF
IOC_BULK_DIAG_EXPECT_LEN = 0xDCE0
IOC_BULK_DIAG_EXPECT_TYPE = 0xDCE2
IOC_BULK_DIAG_EXPECT_SEQ = 0xDCE3

CMD_BULK_TEST	= 0x04
RSP_BULK_TEST	= 0x84

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
	ld a,(rx_frame + 3)
	cp #0x08
	jp nz,bad_reply
	ld a,(rx_frame + 5)
	or a				; MCU -> Z80 direction
	jp nz,bad_reply
	ld a,(rx_frame + 6)
	cp #<REQ_LEN
	jp nz,bad_reply
	ld a,(rx_frame + 7)
	cp #>REQ_LEN
	jp nz,bad_reply

	; Transfer length from READY.  IOCBULK receives DATA only; the common
	; packet header and CRC remain transport-owned.
	ld a,(rx_frame + 6)
	ld e,a
	ld a,(rx_frame + 7)
	ld d,a
	ld (xfer_len),de
	ld hl,#bulk_buf
	call IOCBULK
	or a
	jp nz,bulk_timeout

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
	push af
	ld de,#msg_bulk_timeout
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	call report_bulk_diag
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

; Decode BIOS fixed-RAM diagnostics for an IOCBULK rejection.  This is kept in
; the test program rather than the transport's timed path, so capturing enough
; information to distinguish alignment from metadata cannot cause an overrun.
report_bulk_diag:
	ld de,#msg_diag_reason
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_BULK_DIAG_REASON)
	call print_hex_byte
	ld de,#msg_diag_count
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_BULK_DIAG_COUNT)
	call print_hex_byte
	ld de,#msg_diag_scan
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#IOC_BULK_DIAG_SCAN
	ld b,#1
	call dump_diag_bytes
	ld de,#msg_diag_header
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#IOC_BULK_DIAG_HEADER
	ld b,#5
	call dump_diag_bytes
	ld de,#msg_diag_rr
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_BULK_DIAG_RR0)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_BULK_DIAG_RR1)
	call print_hex_byte
	ld de,#msg_diag_sync
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_BULK_DIAG_SYNCED)
	call print_hex_byte
	ld de,#msg_diag_expect
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_BULK_DIAG_EXPECT_LEN + 1)
	call print_hex_byte
	ld a,(IOC_BULK_DIAG_EXPECT_LEN)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_BULK_DIAG_EXPECT_TYPE)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_BULK_DIAG_EXPECT_SEQ)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	jp BDOS

; B bytes at HL, prefixed with spaces.
dump_diag_bytes:
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
	djnz dump_diag_bytes
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
	.ascii "bulk transport error 0x"
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
msg_diag_reason:
	.ascii "bulk diag reason="
	.db '$'
msg_diag_count:
	.ascii " count="
	.db '$'
msg_diag_scan:
	.ascii " last"
	.db '$'
msg_diag_header:
	.ascii " hdr"
	.db '$'
msg_diag_rr:
	.ascii " rr="
	.db '$'
msg_diag_sync:
	.ascii " sync="
	.db '$'
msg_diag_expect:
	.ascii " exp(len/type/seq)="
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
