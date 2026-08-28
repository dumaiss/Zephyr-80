; Zephyr-80 BIOS IOC two-lane transport.
;
; IOCALL compatibility-mailbox contract:
;   In:
;     HL = pointer to caller-owned 32-byte TX frame in visible application RAM.
;     DE = pointer to caller-owned 32-byte RX frame buffer in visible application RAM.
;   Out:
;     A = IOC_XPORT_OK (00h) on success.
;         IOC_XPORT_TIMEOUT, IOC_XPORT_BAD_FRAME, or IOC_XPORT_HW_ERROR otherwise.
;   On success:
;     32-byte MCU reply frame has been written to caller RX buffer at DE.
;   On error:
;     RX buffer contents are undefined.
;
; IOCALL maps one 32-byte caller mailbox to the common variable-length packet,
; validates the reply packet, and maps it back.  It does not decode PING, RESET,
; or any other command; callers interpret the compatibility mailbox themselves.
;
; Channel:
;   Command channel = SIO1/B, DATA port 32h, CTRL port 33h (bring-up retarget;
;   SIO1/A channel-A outputs failed hardware probing).
;   The MCU is the synchronous clock master.  Z80 SIO1/B is externally clocked.
;   Framing is A5 5A LEN TYPE SEQ STATUS DATA CRC in persistent External Sync;
;   the MCU drives /SYNCB and clocks the exchange.
;   No WAIT/READY; no INIR/OTIR; foreground polled byte I/O only.
;   No SIO1/B interrupts in Phase 1.
;
; sio_command_init initialises SIO1/B once.  Repeating it would reset the SIO
; character boundary and defeat persistent sync.
;
; RESET note:
;   RESET is a terminal/disruptive command.  If the MCU executes RESET, the
;   machine may restart before ioc_command_recv_frame returns.  A timeout or
;   non-return from IOCALL is the expected result for RESET callers.

	.globl IOCALL
	.globl IOCTRL_CODE_START,IOCTRL_CODE_END
	.globl sio_command_init,ioc_link_init_once
	.globl sio_command_rts_assert,sio_command_rts_release
	.globl ioc_command_send_frame,ioc_command_recv_frame
	.globl ioc_bulk_tx_type,ioc_bulk_tx_seq,ioc_bulk_rx_type,ioc_bulk_rx_seq

	.area CODE (ABS)

	; One byte of transport level, immediately below IOCALL.  See
	; ZBIOS_XPORT_LEVEL: a host can read it straight out of ROM and refuse to
	; interpret a wire capture produced by a BIOS it was not built against.
	.org ZBIOS_XPORT_LEVEL_ADDR
	.db ZBIOS_XPORT_LEVEL

	.org CBIOS_IOCTRL_CODE_BASE

IOCTRL_CODE_START:

