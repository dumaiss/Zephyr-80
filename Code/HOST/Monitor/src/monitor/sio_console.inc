; BIOS-backed monitor console routines.
;
; The monitor keeps its historical sio_* routine names so command, line-editing,
; and Intel HEX code stay unchanged. These wrappers call the resident
; CP/M-style BIOS console ABI; the BIOS owns SIO initialization and hardware
; polling.

; Write A through BIOS CONOUT.
; Input: A = byte to transmit.
; Output: byte written to the BIOS console.
; Preserves: BC, DE, HL, IX, IY. Clobbers: AF.
sio_putc:
	push bc
	push hl
	ld c,a
	call BCOUT
	pop hl
	pop bc
	ret

; Read one byte through BIOS CONIN.
; Input: none.
; Output: A = received byte.
; Preserves: BC, DE, HL, IX, IY. Clobbers: AF.
sio_getc:
	push hl
	call BCIN
	pop hl
	ret

; Query BIOS CONST.
; Input: none.
; Output: A = 00h if no character is pending, FFh if one is available.
; Preserves: BC, DE, HL, IX, IY. Clobbers: AF.
sio_const:
	push hl
	call BCNST
	pop hl
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
; Up arrow recalls the previous command line stored in HISTORY_BUF.
; Input: none.
; Output: HL = LINE_BUF, containing a NUL-terminated line without CR/LF.
; Clobbers: AF, BC, DE, HL.
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
	jp sio_getline_done

sio_getline_not_lf:
	; Any non-LF input clears the pending-CR state. CR below marks the state
	; again so a following LF can be suppressed by the next getline call.
	ld b,a
	xor a
	ld (EOL_CR_FLAG),a
	ld a,b
	cp #CR
	jr z,sio_getline_cr_done
	cp #ESC
	jr z,sio_getline_escape
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

sio_getline_escape:
	; Terminals send up arrow as ESC [ A. Ignore other escape sequences.
	call sio_getc
	cp #0x5b		; [
	jr nz,sio_getline_loop
	call sio_getc
	cp #0x41		; A
	jr nz,sio_getline_loop
	ld a,(HISTORY_LEN)
	or a
	jr z,sio_getline_bell

sio_getline_recall_erase:
	ld a,c
	or a
	jr z,sio_getline_recall_copy
	dec hl
	dec c
	call sio_erase_echo
	jr sio_getline_recall_erase

sio_getline_recall_copy:
	ld hl,#LINE_BUF
	ld de,#HISTORY_BUF
	ld a,(HISTORY_LEN)
	ld b,a
	ld c,#0x00

sio_getline_recall_copy_loop:
	ld a,b
	or a
	jp z,sio_getline_loop
	ld a,(de)
	ld (hl),a
	inc de
	inc hl
	inc c
	call sio_putc
	dec b
	jr sio_getline_recall_copy_loop

sio_getline_backspace:
	; Backspace and DEL both erase one buffered character. Echo the conventional
	; BS-space-BS sequence to remove it from simple terminals.
	ld a,c
	or a
	jp z,sio_getline_loop
	dec hl
	dec c
	call sio_erase_echo
	jp sio_getline_loop

sio_erase_echo:
	ld a,#BS
	call sio_putc
	ld a,#0x20
	call sio_putc
	ld a,#BS
	call sio_putc
	ret

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

; Save the current non-empty LINE_BUF contents as the one-line recall history.
; Input: LINE_BUF contains a NUL-terminated command line.
; Output: HISTORY_BUF and HISTORY_LEN updated for non-empty lines.
; Clobbers: AF, BC, DE, HL.
sio_save_line_history:
	ld hl,#LINE_BUF
	ld a,(hl)
	or a
	ret z
	ld de,#HISTORY_BUF
	ld c,#0x00

sio_save_line_history_loop:
	ld a,(hl)
	ld (de),a
	or a
	jr z,sio_save_line_history_done
	inc hl
	inc de
	inc c
	jr sio_save_line_history_loop

sio_save_line_history_done:
	ld a,c
	ld (HISTORY_LEN),a
	ret
