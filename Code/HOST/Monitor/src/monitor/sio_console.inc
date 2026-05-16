; SIO channel B console initialization and polling I/O routines.
;
; This module owns the monitor console. It talks directly to SIO channel B and
; uses polling only: transmit waits for RR0 Tx Buffer Empty, receive waits for
; RR0 Rx Character Available. Interrupts remain disabled for the whole monitor.

; Initialize SIO channel B for 115200 8N1 using x16 async clocking.
; Input: none.
; Output: SIO channel B configured for polled 115200 8N1 console I/O.
; Clobbers: AF.
sio_init:
	; WR0: channel reset
	ld a,#0x18
	out (SIOB_CTRL),a

	; WR4: x16 clock, 1 stop bit, no parity
	ld a,#0x04
	out (SIOB_CTRL),a
	ld a,#0x44
	out (SIOB_CTRL),a

	; WR3: RX enable, 8-bit RX, auto-enables disabled. FT230-style USB serial
	; adapters may not drive modem-control inputs in the way SIO auto-enables
	; expect, so receive gating is kept under software control.
	ld a,#0x03
	out (SIOB_CTRL),a
	ld a,#0xc1
	out (SIOB_CTRL),a

	; WR5: DTR, TX 8-bit, TX enable, RTS
	ld a,#0x05
	out (SIOB_CTRL),a
	ld a,#0xea
	out (SIOB_CTRL),a

	; WR1: interrupts disabled
	ld a,#0x01
	out (SIOB_CTRL),a
	xor a
	out (SIOB_CTRL),a
	ret

; Write A to SIO channel B after RR0 Tx Buffer Empty is set.
; Input: A = byte to transmit.
; Output: byte written to SIOB_DATA.
; Preserves: BC, DE, HL, IX, IY. Clobbers: AF.
sio_putc:
	push af
sio_putc_wait:
	; RR0 is read from the control port. The loop exits only when the SIO can
	; accept another transmit byte.
	in a,(SIOB_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,sio_putc_wait
	pop af
	out (SIOB_DATA),a
	ret

; Read one byte from SIO channel B after RR0 Rx Character Available is set.
; Input: none.
; Output: A = received byte.
; Clobbers: AF.
sio_getc:
sio_getc_wait:
	; Poll RR0 until receive data is present, then fetch exactly one byte from
	; the channel B data port.
	in a,(SIOB_CTRL)
	and #SIO_RR0_RX_AVAIL
	jr z,sio_getc_wait
	in a,(SIOB_DATA)
	ret

; Wait silently until the operator presses Enter once.
; If Enter arrives as CRLF, remember the CR so sio_getline ignores the pending LF.
; Input: none.
; Output: EOL_CR_FLAG set when CR was the terminating byte, clear for LF.
; Clobbers: AF.
wait_for_first_enter:
	call sio_getc
	cp #CR
	jr z,wait_for_first_enter_cr
	cp #LF
	jr nz,wait_for_first_enter
	xor a
	ld (EOL_CR_FLAG),a
	ret

wait_for_first_enter_cr:
	ld a,#0x01
	ld (EOL_CR_FLAG),a
	ret

; Print a NUL-terminated string at HL.
; Input: HL = address of NUL-terminated string.
; Output: all bytes before the NUL are sent to the console.
; Clobbers: AF, HL.
sio_puts:
	ld a,(hl)
	or a
	ret z
	call sio_putc
	inc hl
	jr sio_puts

; Read an edited console line into LINE_BUF and NUL-terminate it.
; Echoes printable characters. CR or LF ends the line. Backspace/delete edits.
; Input: none.
; Output: HL = LINE_BUF, containing a NUL-terminated line without CR/LF.
; Clobbers: AF, BC, HL.
sio_getline:
	ld hl,#LINE_BUF
	ld c,#0x00
sio_getline_loop:
	call sio_getc
	cp #LF
	jr nz,sio_getline_not_lf
	; If the previous line ended with CR and this LF is the first character of
	; the new read, treat it as the second half of CRLF and discard it.
	ld b,a
	ld a,c
	or a
	jr nz,sio_getline_lf_done
	ld a,(EOL_CR_FLAG)
	or a
	jr z,sio_getline_lf_done
	xor a
	ld (EOL_CR_FLAG),a
	jr sio_getline_loop

sio_getline_lf_done:
	xor a
	ld (EOL_CR_FLAG),a
	ld a,b
	; A real LF line ending falls through to the common terminator path.
	jr sio_getline_done

sio_getline_not_lf:
	; Any non-LF input clears the pending-CR state. CR below marks the state
	; again so a following LF can be suppressed by the next getline call.
	ld b,a
	xor a
	ld (EOL_CR_FLAG),a
	ld a,b
	cp #CR
	jr z,sio_getline_cr_done
	cp #BS
	jr z,sio_getline_backspace
	cp #DEL
	jr z,sio_getline_backspace
	cp #0x20
	jr c,sio_getline_loop
	; Printable bytes are stored until LINE_MAX-1 so there is always room for
	; the terminating NUL.
	ld b,a
	ld a,c
	cp #(LINE_MAX - 1)
	jr nc,sio_getline_bell
	ld a,b
	ld (hl),a
	inc hl
	inc c
	call sio_putc
	jr sio_getline_loop

sio_getline_bell:
	; A full input buffer rejects additional printable characters and rings the
	; terminal bell without changing the buffer.
	ld a,#0x07
	call sio_putc
	jr sio_getline_loop

sio_getline_backspace:
	; Backspace and DEL both erase one buffered character. Echo the conventional
	; BS-space-BS sequence to remove it from simple terminals.
	ld a,c
	or a
	jr z,sio_getline_loop
	dec hl
	dec c
	ld a,#BS
	call sio_putc
	ld a,#0x20
	call sio_putc
	ld a,#BS
	call sio_putc
	jr sio_getline_loop

sio_getline_cr_done:
	; Remember CR termination so a following LF from CRLF input does not become
	; an empty command line.
	ld a,#0x01
	ld (EOL_CR_FLAG),a
	jr sio_getline_done

sio_getline_done:
	; Terminate the command in RAM and echo the monitor's normal CRLF before
	; returning LINE_BUF to the dispatcher.
	ld (hl),#0x00
	call print_crlf
	ld hl,#LINE_BUF
	ret
