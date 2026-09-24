; serial console tee: the bank-7 half.
; The common half -- what an interrupt reaches -- is in common/sercon.asm.
; Split so that every source file belongs to exactly one memory class, which is
; what lets the build check a file's directory against the addresses it emits.


; ---------------------------------------------------------------------------
; Bank 7: the polled serial console tee
; ---------------------------------------------------------------------------
; The driver table, init/install, the CONST/CONIN/CONOUT tee, and TX with CTS
; handling.  Reached only through the console facade (bank 7) and from boot
; after bank7_check, so none of it needs a common address.
;
; It reads sercon_rx_buffer and SERCON_RX_HEAD/_COUNT, which stay in common
; because the sink writes them: bank 7 reads common freely in mode 11.

	.area CODE (ABS)
	.org CBIOS_SERCON_BANK7_CODE_BASE

SERCON_BANK7_CODE_START:

; The composite driver table the console facade dispatches through.
;
; const/conin/conout are ours; the remaining four are copied verbatim from the
; selected backend at init, so list/punch/reader/listst cost no indirection and
; no code here.
sercon_console_driver:
	.dw sercon_const
	.dw sercon_conin
	.dw sercon_conout
sercon_driver_tail:
	.ds 8				; list, punch, reader, listst

; The backend entries we displaced, saved so the wrappers can still reach them.
sercon_backend_const:
	.dw 0x0000
sercon_backend_conin:
	.dw 0x0000
sercon_backend_conout:
	.dw 0x0000

; Install the tee.
;
; Called once from cold boot, after the backend has initialised and therefore
; after console_init has installed the backend's own table.
; Clobbers: AF, BC, DE, HL.
sercon_init:
	; Clear state.  The tee starts OFF: see the header.
	xor a
	ld (SERCON_FLAGS),a
	ld (SERCON_ESC_COUNT),a
	ld (SERCON_RX_HEAD),a
	ld (SERCON_RX_TAIL),a
	ld (SERCON_RX_COUNT),a
	; fall through

; Bind to the selected backend and the SIO, WITHOUT touching armed state.
;
; Warm boot has to call this, not sercon_init.  CP/M warm-boots after every
; transient program, and two things there undo the installation:
;   console_init()  resets CONSOLE_DRIVER to the backend's own table, which
;                   drops the composite table and with it the tee;
;   sio_core_init() clears SIO0B_RX_SINK, which unregisters the sink.
; Rebinding without clearing the flags is what lets a terminal stay in control
; across a command.  Clearing them here would disarm the tee the first time you
; ran anything, which is exactly when you would be relying on it.
; Clobbers: AF, BC, DE, HL.
sercon_install:
	; Take the backend's list/punch/reader/listst verbatim.
	ld hl,#(console_backend_driver + 6)
	ld de,#sercon_driver_tail
	ld bc,#8
	ldir

	; Keep its const/conin/conout so the wrappers can forward to them.
	ld hl,#console_backend_driver
	ld de,#sercon_backend_const
	ld bc,#6
	ldir

	; Watch SIO0/B receive bytes.  The ISR already reads and discards them in
	; a build with no console sink registered; this puts them to use.
	ld hl,#sercon_rx_sink
	ld a,#SIO_CH_CONSOLE
	call sio_register_rx_sink

	ld hl,#sercon_console_driver
	jp console_set_driver

; Tail-call the backend entry whose vector is at HL.
; In: HL = address of a saved vector.  Falls into the backend, which returns to
; our caller.
sercon_call_backend:
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	jp (hl)

; CONOUT: backend first, then the serial tee.
; In: C = character.
sercon_conout:
	push bc
	ld hl,#sercon_backend_conout
	call sercon_call_backend
	pop bc
	; fall through

; Send C to the serial port if the tee is armed and a terminal is present.
; Clobbers: AF, HL, DE (via sio_send_byte).
sercon_tx:
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_TEE
	ret z

	; /CTS is the "is anything listening" test.  Without it an absent terminal
	; costs a full SIO_CONSOLE_TIMEOUT per character.
	; Wait briefly for /CTS.  A terminal that closes and reopens the port takes
	; RTS with it for a few milliseconds, and dropping output across a flap
	; that short makes a working link look broken -- holes in the output while
	; input, which does not depend on /CTS, keeps working perfectly.
	ld de,#SERCON_CTS_WAIT
