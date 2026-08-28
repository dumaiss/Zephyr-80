; IOC_PING.COM — Send a PING command to the IO Controller and report the result.
;
; Uses the IOCALL BIOS extension at DA3Fh (ZBIOS_EXT_BASE + 0Ch).
; Builds a 32-byte compatibility mailbox with CMD_PING (01h), issues it via
; IOCALL, and verifies that the MCU replies with RSP_PING (81h).  IOCALL maps
; the mailbox to the common A5/5A variable-length packet on the wire.
;
; Frame layout (32 bytes, Z80 -> MCU):
;   byte  0  command class:  CMD_PING = 01h
;   byte  1  sequence:       01h
;   byte  2  status/flags:   00h (filled by MCU in reply)
;   byte  3  payload length: 10h
;   bytes 4-19  payload:     test pattern (MCU echoes it in RSP_PING reply)
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
BDOS_PRINT	= 0x09
CMD_PROFILE	= 0x0B
; Fixed-address link diagnostic block written by the BIOS when a reply never
; arrives.  Read directly, because a broken link cannot answer a query.
IOC_DIAG_BASE	= 0xDCC0
RSP_PROFILE	= 0x8B		; print '$'-terminated string at DE
IOCALL		= 0xDA3F	; BIOS extended entry: IOC compatibility transport

CMD_PING	= 0x01
RSP_PING	= 0x81
IOC_FW_LEVEL	= 19
ZBIOS_XPORT_LEVEL = 7
ZBIOS_XPORT_LEVEL_ADDR = 0xDF7A

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jp nz,stale_bios

	; Zero the entire TX frame before filling header fields.
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

	; Fill frame header.
	ld hl,#tx_frame
	ld a,#CMD_PING
	ld (hl),a		; byte 0: command class
	inc hl
	ld a,#0x01
	ld (hl),a		; byte 1: sequence number
	inc hl			; byte 2: status/flags remains zero
	inc hl			; byte 3: payload length
	ld a,#0x10
	ld (hl),a
	inc hl			; byte 4: payload start
	ld de,#ping_payload
	ld b,#16
copy_payload:
	ld a,(de)
	ld (hl),a
	inc de
	inc hl
	djnz copy_payload

	; Issue IOCALL.
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL

	or a
	jp nz,xport_err

	; Verify reply class.
	ld a,(rx_frame)
	cp #RSP_PING
	jp nz,bad_reply
	; Sequence is no longer checked here: it rolls per transaction and IOCALL
	; validates the echo itself, rejecting a mismatch as IOC_XPORT_BAD_SEQ.
	; Comparing it against a constant would fail on every transaction but the
	; first.
	ld a,(rx_frame + 2)
	or a
	jp nz,bad_reply
	ld a,(rx_frame + 3)
	cp #0x1a			; diagnostics extend through mailbox byte 29
	jp nz,bad_reply
	ld hl,#(rx_frame + 4)
	ld de,#ping_payload
	ld b,#16
