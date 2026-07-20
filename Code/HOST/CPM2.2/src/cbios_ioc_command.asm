; Zephyr-80 BIOS IOC Command-channel byte helpers — Phase 1.
;
; These routines provide polled byte I/O and fixed-frame send/receive for
; the IO Controller Command channel (SIO1/B — bring-up retarget; see
; cbios_defs.inc).
;
; Command channel = SIO1/B
;   DATA port = SIO_COMMAND_DATA_PORT = 32h
;   CTRL port = SIO_COMMAND_CTRL_PORT = 33h
;
; SIO1/A channel-A outputs failed hardware probing; the PIC bit-bang bring-up
; uses channel B.
;
; Hardware model:
;   The MCU is the synchronous clock master.  TXC/RXC for SIO1/B are supplied
;   by the MCU.  The MCU clocks only during active transactions.  Clocking alone
;   does not trigger a useful Z80 SIO interrupt; the MCU must deliver a complete
;   External Sync byte window.  No WAIT/READY; no INIR/OTIR; polled byte I/O only.
;   No SIO1/B interrupts in Phase 1.
;
; SIO1/B External Sync framing:
;   BIOS sends a software preamble byte followed by 32 transparent IOC payload
;   bytes.  The MCU drives /SYNCB and the clock; BIOS receives bytes from the
;   SIO RX buffer and hunts the preamble before copying the 32-byte reply.
;
; Placement:
;   CBIOS_IOC_COMMAND_CODE_BASE = F52Ch (gap after VDrip console driver).

	.globl sio_command_rts_assert,sio_command_rts_release
	.globl sio_command_put_byte,sio_command_get_byte
	.globl ioc_command_send_frame,ioc_command_recv_frame
	.globl IOC_CMD_CODE_START,IOC_CMD_CODE_END

	.area CODE (ABS)
	.org CBIOS_IOC_COMMAND_CODE_BASE

IOC_CMD_CODE_START:

; ---------------------------------------------------------------------------
; sio_command_rts_assert
; Assert RTS on SIO1/B (Command channel) to signal the MCU to start clocking.
; Writes WR5 = 0x6A (TX enabled + RTS on) -> /RTSB goes LOW.  The MCU detects
; this high->low edge on the channel-B RTS input.  sio_command_init / a prior
; rts_release leave TX disabled and /RTSB HIGH, so this write produces a clean
; falling edge.
; In:  nothing
; Out: A = 0
; Clobbers: AF
; ---------------------------------------------------------------------------
sio_command_rts_assert:
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_ON
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_rts_release
; Release RTS on SIO1/B (Command channel) after the transaction completes.
;
; Writes WR5 = 0x00 (TX DISABLED + RTS off), NOT 0x68.  In External Sync mode an
; enabled transmitter never empties (it streams sync/fill idle), so the SIO's
; delayed /RTS-deassert never fires and clearing the RTS bit alone leaves /RTSB
; latched LOW.  Disabling TX satisfies the transmit-empty condition so /RTSB
; returns HIGH — restoring the idle state and letting the next transaction's
; rts_assert generate a fresh falling edge for the MCU.
; In:  nothing
; Out: A = 0
; Clobbers: AF
; ---------------------------------------------------------------------------
sio_command_rts_release:
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_IDLE
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_put_byte
; Send one byte on SIO1/B (Command channel) with polling.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 2 (TX buffer empty) before writing.
; In:  C = byte to send
; Out: A = IOC_XPORT_OK (0) on success, IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, DE
; ISR-safe: No.  Blocking poll.
;
; DEBUG BRING-UP: the wait is a very long 24-bit countdown (inner DE =
; SIO_COMMAND_TIMEOUT, repeated SIO_COMMAND_TIMEOUT_OUTER times in B) so the PIC
; side can be single-stepped without the Z80 bailing out, yet it still returns
; IOC_XPORT_TIMEOUT instead of hanging forever.  B is saved/restored so the
; caller's frame counter survives.  For production, set OUTER = 1 (or restore the
; original single-DE wait).
; ---------------------------------------------------------------------------
sio_command_put_byte:
	push bc				; preserve caller B (frame counter) and C (data byte)
	ld b,#SIO_COMMAND_TIMEOUT_OUTER