sercon_tx_cts:
	xor a
	out (SIO0B_CTRL_PORT),a		; point at RR0
	in a,(SIO0B_CTRL_PORT)
	and #SIO_RR0_CTS
	jr nz,sercon_tx_send
	dec de
	ld a,d
	or e
	jr nz,sercon_tx_cts

	ret				; nothing listening: drop the byte

sercon_tx_send:

	ld a,#SIO_CH_CONSOLE
	jp sio_send_byte		; bounded; drops the byte on timeout

; CONST: whichever source currently owns input.
; Out: A = FFh if a character is waiting, 00h otherwise.
;
; The backend's CONST is called on EVERY path, including when serial owns input
; and its answer is discarded.  It is not just a query: for the V9958 backend it
; is where the pending print run is flushed to the screen -- CONOUT only
; buffers.  Skipping it froze the V9958 while serial had input, so typing was
; invisible there until enough output accumulated to overflow the run buffer and
; flush itself.  Answering from the right source is this routine's job; deciding
; the backend does not need to run is not.
sercon_const:
	ld hl,#sercon_backend_const
	call sercon_call_backend
	ld c,a				; the backend's answer, kept

	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	jr nz,sercon_const_serial
	ld a,c
	ret
sercon_const_serial:
	ld a,(SERCON_RX_COUNT)
	or a
	ret z
	ld a,#0xff
	ret

; CONIN: blocking read from whichever source owns input.
; Out: A = character.
;
; This must never call the backend's blocking CONIN directly.
;
; That was the first version, and it meant the ESC gesture could not take over
; while CP/M sat at a prompt: the backend was already blocked inside its own
; wait on the HID queue, so the toggle did not take effect until someone
; pressed a key on the USB keyboard.  Poll the backend's non-blocking CONST
; instead, re-checking the flag each pass, and only enter the backend's CONIN
; once it has said a character is ready.
sercon_conin:
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	jr nz,sercon_conin_serial

	ld hl,#sercon_backend_const
	call sercon_call_backend
	or a
	jr z,sercon_conin		; nothing yet: re-check the flag and poll
	ld hl,#sercon_backend_conin
	jp sercon_call_backend

sercon_conin_serial:
	; Re-read the flag every pass.  The sink can toggle input back to the
	; keyboard while we are blocked here, and without this that gesture would
	; be ignored until something else happened to call CONIN.
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	jr z,sercon_conin
	ld a,(SERCON_RX_COUNT)
	or a
	jr nz,sercon_conin_dequeue

	; Nothing queued.  Give the backend a CONST anyway before looping: that is
	; what flushes its print run, and without it the screen stays frozen for as
	; long as we sit here waiting for a serial byte -- which is most of the
	; time, since this is where the machine idles at a prompt.
	ld hl,#sercon_backend_const
	call sercon_call_backend
	jr sercon_conin_serial

sercon_conin_dequeue:
	; Dequeue.  Masked: the sink runs from the SIO ISR and touches the same
	; three bytes.
	call irq_save_disable
	push af
	ld hl,#SERCON_RX_HEAD
	ld e,(hl)
	ld a,e
	inc a
	and #(SERCON_RX_BUFFER_SIZE - 1)
	ld (hl),a
	ld hl,#SERCON_RX_COUNT
	dec (hl)
	ld d,#0x00
	ld hl,#sercon_rx_buffer
	add hl,de
	ld e,(hl)
	pop af
	call irq_restore
	ld a,e
	ret

SERCON_BANK7_CODE_END:

	.ifgt (SERCON_BANK7_CODE_END - SERCON_BANK7_CODE_START) - (CBIOS_SERCON_BANK7_CODE_LIMIT - CBIOS_SERCON_BANK7_CODE_BASE)
	.error 1			; serial console tee overflows its bank-7 region
	.endif