; ---------------------------------------------------------------------------
; IOCALL — compatibility-mailbox Command-channel entry point
; ---------------------------------------------------------------------------
; RTS here means "I have an unacknowledged request for you", NOT "a transaction
; is in progress".  It is released as soon as the request frame is delivered,
; which is well before the reply arrives.
;
; That distinction is the whole handshake.  The MCU cannot reliably catch a
; falling edge -- it samples the line only in its main loop and is blind for the
; length of a bulk transfer or a card write -- so nothing important may live in
; an edge.  Under these semantics the MCU never leaves a service without having
; positively observed this release, so any low level it finds while idle is
; unambiguously a NEW request, whether or not it saw the transition.
;
; It also decouples the release from the reply.  If the MCU fails to decode a
; request it sends nothing, and the host waits out its receive timeout -- but
; RTS is already high by then, so the MCU cannot mistake that wait for another
; request and clock junk windows into a host that is trying to listen.
IOCALL:
	; ONCE, not per call.  sio_command_init issues a channel reset, and the SIO
	; manual lists chip reset as one of the three things that destroy character
	; synchronisation -- so running it here defeated persistent External Sync
	; before anything else could.  The helper does nothing after the first call.
	call ioc_link_init_once

	push de				; save caller RX frame pointer across send

	; Backpressure: the MCU advertises COMMAND_READY on /DCDB only while it is
	; in command-idle.  Asserting RTS before that would hand it a request it
	; cannot yet see -- and would make a dead controller indistinguishable
	; from a busy one, since both would present as a byte timeout seconds
	; later.  HL (the caller's TX frame pointer) is untouched by this.
	call sio_command_wait_ready
	or a
	jr nz,IOCALL_FAIL_STACKED

	; Stamp the outgoing sequence.  The send helper maps this compatibility
	; mailbox to the common variable-length wire packet and supplies its CRC.
	call ioc_frame_stamp		; HL preserved; A = sequence stamped
	ld (ioc_expect_seq),a
	ld (ioc_bulk_tx_seq),a
	ld a,(hl)
	ld (ioc_bulk_tx_type),a

	; RTS is asserted INSIDE ioc_command_send_frame, after the preamble has been
	; loaded into the transmitter.  Asserting it here started the MCU clocking
	; against an empty transmitter; see the note at IOC_CMD_SEND_EOM.
	;
	; HL = caller TX frame pointer
	call ioc_command_send_frame
	or a
	jr nz,IOCALL_FAIL_STACKED

	pop de				; restore caller RX frame pointer

	; Request delivered — acknowledge it.  ioc_command_send_frame has clocked
	; trailing filler, so the last frame byte is off the shift register and
	; disabling the transmitter here cannot truncate it.
	call sio_command_rts_release

	; recv_frame does NOT preserve DE.  Its header comment claims
	; "Clobbers: AF, B, C, HL", but it calls sio_command_get_byte in a loop
	; and that uses DE as its timeout counter -- so the RX pointer is gone by
	; the time it returns.  Keep it on the stack instead of trusting DE.
	push de
	call ioc_command_recv_frame
	pop hl				; HL = caller RX frame
	or a
	ret nz				; transport error: nothing to validate

	; recv_frame has already verified the exact wire CRC, so the sequence byte
	; can be trusted.  A reply echoing a
	; different sequence belongs to an earlier transaction -- accepting it
	; would answer this request with a stale one.
	inc hl				; IOC_OFF_SEQ
	ld a,(ioc_expect_seq)
	cp (hl)
	jr nz,IOCALL_SEQ_FAIL

	; The following IOCBULK is the data phase of this command transaction.
	; Preserve the verified response metadata so the bulk packet can be matched
	; to the READY response that authorized it.
	ld a,(hl)
	ld (ioc_bulk_rx_seq),a
	dec hl
	ld a,(hl)
	ld (ioc_bulk_rx_type),a

	xor a
	ret

IOCALL_SEQ_FAIL:
	ld a,#IOC_XPORT_BAD_SEQ
	ret

; Sequence expected in the reply to the outstanding request.
ioc_expect_seq:
	.db 0

IOCALL_FAIL_STACKED:
	pop de				; balance stack
	ld b,a
	call sio_command_rts_release
	ld a,b
	ret


; ---------------------------------------------------------------------------
; sio_command_init — initialise SIO1/B for Command-channel External Sync
; ---------------------------------------------------------------------------
; Purpose:
;   Configure SIO1/B for External Sync mode with external clock.  Idempotent.
;   Called once by ioc_link_init_once; later IOCALLs leave the receiver and its
;   External Sync character boundary intact.
;
; Command channel = SIO1/B, CTRL port 33h.
; MCU is the synchronous clock master; Z80 SIO1/B is externally clocked x1.
; No interrupts, no WAIT/READY; polled byte I/O only in Phase 1.
;
; Register sequence:
;   WR0 0x18  channel reset
;   WR1 0x00  no interrupts, no WAIT/DMA
;   WR4 0x30  External Sync mode, x1 clock, no parity
;   WR7 0xFF  TX underrun fill (sync is via /SYNC pin)
;   WR3 0xC0  8-bit RX format, receiver disabled before first establishment
;   WR5 0x68  8-bit TX, TX enable, TX CRC disabled, RTS inactive
;   WR9 via SIO1B_CTRL: SIO1 master interrupt disabled (chip-wide, already 0)
;
; SIO1 master interrupt (WR9 via SIO1B_CTRL port 33h) is already disabled by
; sio1_ioc_init which runs during sio_core_init.  Not rewritten here.
;
; Out: A = 0.
; Clobbers: AF.
sio_command_init:
	; WR0: channel reset.
	ld a,#0x18
	out (SIO_COMMAND_CTRL_PORT),a

	; WR1: no interrupts, no WAIT/DMA.
	ld a,#0x01
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	out (SIO_COMMAND_CTRL_PORT),a

	; WR4: External Sync mode (bits 5:4 = 11), x1 external clock (bits 7:6 = 00).
	; /SYNCB is an INPUT in this mode, driven by the MCU (no contention).
	ld a,#0x04
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR4_CMD_EXTSYNC
	out (SIO_COMMAND_CTRL_PORT),a

	; WR7: marking underrun fill; packet framing uses A5 5A in software.
	ld a,#0x07
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_EXTSYNC_FILL
	out (SIO_COMMAND_CTRL_PORT),a

	; WR3: 8-bit RX format, initially disabled.  This is before a character
	; boundary exists.  Once the first reply establishes sync, the receiver is
	; enabled and is never disabled again except during explicit link recovery.
	ld a,#0x03
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR3_CMD_RX_OFF
	out (SIO_COMMAND_CTRL_PORT),a

	; WR5: 8-bit TX, TX enable, TX CRC disabled, RTS inactive.
	; RTS is managed separately by sio_command_rts_assert/release.
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_OFF
	out (SIO_COMMAND_CTRL_PORT),a

	xor a
	ret

IOCTRL_CODE_END:

	.area CODE (ABS)
