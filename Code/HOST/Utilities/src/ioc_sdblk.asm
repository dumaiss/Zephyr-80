; IOC_SDBLK.COM — read a whole 512-byte sector over the two-lane transport.
;
; Full READY -> BULK -> DONE lifecycle.  Both lanes now go through the BIOS:
; the command lane via IOCALL, the bulk lane via IOCBULK.
;
;   Z80                         PIC
;    |-- CMD_SD_READ_BULK(LBA) ->|   command lane (IOCALL, SIO1/B)
;    |                           |-- read sector into MCU SRAM
;    |<-- READY(id, dir, 512) ---|   command lane
;    |<====== 512 bytes =========|   bulk lane (IOCBULK, SIO1/A)
;    |-- CMD_XFER_STATUS ------->|   command lane, ERROR PATH ONLY
;    |<-- DONE(id, status) ------|   command lane
;
; This program owns no SIO registers at all — IOCBULK does the arming, software
; admission, common-packet validation, CRC check, RTS and /CTSA handling.
;
; On the happy path the DONE query is skipped: receiving every byte and seeing
; the PIC drop /CTSA already proves the read completed.  DONE is still issued
; whenever anything goes wrong, so the authoritative status is never lost.
;
; The MCU reads the card BEFORE replying READY, so SD latency is outside the
; bulk transaction.  It then waits for RTS on channel A before clocking — RTS
; that IOCBULK asserts — so the handoff is deterministic rather than timed.
; Auto Enables is off so RX remains continuously enabled.  IOCBULK polls /DCDA
; for software receive admission, while /CTSA marks the bulk phase.
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
IOCALL		= 0xDA3F	; ZBIOS_EXT_BASE + 0Ch: compatibility mailbox transport
IOCBULK		= 0xDA45	; ZBIOS_EXT_BASE + 12h: bulk-lane receive

CMD_SD_READ_BULK = 0x05
RSP_SD_READ_BULK = 0x85
CMD_XFER_STATUS	= 0x06
RSP_XFER_STATUS	= 0x86

start:
	; Private stack.
	;
	; CP/M enters a .COM through CALL TBASE, on the CCP's own stack -- sixteen
	; bytes total, several of them already spent getting here.  The BIOS
	; transport nests roughly twenty-five bytes deep and runs with interrupts
	; enabled while it waits for the MCU, so calling it from here used to run
	; off the bottom of that stack and into the CCP's own code.  Nothing
	; repaired it: a .COM exits through RET, not a warm boot, so WBOOT's
	; restore_ccp_from_rom never ran and the next CCP command died.
	;
	; The BIOS shims for IOCALL/IOCBULK/IOCBULKW now switch stacks themselves,
	; so this is no longer the only thing standing between here and a wedged
	; machine -- but BDOS nesting and an interrupt frame still land on whatever
	; stack this program is running on, and sixteen bytes is not enough for
	; those either.
	;
	; Entered through CALL so every RET in the body below lands back here and
	; the CCP's stack pointer is put back exactly once.
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
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

	; No pre-arming here any more.  IOCBULK arms the receiver itself, and the
	; PIC will not clock a single edge until it sees RTS, which IOCBULK asserts
	; — so there is nothing to race against between the command and the bulk
	; phase.
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

	; ---- bulk read, through the BIOS ----
	; IOCBULK owns the entire SIO1/A handshake: arm the receiver, assert RTS,
	; drain the stream, release RTS, confirm the PIC dropped /CTSA.  Length
	; comes from READY rather than being assumed to be 512, so a short transfer
	; is the PIC's to declare.
	;
	; HL = destination, DE = byte count.  A returns the transport status.
	ld hl,#sector_buf
	ld a,(rx_frame + 6)
	ld e,a
	ld a,(rx_frame + 7)
	ld d,a
	ld (xfer_len),de
	call IOCBULK
	or a
	jp nz,bulk_err

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

; IOCBULK failed.  Its status says how the bulk lane failed; the command lane
; still has the authoritative reason, so ask for it.
bulk_err:
	push af
	ld de,#msg_bulk_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_bulk_key
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
msg_bulk_err:
	.ascii "IOCBULK failed 0x"
	.db '$'
msg_bulk_key:
	.db 0x0d, 0x0a
	.ascii "01=timeout 02=bad length 03=/CTSA stuck"
	.db 0x0d, 0x0a, '$'
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

; Private stack, and the CCP stack pointer parked while it is in use.
; Reserved, not emitted: the .COM image ends at the last byte above.
entry_sp:	.ds 2
	.ds 128				; BDOS nesting plus an interrupt frame
stack_top:
