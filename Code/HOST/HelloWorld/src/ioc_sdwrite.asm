; IOC_SDWRT.COM — write a 512-byte ramp to block 0 over the two-lane transport.
;
; The write half of the bulk protocol.  Reverses the read lifecycle:
;
;   Z80                         PIC
;    |-- CMD_SD_WRITE_BULK(LBA) ->|   command lane (IOCALL, SIO1/B)
;    |<-- READY(id, dir, 512) ----|   command lane
;    |====== 7E 81 + 512 bytes ==>|   bulk lane (SIO1/A, ports 30h/31h)
;    |                            |-- write sector to the card
;    |-- CMD_XFER_STATUS -------->|   command lane, ALWAYS
;    |<-- DONE(id, status) -------|   command lane
;
; Two things differ from the read direction and both matter:
;
; 1. DONE IS MANDATORY.  A read can skip it: receiving every byte and seeing
;    /CTSA drop already proves the transfer completed.  A write cannot.  Bytes
;    reaching the MCU says nothing about whether the card stored them, and the
;    card is only touched AFTER the last byte arrives.  The status that matters
;    comes back on the command lane or not at all.
;
; 2. THE PAYLOAD IS LED BY A 7E 81 PREAMBLE.  Sending is not symmetric with
;    receiving.  When the MCU sends, it places the /SYNC edge and owns the byte
;    boundary.  When we send, the MCU supplies the clock but cannot know which
;    edge our transmitter started shifting on, so it searches for this pattern
;    and de-shifts the rest of the stream against it.  Two bytes rather than
;    one: a lone 7Eh occurs at a shifted offset inside a 00-FF ramp, and a
;    false lock would rotate the whole block silently.
;
; Handshake is otherwise the read's mirror image.  /CTSA gates THIS channel's
; transmitter via Auto Enables, so the MCU decides when we may put bits on the
; wire; that is the same line that marks the bulk phase for a read, keeping one
; meaning for the signal.  /DCDA stays deasserted — our receiver is not wanted.
;
; Both of those are now the BIOS's problem, not this program's.  The transmit
; loop that used to live here has moved into IOCBULKW, alongside IOCBULK for
; the read direction, and this file writes no SIO register at all — the whole
; bulk phase is one call.  IOC_BULK.COM keeps its inline loop deliberately, as
; the control case: if a BIOS change breaks the lane, that program still
; exercises it directly.
;
; WARNING: this overwrites block 0, destroying the partition table.  After it
; runs, IOC_SDBLK will report "signature BAD at 510: 0xFEFF" — which is the
; CORRECT result, since a 00-FF ramp puts FEh at offset 510 and FFh at 511.
; The hex dump reading 00 01 02 ... 0F is the confirmation that matters.

	.module ioc_sdwrite
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F
IOCBULKW	= 0xDA48

; Transport status, from cbios_defs.inc
IOC_XPORT_HW_ERROR = 0x03

CMD_SD_WRITE_BULK = 0x07
RSP_SD_WRITE_BULK = 0x87
CMD_XFER_STATUS	= 0x06
RSP_XFER_STATUS	= 0x86

BULK_DATA	= 0x30		; SIO1/A data
BULK_CRC_BYTES	= 2		; CRC-16 trailer the MCU expects
BULK_CTRL	= 0x31		; SIO1/A control
WR0_RESET_ERROR	= 0x30
WR0_RESET_EOM	= 0xc0		; reset Tx Underrun/EOM latch
WR3_RX_OFF	= 0xf0		; Auto Enables, RX disabled: we only transmit
WR5_TX_RTS_ON	= 0xea		; DTR on, 8-bit TX, TX enable, RTS on
WR5_TX_RTS_OFF	= 0xe8		; same with RTS off
RR0_TX_EMPTY	= 0x04		; RR0 bit 2: transmit buffer empty
RR0_CTS		= 0x20		; set while /CTSA is asserted (bulk phase live)
RR1_TX_UNDERRUN	= 0x40		; RR1 bit 6: Tx Underrun/EOM latch

PREAMBLE_0	= 0x7e
PREAMBLE_1	= 0x81

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	xor a
	ld (tx_failed),a		; .ds space is not zeroed by the loader

	call build_ramp

	; ---- build SD_WRITE_BULK(LBA 0) ----
	call zero_frames
	ld a,#CMD_SD_WRITE_BULK
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a		; payload length = 4 (32-bit LBA)
	; bytes 4-7 stay zero => LBA 0

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_err_cmd

	ld a,(rx_frame + 0)
	cp #RSP_SD_WRITE_BULK
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,ready_err			; MCU refused; no bulk phase was staged

	ld a,(rx_frame + 4)
	ld (ready_id),a			; remember for the DONE check

	; ---- bulk write ----
	; One call.  IOCBULKW arms channel A for transmit, sends the preamble,
	; clocks out the 512 bytes, appends the CRC-16 trailer, checks the
	; transmitter for underrun, drops RTS and waits out the card commit --
	; all of it behind DI, which a user program has no business asserting
	; around a transfer of this length.
	;
	; This program used to do every one of those steps itself, and that is
	; why it is worth pointing at: the storage driver is not user space.  A
	; .com file that wants a sector should not have to know that the EOM
	; reset has to follow the first buffered byte, or that a stalled
	; transmitter streams WR7 fill the MCU will happily commit.
	ld hl,#sector_buf
	ld de,#512
	call IOCBULKW
	or a
	jr z,tx_ok
	cp #IOC_XPORT_HW_ERROR
	jp z,tx_underrun		; transmitter ran dry: fill went to the card
	jp bulk_timeout
