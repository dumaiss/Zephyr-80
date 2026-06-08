; Zephyr-80 BIOS IOC Command-channel byte helpers — Phase 1.
;
; These routines provide polled byte I/O and fixed-frame send/receive for
; the IO Controller Command channel (SIO1/B).
;
; Command channel = SIO1/B
;   DATA port = SIO_COMMAND_DATA_PORT = 32h
;   CTRL port = SIO_COMMAND_CTRL_PORT = 33h
;
; Bulk channel = SIO1/A (inactive in Phase 1; port aliases defined for reference)
;
; Hardware model:
;   The MCU is the synchronous clock master.  TXC/RXC for SIO1/B are supplied
;   by the MCU.  The MCU clocks only during active transactions.  Clocking alone
;   does not trigger a useful Z80 SIO interrupt; the MCU must deliver a complete
;   valid SDLC frame.  No WAIT/READY; no INIR/OTIR; polled byte I/O only.
;   No SIO1/B interrupts in Phase 1.
;
; SIO1/B SDLC transparency:
;   The Z80 SIO in SDLC mode handles framing automatically.
;   On transmit:  BIOS writes data bytes; SIO appends opening flag, zero-bit
;                 insertion, FCS, and closing flag.
;   On receive:   SIO strips flags, removes zero-bit stuffing, validates FCS,
;                 then presents clean data bytes one at a time via the RX buffer.
;   BIOS sees only the 32 IOC payload bytes in both directions.
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
; Release RTS on SIO1/B (Command channel) after transaction completes.
; In:  nothing
; Out: A = 0
; Clobbers: AF
; ---------------------------------------------------------------------------
sio_command_rts_release:
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_OFF
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_put_byte
; Send one byte on SIO1/B (Command channel) with polling and timeout.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 2 (TX buffer empty) before writing.
; In:  C = byte to send
; Out: A = IOC_XPORT_OK (0) on success, IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, DE
; ISR-safe: No.  Blocking poll.
; ---------------------------------------------------------------------------
sio_command_put_byte:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_PUT_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_TX_READY
	jr nz,SIO_CMD_PUT_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_PUT_WAIT
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_PUT_READY:
	ld a,c
	out (SIO_COMMAND_DATA_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_get_byte
; Receive one byte from SIO1/B (Command channel) with polling and timeout.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 0 (RX character available) before reading.
; In:  nothing
; Out: A = IOC_XPORT_OK (0), C = received byte
;   or A = IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, C, DE
; ISR-safe: No.  Blocking poll.
; TODO: Check RR1 end-of-frame and CRC status after frame receive for
;       hardware validation of SDLC framing.
; ---------------------------------------------------------------------------
sio_command_get_byte:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_GET_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,SIO_CMD_GET_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_GET_WAIT
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_GET_READY:
	in a,(SIO_COMMAND_DATA_PORT)
	ld c,a
	xor a
	ret

; ---------------------------------------------------------------------------
; ioc_command_send_frame
; Send exactly IOC_FRAME_SIZE (32) bytes via SIO1/B (Command channel) in
; External Sync mode (transparent bytes; software framing/CRC live elsewhere).
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
	; Sync preamble first (byte-alignment marker for the MCU), then reset the
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
; The Z80 SIO in SDLC mode handles framing transparently: it detects the
; opening flag, removes zero-bit stuffing, validates FCS, then presents
; clean data bytes.  BIOS receives only the 32 IOC payload bytes.
; In:  DE = pointer to 32-byte RX frame buffer in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
;      32-byte frame written to buffer at DE on success.
; Clobbers: AF, B, C, HL
; ---------------------------------------------------------------------------
ioc_command_recv_frame:
	push de
	pop hl				; HL = RX buffer pointer

	; Skip received bytes until the sync preamble is seen (byte boundary is
	; provided by the SIO RX via /SYNC; we just locate the frame start).
	; Bounded so a missing preamble fails rather than spinning.
	ld b,#0x40			; scan up to 64 bytes for the preamble
IOC_CMD_RECV_SYNC:
	call sio_command_get_byte	; clobbers AF,C,DE; preserves B,HL
	or a
	ret nz				; timeout
	ld a,c
	cp #IOC_SYNC_PREAMBLE
	jr z,IOC_CMD_RECV_BODY
	djnz IOC_CMD_RECV_SYNC
	ld a,#IOC_XPORT_BAD_FRAME	; preamble not found in window
	ret

IOC_CMD_RECV_BODY:
	ld b,#IOC_FRAME_SIZE
IOC_CMD_RECV_LOOP:
	call sio_command_get_byte
	or a
	ret nz				; return error code on timeout
	ld (hl),c
	inc hl
	djnz IOC_CMD_RECV_LOOP
	xor a
	ret

IOC_CMD_CODE_END:

	.area CODE (ABS)