verify_payload:
	ld a,(de)
	cp (hl)
	jp nz,bad_reply
	inc de
	inc hl
	djnz verify_payload

	ld de,#msg_ok
	ld c,#BDOS_PRINT
	call BDOS

	; ---- firmware level and power handshake ----
	ld de,#msg_fw
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 20)		; IOC_OFF_PING_LEVEL
	call print_hex_byte
	ld a,(rx_frame + 20)
	cp #IOC_FW_LEVEL
	jp nz,stale_fw

	; Decode the power snapshot rather than printing a hex byte nobody can
	; read at a glance.  Each line is one question the handshake raises.
	ld a,(rx_frame + 21)		; IOC_OFF_PING_POWER
	ld (pwr_bits),a

	ld de,#msg_pwr_drv
	call say_bit_2			; bit 2: do we own /PWR_OFF
	ld de,#msg_pwr_lat
	call say_bit_1			; bit 1: what we drive it to
	ld de,#msg_pwr_pin
	call say_bit_0			; bit 0: what it actually sits at
	ld de,#msg_sd_pin
	call say_bit_3			; bit 3: is the PMU asking
	ld de,#msg_sd_latch
	call say_bit_4			; bit 4: was a falling edge seen
	ld de,#msg_sd_wpu
	call say_bit_5			; bit 5: is our pull-up on
	ld de,#msg_link_synced
	call say_bit_6			; bit 6: PIC steady-sync state

	; Silent SD retry accounting.  A retried read succeeds, so these two
	; numbers are the only place it is ever visible.
	ld de,#msg_retry
	ld hl,#(rx_frame + 22)
	call say_word
	ld de,#msg_reinit
	ld hl,#(rx_frame + 24)
	call say_word
	ld de,#msg_rx_edges
	ld hl,#(rx_frame + 26)
	call say_word
	ld de,#msg_tx_edges
	ld hl,#(rx_frame + 28)
	call say_word

	; PROFILE is a second transaction.  It must come last: it reports the
	; accumulated totals, and issuing it earlier would leave its own exchange
	; out of the numbers it is printing.
	; Both frames cleared inline; ioc_ping has no shared helper for this and
	; A5h in the RX frame is what makes "no reply at all" visible.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx2:
	ld (hl),a
	inc hl
	djnz zero_tx2
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx2:
	ld (hl),a
	inc hl
	djnz zero_rx2

	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,prof_bad
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr nz,prof_bad

	ld de,#msg_prof
	ld hl,#(rx_frame + 4)
	call say_word
	ld de,#msg_p1
	ld hl,#(rx_frame + 6)
	call say_word
	ld de,#msg_p2
	ld hl,#(rx_frame + 8)
	call say_word
	ld de,#msg_p3
	ld hl,#(rx_frame + 10)
	call say_word
	ld de,#msg_p4
	ld hl,#(rx_frame + 12)
	call say_word
	ld de,#msg_p5
	ld hl,#(rx_frame + 14)
	call say_word
	ld de,#msg_calls
	ld hl,#(rx_frame + 16)
	call say_word
	ld de,#msg_aborts
	ld hl,#(rx_frame + 18)
	call say_word

	; SD CMD0 response trace; see sd_card.h for how to read it.
	ld de,#msg_sdtr
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 20)
	ld b,#8
sdtr_loop:
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
	djnz sdtr_loop
	ret
prof_bad:
	ld de,#msg_proferr
	ld c,#BDOS_PRINT
	call BDOS
	ret

; The fixed-address block the BIOS fills in when a reply never arrives.  Always
; printed: it costs four lines and it is the only evidence available when the
; link is too broken to answer anything.
say_link_diag:
	ld de,#msg_diag
	ld a,(IOC_DIAG_BASE + 0)
	call say_byte
	ld de,#msg_diag1
	ld a,(IOC_DIAG_BASE + 1)
	call say_byte
	ld de,#msg_diag2
	ld a,(IOC_DIAG_BASE + 2)
	call say_byte
	ld de,#msg_diag3
	ld a,(IOC_DIAG_BASE + 3)
	call say_byte
	ld de,#msg_diag4
	ld a,(IOC_DIAG_BASE + 4)
	call say_byte

	ld de,#msg_diag5
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(IOC_DIAG_BASE + 5)
	ld b,#8
sld_loop:
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
	djnz sld_loop
	ld de,#msg_diag6
	ld a,(IOC_DIAG_BASE + 13)
	call say_byte
	ret

; Print the label at DE then the byte in A.
say_byte:
	push af
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ret

; Print the label at DE then the little-endian word at HL, high byte first.
;
; BOTH bytes are fetched BEFORE anything is printed, because print_hex_byte
; calls BDOS and CP/M's BDOS preserves nothing -- HL included.  The first
; version of this walked the pointer between the two prints, so it displayed a
; correct high byte followed by whatever address the clobbered HL happened to
; land on.  Every counter came out as 00FF, and the FF was pure fiction; it cost
; a debugging round on the theory that the SD path was retrying 255 times.
say_word:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ld a,(hl)			; low byte
	inc hl
	ld h,(hl)			; high byte; the pointer is finished with
	ld l,a				; HL = high:low, both now in registers
	ld a,h
	push hl
	call print_hex_byte
	pop hl
	ld a,l
	call print_hex_byte
	ret

; Print the label at DE then 0 or 1 for the selected bit of pwr_bits.
say_bit_5:
	ld b,#0x20
	jr say_bit