tx_ok:

	ld de,#msg_tx_done
	ld c,#BDOS_PRINT
	call BDOS

	; ---- DONE: mandatory for a write ----
	; The MCU writes the sector after the last byte lands, so its status
	; only exists now.  There is no fast path here and there must not be.
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
	jp nz,xport_err_done
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jp nz,bad_reply

	; DONE id must match the READY id, or a transfer was lost or overlapped.
	ld a,(rx_frame + 4)
	ld hl,#ready_id
	cp (hl)
	jp nz,id_mismatch
	ld a,(rx_frame + 5)
	or a
	jp nz,done_err

	; DONE is clean -- but only meaningful if we actually sent the payload.
	ld a,(tx_failed)
	or a
	jr nz,tx_failed_report

	ld de,#msg_ok
	ld c,#BDOS_PRINT
	call BDOS
	call report_peek
	call report_raw
	ret

tx_failed_report:
	ld de,#msg_tx_failed
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print the first 8 bytes the MCU says it received, from the DONE payload.
; Expect 00 01 02 03 04 05 06 07 -- the head of the ramp.  All zeros means the
; MCU received fill, not data, whatever the card reads back afterwards.
report_peek:
	ld de,#msg_peek
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 6)
	ld b,#8
rp_loop:
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
	djnz rp_loop
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print the first 8 RAW bytes off the wire, before the MCU de-shifted them.
; Expect 7E 81 then the ramp at some bit offset.  7E 81 followed by zeros means
; the transmitter stopped after the preamble; a ramp visible here but zeros in
; "MCU received" means the de-shift is at fault.
report_raw:
	ld de,#msg_raw
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 14)
	ld b,#8
rr_loop:
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
	djnz rr_loop
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Fill the 512-byte buffer with 00..FF twice.
build_ramp:
	ld hl,#sector_buf
	ld c,#2				; two passes
br_pass:
	ld b,#0				; 256 bytes
	xor a
br_byte:
	ld (hl),a
	inc hl
	inc a
	djnz br_byte
	dec c
	jr nz,br_pass
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

; Transmit stalled.  Still query DONE -- the command lane knows what the MCU
; made of the partial stream -- but the run has already failed, so the result
; must never be reported as OK.  A stalled transmitter under-runs into WR7 fill
; (00h here), which the MCU receives as a perfectly well-formed block of zeros
; and commits happily: DONE says OK while the card holds garbage.  Reporting
; that as success is exactly the bug this flag exists to prevent.
bulk_timeout:
	ld a,#1
	ld (tx_failed),a
	ld de,#msg_bulk_timeout
	ld c,#BDOS_PRINT
	call BDOS
	jp done_query			; get the authoritative reason

; The transmitter ran dry mid-block: whatever reached the card is fill, not the
; ramp.  Still ask DONE, but this run has failed.
tx_underrun:
	ld a,#1
	ld (tx_failed),a
	ld de,#msg_underrun
	ld c,#BDOS_PRINT
	call BDOS
	jp done_query

xport_err_cmd:
	push af
	ld de,#msg_xport_cmd
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

xport_err_done:
	push af
	ld de,#msg_xport_done
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	jr crlf_ret

ready_err:
	push af
	ld de,#msg_ready_err
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
	ld de,#msg_done_key
	ld c,#BDOS_PRINT
	call BDOS
	ret

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
	.ascii "IOC SD WRITE - ramp 00-FF x2 to block 0"
	.db 0x0d, 0x0a, '$'
msg_ok:
	.ascii "OK - sector written"
	.db 0x0d, 0x0a, '$'
msg_bulk_timeout:
	.ascii "bulk transmit timeout"
	.db 0x0d, 0x0a, '$'
msg_underrun:
	.ascii "Tx UNDERRUN - transmitter ran dry mid-block"
	.db 0x0d, 0x0a, '$'
msg_tx_failed:
	.ascii "FAILED - transmit stalled; DONE reports OK but the sector holds"
	.db 0x0d, 0x0a
	.ascii "underrun fill (00h), not the ramp.  Do not trust this write."
	.db 0x0d, 0x0a, '$'
msg_raw:
	.ascii "raw on wire:"
	.db '$'
msg_peek:
	.ascii "MCU received:"
	.db '$'
msg_tx_done:
	.ascii "bulk phase complete, querying DONE..."
	.db 0x0d, 0x0a, '$'
msg_xport_cmd:
	.ascii "transport error on WRITE command 0x"
	.db '$'
msg_xport_done:
	.ascii "transport error on DONE query 0x"
	.db '$'
msg_ready_err:
	.ascii "READY status 0x"
	.db '$'
msg_done_err:
	.ascii "DONE status 0x"
	.db '$'
msg_done_key:
	.db 0x0d, 0x0a
	.ascii "18=cmd24 19=rejected 1A=busy 20=bulkfail 21=nohost 22=nosync"
	.db 0x0d, 0x0a, '$'
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
tx_failed:
	.ds 1
tx_frame:
	.ds 32
rx_frame:
	.ds 32
sector_buf:
	.ds 512
