; Serial console fallback for the Zephyr-80 CP/M BIOS.
;
; A second console that lives alongside the selected backend rather than
; replacing it, so that a dark V9958 does not leave the machine unreachable.
; SIO0/B is the port: sio_core_init() already configures it as async 8N1 with
; RX and TX enabled in every build, so nothing here touches SIO setup.
;
; ---------------------------------------------------------------------------
; How it behaves
; ---------------------------------------------------------------------------
;
; OUTPUT is teed.  Every CONOUT goes to the selected backend first and then, if
; the tee is enabled, to the serial port.  The screen never becomes secondary.
;
; INPUT is switched, not merged.  Serial bytes are watched for three ESCs; the
; third toggles input between the USB/HID keyboard and the serial port, and
; arms the tee.  The same gesture hands control back, so taking over does not
; strand the keyboard until a reboot.
;
; Switching rather than merging is deliberate.  A merge would need CONIN to
; poll two blocking sources, and it would let a connected-but-idle terminal --
; or noise on a cable someone just plugged in -- type into a running program.
; Takeover is a gesture the operator makes on purpose.
;
; ---------------------------------------------------------------------------
; Why the tee defaults OFF
; ---------------------------------------------------------------------------
;
; sio_send_byte's console path waits for SIO_CONSOLE_TX_READY, which is
; TX-buffer-empty AND /CTS.  With no terminal attached /CTS never asserts, so
; every character would burn the full SIO_CONSOLE_TIMEOUT of FFFFh loop
; iterations -- on the order of a second each.  The boot banner alone would
; take about a minute.
;
; Two things prevent that.  The tee is off until something arms it, and
; sercon_tx checks /CTS itself before calling the helper: an absent terminal
; costs three instructions per character instead of a timeout.  The CTS test is
; not a guess about the wiring -- sio_core.asm already folds /CTS into its own
; ready mask, so this port's design already treats it as meaningful.
;
; ---------------------------------------------------------------------------
; Input pacing
; ---------------------------------------------------------------------------
;
; IOCBULK masks interrupts for a whole transfer -- roughly 3 ms for a 512-byte
; record -- during which this sink cannot run and the SIO's 3-byte FIFO is the
; only buffer.  At 115200 that is about 35 character times.  Typing survives
; that easily; pasting does not, and the mitigation is to pace the terminal
; rather than to add RTS watermark logic here.  That is why the ring is eight
; bytes and there is no flow control: it covers ISR latency, not a burst.
; ---------------------------------------------------------------------------

	.globl sercon_init,sercon_install,sercon_console_driver
	.globl SERCON_CODE_START,SERCON_CODE_END
	.globl console_backend_driver,console_set_driver
	.globl sio_register_rx_sink,sio_send_byte

	.area CODE (ABS)
	.org CBIOS_SERCON_CODE_BASE

SERCON_CODE_START:

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
	di
	ld hl,#SERCON_RX_HEAD
	ld e,(hl)
	ld a,e
	inc a
	and #(SERCON_RX_BUFFER_SIZE - 1)
	ld (hl),a
	ld a,(SERCON_RX_COUNT)
	dec a
	ld (SERCON_RX_COUNT),a
	ld d,#0x00
	ld hl,#sercon_rx_buffer
	add hl,de
	ld a,(hl)
	ei
	ret

; SIO0/B RX sink, called from the interrupt frame.
;
; In: A = channel id, C = received byte.  May clobber AF/BC/DE/HL but not
; IX/IY, per the sio_core sink contract.  Returns quickly; no BDOS, no blocking,
; no rendering.
sercon_rx_sink:
	ld a,c
	cp #SERCON_ESC
	jr z,sercon_rx_esc

	; Any other byte breaks a partial match.
	xor a
	ld (SERCON_ESC_COUNT),a
	jr sercon_rx_store

sercon_rx_esc:
	ld hl,#SERCON_ESC_COUNT
	inc (hl)
	ld a,(hl)
	cp #SERCON_ESC_TRIGGER
	jr c,sercon_rx_store

	; Third ESC: toggle input ownership and arm the tee.  Arming on takeover
	; means the rescue gesture works from a dark screen in one step.
	ld (hl),#0x00
	ld a,(SERCON_FLAGS)
	xor #SERCON_FLAG_INPUT
	or #SERCON_FLAG_TEE
	ld (SERCON_FLAGS),a

	; Drop the two ESCs already queued: the sequence is a command, not input.
	xor a
	ld (SERCON_RX_HEAD),a
	ld (SERCON_RX_TAIL),a
	ld (SERCON_RX_COUNT),a
	ret

sercon_rx_store:
	; Only keep bytes when serial owns input; otherwise a terminal sitting at
	; a prompt would type into whatever the machine is running.
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	ret z

	ld a,(SERCON_RX_COUNT)
	cp #SERCON_RX_BUFFER_SIZE
	ret nc				; full: drop, the terminal is meant to pace
	inc a
	ld (SERCON_RX_COUNT),a

	ld hl,#SERCON_RX_TAIL
	ld e,(hl)
	ld a,e
	inc a
	and #(SERCON_RX_BUFFER_SIZE - 1)
	ld (hl),a
	ld d,#0x00
	ld hl,#sercon_rx_buffer
	add hl,de
	ld (hl),c
	ret

sercon_rx_buffer:
	.ds SERCON_RX_BUFFER_SIZE

SERCON_CODE_END:
