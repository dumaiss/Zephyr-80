; Zephyr-80 BIOS IOC Command-channel transport — Phase 1.
;
; IOCALL fixed-frame contract:
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
; IOCALL is a dumb transport: send one 32-byte TX frame, receive one 32-byte RX
; frame, return transport status.  IOCALL does not decode PING, RESET, or any
; other command.  Callers decode the 32-byte frame themselves.
;
; Channel:
;   Command channel = SIO1/B, DATA port 32h, CTRL port 33h.
;   The MCU is the synchronous clock master.  Z80 SIO1/B is externally clocked.
;   Clocking alone is not sufficient; the MCU must deliver a valid SDLC frame.
;   No WAIT/READY; no INIR/OTIR; foreground polled byte I/O only.
;   No SIO1/B interrupts in Phase 1.
;
; sio_command_init:
;   Initialises SIO1/B for SDLC.  Defined here in the IOCTRL code area because
;   sio_core.asm and cbios_boot.asm have no room for additional code in Phase 1.
;   Phase 1 workaround: IOCALL calls sio_command_init at the start of each
;   transaction to ensure clean SIO state.  In a future phase, when space is
;   reclaimed, move the call into the BIOS startup sequence so it runs once.
;
; RESET note:
;   RESET is a terminal/disruptive command.  If the MCU executes RESET, the
;   machine may restart before ioc_command_recv_frame returns.  A timeout or
;   non-return from IOCALL is the expected result for RESET callers.

	.globl IOCALL
	.globl IOCTRL_CODE_START,IOCTRL_CODE_END
	.globl sio_command_init
	.globl sio_command_rts_assert,sio_command_rts_release
	.globl ioc_command_send_frame,ioc_command_recv_frame

	.area CODE (ABS)
	.org CBIOS_IOCTRL_CODE_BASE

IOCTRL_CODE_START:

; ---------------------------------------------------------------------------
; IOCALL — fixed-frame Command-channel transport entry point
; ---------------------------------------------------------------------------
IOCALL:
	call sio_command_init		; (re)init SIO1/B SDLC — Phase 1 workaround

	push de				; save caller RX frame pointer across send

	call sio_command_rts_assert	; assert SIO1/B RTS → MCU starts clocking

	; HL = caller TX frame pointer (preserved by rts_assert which clobbers AF only)
	call ioc_command_send_frame
	or a
	jr nz,IOCALL_FAIL_STACKED

	pop de				; restore caller RX frame pointer
	call ioc_command_recv_frame
	or a
	jr nz,IOCALL_FAIL_RTS

	call sio_command_rts_release
	xor a
	ret

IOCALL_FAIL_STACKED:
	pop de				; balance stack
IOCALL_FAIL_RTS:
	ld b,a
	call sio_command_rts_release
	ld a,b
	ret


; ---------------------------------------------------------------------------
; sio_command_init — initialise SIO1/B for Command-channel SDLC
; ---------------------------------------------------------------------------
; Purpose:
;   Configure SIO1/B for SDLC mode with external clock.  Idempotent.
;   Called at the start of each IOCALL in Phase 1 (see header note).
;
; Command channel = SIO1/B, CTRL port 33h.
; MCU is the synchronous clock master; Z80 SIO1/B is externally clocked x1.
; No interrupts, no WAIT/READY; polled byte I/O only in Phase 1.
;
; Register sequence:
;   WR0 0x18  channel reset
;   WR1 0x00  no interrupts, no WAIT/DMA
;   WR4 0x30  External Sync mode, x1 clock, no parity
;   WR7 0x7E  receive sync char / TX underrun fill (sync is via /SYNC pin)
;   WR3 0xD1  8-bit RX, enter hunt, RX enable, RX CRC disabled
;   WR5 0x68  8-bit TX, TX enable, TX CRC disabled, RTS inactive
;   WR9 via SIO1A_CTRL: SIO1 master interrupt disabled (chip-wide, already 0)
;
; SIO1 master interrupt (WR9 via SIO1A_CTRL port 31h) is already disabled by
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

	; WR7: SDLC flag byte = 7Eh.
	ld a,#0x07
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_SDLC_FLAG
	out (SIO_COMMAND_CTRL_PORT),a

	; WR3: 8-bit RX, enter hunt mode (search for opening flag), RX CRC enable,
	; RX enabled.
	ld a,#0x03
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR3_CMD_RX
	out (SIO_COMMAND_CTRL_PORT),a

	; WR5: 8-bit TX, TX enable, CRC-CCITT polynomial, TX CRC enable, RTS inactive.
	; RTS is managed separately by sio_command_rts_assert/release.
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_OFF
	out (SIO_COMMAND_CTRL_PORT),a

	xor a
	ret

IOCTRL_CODE_END:

	.area CODE (ABS)