say_bit_6:
	ld b,#0x40
	jr say_bit
say_bit_4:
	ld b,#0x10
	jr say_bit
say_bit_3:
	ld b,#0x08
	jr say_bit
say_bit_2:
	ld b,#0x04
	jr say_bit
say_bit_1:
	ld b,#0x02
	jr say_bit
say_bit_0:
	ld b,#0x01
say_bit:
	push bc
	ld c,#BDOS_PRINT
	call BDOS
	pop bc
	ld a,(pwr_bits)
	and b
	ld a,#0x30			; '0'
	jr z,say_bit_out
	inc a				; '1'
say_bit_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	jp BDOS

xport_err:
	push af
	ld de,#msg_xport_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	call dump_rx_frame
	call say_link_diag
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

stale_bios:
	ld de,#msg_stale_bios
	ld c,#BDOS_PRINT
	call BDOS
	ret

stale_fw:
	ld de,#msg_stale_fw
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

; Dump the 32-byte IOCALL RX frame buffer as hex bytes.
; This is primarily useful after transport error 12h, where IOCALL may have
; stored the reply start and some partial body bytes before timing out.
; Clobbers: AF, BC, DE, HL.
dump_rx_frame:
	ld de,#msg_rx_dump
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame
	ld b,#32
dump_rx_loop:
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
	djnz dump_rx_loop
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
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
msg_stale_bios:
	.ascii " - BIOS transport level mismatch (need 07)"
	.db 0x0d, 0x0a, '$'
msg_stale_fw:
	.ascii " - controller firmware level mismatch (need 13)"
	.db 0x0d, 0x0a, '$'
msg_fw:		.ascii "fw level $"
msg_pwr_drv:	.db 13,10
		.ascii "  /PWR_OFF     driven by us : $"
msg_pwr_lat:	.ascii "  /PWR_OFF     we drive     : $"
msg_pwr_pin:	.ascii "  /PWR_OFF     pin reads    : $"
msg_sd_pin:	.ascii "  /SHUTDOWN_RQ pin reads    : $"
msg_sd_latch:	.ascii "  /SHUTDOWN_RQ edge latched : $"
msg_sd_wpu:	.ascii "  /SHUTDOWN_RQ pull-up on   : $"
msg_link_synced:
		.ascii "  PIC persistent sync      : $"
msg_retry:	.db 13,10
		.ascii "  service calls           : $"
msg_reinit:	.ascii "  .. aborted, no frame    : $"
msg_rx_edges:	.ascii "  current request clocks  : $"
msg_tx_edges:	.ascii "  previous reply clocks   : $"
msg_prof:	.db 13,10
		.ascii "  ms in rx window         : $"
msg_p1:		.ascii "  ms in frame decode      : $"
msg_p2:		.ascii "  ms in dispatch/card     : $"
msg_p3:		.ascii "  ms in reply send        : $"
msg_p4:		.ascii "  ms in bulk phase        : $"
msg_p5:		.ascii "  ms total (all phases)   : $"
msg_calls:	.ascii "  service calls           : $"
msg_aborts:	.ascii "  .. aborted, no frame    : $"
msg_sdtr:	.db 13,10
		.ascii "  SD CMD0 trace         :$"
msg_proferr:	.ascii "  PROFILE failed$"
msg_diag:	.db 13,10
		.ascii "  link RR0 (b4=hunting)  : $"
msg_diag1:	.ascii "  link RR1 (rx errors)  : $"
msg_diag2:	.ascii "  ioc_rx_synced         : $"
msg_diag3:	.ascii "  ioc_link_ready        : $"
msg_diag4:	.ascii "  scan budget left (A0) : $"
msg_diag5:	.ascii "  first 8 non-FF bytes  :$"
msg_diag6:	.ascii "  .. count captured     : $"
msg_crlf:
	.db 0x0d, 0x0a, '$'
msg_rx_dump:
	.db 0x0d, 0x0a
	.ascii "RX:"
	.db '$'

ping_payload:
	.db 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
	.db 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xf0, 0x0f

tx_frame:
	.ds 32
rx_frame:
	.ds 32
pwr_bits:	.ds 1