SIO_CMD_PUT_OUTER:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_PUT_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_TX_READY
	jr nz,SIO_CMD_PUT_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_PUT_WAIT
	djnz SIO_CMD_PUT_OUTER
	pop bc				; restore caller B/C
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_PUT_READY:
	pop bc				; restore caller B; recover data byte in C
	ld a,c
	out (SIO_COMMAND_DATA_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_get_byte
; Receive one byte from SIO1/B (Command channel) with polling.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 0 (RX character available) before reading.
; In:  nothing
; Out: A = IOC_XPORT_OK (0), C = received byte
;   or A = IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, C, DE
; ISR-safe: No.  Blocking poll.
;
; DEBUG BRING-UP: same very long 24-bit countdown as sio_command_put_byte
; (inner DE = SIO_COMMAND_TIMEOUT, outer B = SIO_COMMAND_TIMEOUT_OUTER) so the
; PIC side can be single-stepped, then returns IOC_XPORT_TIMEOUT rather than
; hanging.  B is saved/restored.  For production, set OUTER = 1.
; TODO: During bring-up, inspect RR1 overrun/parity/status if byte receive
;       errors appear.  No SIO hardware CRC/FCS is used in External Sync mode.
; ---------------------------------------------------------------------------
sio_command_get_byte:
	push bc				; preserve caller B (frame counter)
	ld b,#SIO_COMMAND_TIMEOUT_OUTER
SIO_CMD_GET_OUTER:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_GET_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,SIO_CMD_GET_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_GET_WAIT
	djnz SIO_CMD_GET_OUTER
	pop bc				; restore caller B/C
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_GET_READY:
	in a,(SIO_COMMAND_DATA_PORT)	; read byte into A before restoring BC
	pop bc				; restore caller B; C recovered then overwritten
	ld c,a				; return received byte in C
	xor a
	ret

; ---------------------------------------------------------------------------
; ioc_command_send_frame
; Send exactly IOC_FRAME_SIZE (32) bytes via SIO1/B (Command channel) in
; External Sync mode (transparent bytes; optional software preamble only).
;
; Z80 SIO synchronous-transmit requirement: after the first data byte is loaded
; the Tx Underrun/EOM latch must be reset (WR0 = 0xC0) so the transmitter leaves
; its idle/mark state and shifts the buffered data.  Without this the first byte
; is never consumed, TBE never re-asserts, and the send times out.
; In:  HL = pointer to 32-byte TX frame in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
; Clobbers: AF, B, C, DE, HL
; ---------------------------------------------------------------------------
ioc_command_send_frame:
	; Optional sync preamble first (byte-alignment marker for the MCU), then reset the
	; Tx Underrun/EOM latch so the transmitter shifts the buffered bytes.
	ld c,#IOC_SYNC_PREAMBLE
	call sio_command_put_byte
	or a
	ret nz				; return error code on timeout
	ld a,#0xc0			; WR0: Reset Tx Underrun/EOM latch
	out (SIO_COMMAND_CTRL_PORT),a

	; 32 transparent frame bytes.
	ld b,#IOC_FRAME_SIZE
IOC_CMD_SEND_LOOP:
	ld c,(hl)
	call sio_command_put_byte
	or a
	ret nz				; return error code on timeout
	inc hl
	djnz IOC_CMD_SEND_LOOP
	xor a
	ret

; ---------------------------------------------------------------------------
; ioc_command_recv_frame
; Receive exactly IOC_FRAME_SIZE (32) bytes from SIO1/B (Command channel).
; BIOS hunts the optional software preamble when present, or accepts a direct
; PING reply class byte at the start of the receive window during bring-up.
; In:  DE = pointer to 32-byte RX frame buffer in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
;      32-byte frame written to buffer at DE on success.
; Clobbers: AF, B, C, HL
; ---------------------------------------------------------------------------
ioc_command_recv_frame:
	; RX was disabled during request TX, so the request-capture clock window
	; cannot fill the SIO RX FIFO with full-duplex junk.  Clear any stale error
	; latch, then enable RX in hunt mode before the PIC's guarded reply sync
	; sequence starts.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#0x03
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR3_CMD_RX
	out (SIO_COMMAND_CTRL_PORT),a

	push de
	pop hl				; HL = RX buffer pointer

	; Skip received bytes until the sync preamble is seen (byte boundary is
	; provided by the SIO RX via /SYNC; we just locate the frame start).
	; Bounded so a missing preamble fails rather than spinning.
	ld b,#SIO_COMMAND_REPLY_SCAN_LIMIT
IOC_CMD_RECV_SYNC:
	call sio_command_get_byte	; clobbers AF,C; preserves B,DE,HL
	or a
	jr nz,IOC_CMD_RECV_SYNC_TIMEOUT
	ld a,c
	cp #IOC_SYNC_PREAMBLE
	jr z,IOC_CMD_RECV_BODY
	cp #IOC_RSP_PING
	jr z,IOC_CMD_RECV_BODY_FIRST
	djnz IOC_CMD_RECV_SYNC
	ld a,#IOC_XPORT_BAD_FRAME	; preamble not found in window
	ret

IOC_CMD_RECV_BODY_FIRST:
	ld (hl),c			; no preamble visible; first byte is reply class
	inc hl
	ld b,#(IOC_FRAME_SIZE - 1)
	jr IOC_CMD_RECV_LOOP

IOC_CMD_RECV_BODY:
	ld b,#IOC_FRAME_SIZE
IOC_CMD_RECV_LOOP:
	call sio_command_get_byte
	or a
	jr nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld (hl),c
	inc hl
	djnz IOC_CMD_RECV_LOOP
	xor a
	ret

IOC_CMD_RECV_SYNC_TIMEOUT:
	ld a,#IOC_XPORT_TIMEOUT_REPLY_MARKER
	ret

IOC_CMD_RECV_BODY_TIMEOUT:
	ld a,#IOC_XPORT_TIMEOUT_REPLY_BODY
	ret

IOC_CMD_CODE_END:

	.area CODE (ABS)
