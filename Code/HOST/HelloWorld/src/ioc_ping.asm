; IOC_PING.COM — Send a PING command to the IO Controller and report the result.
;
; Uses the IOCALL BIOS extension at DA3Fh (ZBIOS_EXT_BASE + 0Ch).
; Builds a 32-byte fixed frame with CMD_PING (01h), issues it via IOCALL, and
; verifies that the MCU replies with RSP_PING (81h).
;
; Frame layout (32 bytes, Z80 -> MCU):
;   byte  0  command class:  CMD_PING = 01h
;   byte  1  sequence:       01h
;   byte  2  status/flags:   00h (filled by MCU in reply)
;   byte  3  payload length: 00h
;   bytes 4-19  payload:     zeroes (MCU echoes them in RSP_PING reply)
;   bytes 20-31 reserved:    zeroes
;
; IOCALL contract:
;   In:  HL = 32-byte TX frame, DE = 32-byte RX buffer (both in TPA RAM)
;   Out: A  = IOC_XPORT_OK (00h) on success, else transport error code
;
; RESET note: if the MCU is absent or SIO1/B is not clocked, IOCALL returns
; IOC_XPORT_TIMEOUT (01h).

	.module ioc_ping
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02		; output char in E; no useful return
BDOS_PRINT	= 0x09		; print '$'-terminated string at DE
IOCALL		= 0xDA3F	; BIOS extended entry: IOC fixed-frame transport

CMD_PING	= 0x01
RSP_PING	= 0x81

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; Zero the entire TX frame before filling header fields.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx

	; Fill frame header.
	ld hl,#tx_frame
	ld a,#CMD_PING
	ld (hl),a		; byte 0: command class
	inc hl
	ld a,#0x01
	ld (hl),a		; byte 1: sequence number

	; Issue IOCALL.
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL

	or a
	jr nz,xport_err

	; Verify reply class.
	ld a,(rx_frame)
	cp #RSP_PING
	jr nz,bad_reply

	ld de,#msg_ok
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

; Print the byte in A as two uppercase hex digits via BDOS CONOUT (fn 2).
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
	; fall through — this ret also serves as print_hex_byte's return
print_hex_nibble:
	add a,#0x30		; bias to '0'
	cp #0x3a		; past '9'?
	jr c,phx_out
	add a,#0x07		; shift into 'A'-'F'
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

msg_banner:
	.ascii "IOC PING"
	.db '$'
msg_ok:
	.ascii " - OK"
	.db 0x0d, 0x0a, '$'
msg_xport_err:
	.ascii " - transport error 0x"
	.db '$'
msg_bad_reply:
	.ascii " - unexpected reply 0x"
	.db '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'

tx_frame:
	.ds 32
rx_frame:
	.ds 32
