; IOC_BULK.COM — verified throughput test for the SIO1/A bulk lane.
;
; This is the old one-shot lane check repeated as a quiet flood.  It deliberately
; does not touch the SD card: every transfer asks the MCU to generate a known
; ramp in SRAM, receives it through the normal READY -> IOCBULK path, verifies
; the common-packet CRC in IOCBULK, and then verifies every payload byte here.
;
; The controller's Timer3 PROFILE counters time the flood.  This is the same
; independent, wrap-safe clock used by SDBENCH and remains valid while IOCBULK
; masks Z80 interrupts.  Two rates are reported:
;
;   bulk lane        IOCBULK only: admission, packet transfer and CRC check
;   active transport IOCALL + IOCBULK, excluding the semantic ramp check
;
; The split is intentional: this program measures link capacity rather than
; CP/M, console, cache or SD-card performance.
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
; The payload is a repeated 00 01 02 ... FF ramp, so a shifted or dropped byte
; is obvious.  No output is emitted inside the flood.
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
CMD_PROFILE	= 0x0b
RSP_PROFILE	= 0x8b
PROFILE_RESET	= 0x01
PROFILE_PAGE_BULK_TX = 0x01

REQ_LEN		= 512		; maximum normal Bulk payload
FLOOD_COUNT	= 128		; 128 * 512 bytes = 64 KiB
RATE_NUMERATOR	= 64000		; 64 KiB * 1000 ms/s -> integer KiB/s

PROF_RX		= 0
PROF_DECODE	= 2
PROF_DISPATCH	= 4
PROF_SEND	= 6
PROF_BULK	= 8
PROF_TOTAL	= 10

BPROF_WAIT	= 0
BPROF_PREP	= 2
BPROF_DATA	= 4
BPROF_DONE	= 6

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	ld hl,#0
	ld (flood_completed),hl
	call profile_reset
	or a
	jp nz,profile_err

; One normal command/READY/Bulk transaction.  Keeping this exact path is what
; makes the result the capacity of the transport the filesystem actually uses.
flood_loop:
	call zero_frames

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

	; IOCBULK already checked the packet CRC.  Check the semantic ramp too, but
	; stay silent so console traffic cannot enter the measured interval.
	ld hl,#bulk_buf
	ld bc,(xfer_len)
	ld d,#0				; expected value
verify_loop:
	ld a,(hl)
	cp d
	jp nz,verify_bad
	inc hl
	inc d
	dec bc
	ld a,b
	or c
	jr nz,verify_loop

	ld hl,(flood_completed)
	inc hl
	ld (flood_completed),hl
	ld a,h
	or a
	jr nz,flood_done
	ld a,l
	cp #FLOOD_COUNT
	jp c,flood_loop

flood_done:
	ld hl,#profile_words
	call profile_get
	or a
	jp nz,profile_err
	ld hl,#bulk_profile_words
	call profile_get_bulk
	or a
	jp nz,profile_err
	call calculate_times

	ld de,#msg_ok
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,(flood_completed)
	call print_dec_word
	ld de,#msg_ok_tail
	ld c,#BDOS_PRINT
	call BDOS

	ld de,#msg_command_ms
	ld hl,#command_ms
	call say_dec_word
	ld de,#msg_bulk_ms
	ld hl,#bulk_ms
	call say_dec_word
	ld de,#msg_bulk_wait_ms
	ld hl,#(bulk_profile_words + BPROF_WAIT)
	call say_dec_word
	ld de,#msg_bulk_prep_ms
	ld hl,#(bulk_profile_words + BPROF_PREP)
	call say_dec_word
	ld de,#msg_bulk_data_ms
	ld hl,#(bulk_profile_words + BPROF_DATA)
	call say_dec_word
	ld de,#msg_bulk_done_ms
	ld hl,#(bulk_profile_words + BPROF_DONE)
	call say_dec_word
	ld de,#msg_total_ms
	ld hl,#total_ms
	call say_dec_word

	ld de,#msg_bulk_rate
	ld c,#BDOS_PRINT
	call BDOS
	ld de,(bulk_ms)
	call rate_from_ms
	call print_dec_word
	ld de,#msg_rate_tail
	ld c,#BDOS_PRINT
	call BDOS

	ld de,#msg_total_rate
	ld c,#BDOS_PRINT
	call BDOS
	ld de,(total_ms)
	call rate_from_ms
	call print_dec_word
	ld de,#msg_rate_tail
	ld c,#BDOS_PRINT
	call BDOS
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
	call report_completed
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
	call report_completed
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
	call report_completed
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
	call report_completed
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
	call report_completed
	ret

profile_err:
	push af
	ld de,#msg_profile_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	call report_completed
	ret
; Clear both compatibility mailboxes.  RX is filled with A5h so a transaction
; that never receives a reply remains visibly different from a valid zero field.
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

; PROFILE reset/get.  Firmware applies reset after the reset reply is complete,
; so neither control transaction contaminates the captured flood interval.
; Returns A=0, a transport status, or F1h/F2h for an invalid PROFILE reply.
profile_reset:
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 3),a
	ld a,#PROFILE_RESET
	ld (tx_frame + 4),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	ret nz
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr nz,profile_bad_class
	ld a,(rx_frame + 2)
	or a
	ret

; Input HL=12-byte destination for the six little-endian millisecond totals.
profile_get:
	ld (profile_dest),hl
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	ret nz
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr nz,profile_bad_class
	ld a,(rx_frame + 2)
	or a
	jr nz,profile_bad_status
	ld hl,#(rx_frame + 4)
	ld de,(profile_dest)
	ld bc,#12
	ldir
	xor a
	ret

; PROFILE page 1: four bulk-TX subphase totals, eight payload bytes.
profile_get_bulk:
	ld (profile_dest),hl
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld a,#0x02
	ld (tx_frame + 3),a
	ld a,#PROFILE_PAGE_BULK_TX
	ld (tx_frame + 5),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	ret nz
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr nz,profile_bad_class
	ld a,(rx_frame + 2)
	or a
	jr nz,profile_bad_status
	ld a,(rx_frame + 3)
	cp #0x08
	jr nz,profile_bad_page
	ld hl,#(rx_frame + 4)
	ld de,(profile_dest)
	ld bc,#8
	ldir
	xor a
	ret

profile_bad_class:
	ld a,#0xf1
	ret
profile_bad_status:
	ld a,#0xf2
	ret
profile_bad_page:
	ld a,#0xf3
	ret

; Build the displayed totals from the controller's six PROFILE words.  Command
; + READY is RX + DECODE + DISPATCH + SEND; Bulk and TOTAL are direct readings.
calculate_times:
	ld hl,(profile_words + PROF_RX)
	ld de,(profile_words + PROF_DECODE)
	add hl,de
	ld de,(profile_words + PROF_DISPATCH)
	add hl,de
	ld de,(profile_words + PROF_SEND)
	add hl,de
	ld (command_ms),hl
	ld hl,(profile_words + PROF_BULK)
	ld (bulk_ms),hl
	ld hl,(profile_words + PROF_TOTAL)
	ld (total_ms),hl
	ret

; Print the label at DE, the little-endian word at HL in decimal, then " ms".
say_dec_word:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call print_dec_word
	ld de,#msg_ms_tail
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Decimal 16-bit output.  Repeated subtraction is bounded to nine iterations per
; digit and is smaller than carrying a general division routine plus conversion.
; Input: HL=value.  Clobbers AF, BC, DE, HL.
print_dec_word:
	xor a
	ld (dec_started),a
	ld de,#10000
	call print_dec_digit
	ld de,#1000
	call print_dec_digit
	ld de,#100
	call print_dec_digit
	ld de,#10
	call print_dec_digit
	ld a,#1				; the units digit is never suppressed
	ld (dec_started),a
	ld de,#1
	jp print_dec_digit

print_dec_digit:
	ld b,#'0
pdd_subtract:
	or a
	sbc hl,de
	jr c,pdd_restore
	inc b
	jr pdd_subtract
pdd_restore:
	add hl,de
	ld a,b
	cp #'0
	jr nz,pdd_emit
	ld a,(dec_started)
	or a
	ret z
pdd_emit:
	ld a,#1
	ld (dec_started),a
	push bc
	push de
	push hl
	ld e,b
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop de
	pop bc
	ret

; Convert the fixed 64 KiB flood and a millisecond duration into integer KiB/s:
; 64 * 1000 / ms.  Input DE=milliseconds, output HL=KiB/s.  The expected
; quotient is small, so repeated subtraction is both clear and cheap here.
rate_from_ms:
	ld a,d
	or e
	jr z,rate_zero
	ld hl,#RATE_NUMERATOR
	ld bc,#0
rate_divide:
	or a
	sbc hl,de
	jr c,rate_done
	inc bc
	jr rate_divide
rate_done:
	ld h,b
	ld l,c
	ret
rate_zero:
	ld hl,#0
	ret

report_completed:
	ld de,#msg_completed
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,(flood_completed)
	call print_dec_word
	ld de,#msg_transfer_tail
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
	.ascii "IOC BULK FLOOD - 128 x 512 bytes (64 KiB)"
	.db 0x0d, 0x0a, '$'
msg_ok:
	.ascii "OK - packet CRC and ramp verified: "
	.db '$'
msg_ok_tail:
	.ascii " transfers"
	.db 0x0d, 0x0a, '$'
msg_command_ms:
	.ascii "  command + READY     "
	.db '$'
msg_bulk_ms:
	.ascii "  IOCBULK calls       "
	.db '$'
msg_bulk_wait_ms:
	.ascii "    host-ready wait   "
	.db '$'
msg_bulk_prep_ms:
	.ascii "    admission/setup   "
	.db '$'
msg_bulk_data_ms:
	.ascii "    packet + CRC      "
	.db '$'
msg_bulk_done_ms:
	.ascii "    teardown          "
	.db '$'
msg_total_ms:
	.ascii "  timed total         "
	.db '$'
msg_ms_tail:
	.ascii " ms"
	.db 0x0d, 0x0a, '$'
msg_bulk_rate:
	.ascii "  Bulk lane           "
	.db '$'
msg_total_rate:
	.ascii "  active transport    "
	.db '$'
msg_rate_tail:
	.ascii " KiB/s"
	.db 0x0d, 0x0a, '$'
msg_completed:
	.ascii "completed before failure: "
	.db '$'
msg_transfer_tail:
	.ascii " transfers"
	.db 0x0d, 0x0a, '$'
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
msg_profile_err:
	.ascii "PROFILE error 0x"
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
flood_completed:
	.ds 2
dec_started:
	.ds 1
profile_dest:
	.ds 2
profile_words:
	.ds 12
bulk_profile_words:
	.ds 8
command_ms:
	.ds 2
bulk_ms:
	.ds 2
total_ms:
	.ds 2
tx_frame:
	.ds 32
rx_frame:
	.ds 32
bulk_buf:
	.ds 512
