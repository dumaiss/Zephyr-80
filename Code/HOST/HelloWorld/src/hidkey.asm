; HIDKEY.COM -- Exercise IOC USB keyboard input without BIOS CONST/CONIN.
;
; The IOC translates boot-keyboard reports into terminal input bytes.  This
; program polls that queue directly with CMD_HID_INPUT and sends each returned
; byte to the existing CP/M console output path.  It is deliberately a test
; harness: BIOS console input remains untouched in this phase.
;
; Printable keys echo normally.  Cursor/function keys emit their VT100 escape
; sequences, so the existing console parser exercises the same byte stream it
; will eventually receive through CONST/CONIN.  Ctrl-C exits.

	.module hidkey
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
BDOS_CONSTAT	= 0x0B
IOCALL		= 0xDA3F

	.include "ioc_levels.inc"

CMD_HID_INPUT	= 0x0e
RSP_HID_INPUT	= 0x8e
MAX_READ	= 24

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; The request frame is constant.  IOCALL owns the rolling wire sequence.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx
	ld a,#CMD_HID_INPUT
	ld (tx_frame + 0),a
	ld a,#1
	ld (tx_frame + 3),a
	ld a,#MAX_READ
	ld (tx_frame + 4),a

poll:
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,transport_error

	ld a,(rx_frame + 0)
	cp #RSP_HID_INPUT
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,bad_reply
	ld a,(rx_frame + 3)
	cp #2
	jp c,bad_reply
	cp #(MAX_READ + 3)
	jp nc,bad_reply

	sub #2
	ld (byte_count),a

	; Stuck-queue detector.  The reply carries the controller's remaining
	; queue depth at payload+0.  If a poll returns no data while that depth
	; is non-zero, the bytes exist and the drain is not handing them over --
	; which is a different fault from the bytes never being produced.  Print
	; one '!' per episode rather than per poll, so a stuck queue is visible
	; without flooding the screen.
	ld a,(byte_count)
	or a
	jr nz,got_data
	ld a,(rx_frame + 4)		; queued
	or a
	jr z,not_stuck
	ld a,(stuck_flag)
	or a
	jr nz,poll			; already reported this episode
	ld a,#1
	ld (stuck_flag),a
	ld e,#'!'
	ld c,#BDOS_CONOUT
	call BDOS
	; ...and how many are stuck.  One is an off-by-one in the drain; more is
	; a stalled drain.  The distinction decides where to look.
	ld a,(rx_frame + 4)
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,stuck_digit
	add a,#0x07
stuck_digit:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	call console_publish
	jp poll
not_stuck:
	xor a
	ld (stuck_flag),a
	jp poll
got_data:
	xor a
	ld (stuck_flag),a
	ld hl,#(rx_frame + 6)
emit_loop:
	ld a,(byte_count)
	or a
	jr z,emit_done
	dec a
	ld (byte_count),a

	ld a,(hl)
	inc hl
	cp #0x03
	jr z,done
	push hl
	call emit_byte
	pop hl
	jr emit_loop

emit_done:
	call console_publish
	jp poll

; Show a byte the way CP/M echoes console input: control codes in caret
; notation.  Passing them through raw let the terminal's ANSI parser execute
; them instead of displaying them, which is why F1 -- ESC O P -- showed up as a
; bare "P": the parser consumed the introducer and printed the final byte.  The
; VDrip console's own keyboard reads as ^[OP for the same key, so this makes the
; two directly comparable.
;
; CR and LF are deliberately passed through raw.  They are the only bytes whose
; display action is more useful than their name, and without them the survey
; runs off the end of one line.
emit_byte:
	cp #0x0d
	jr z,emit_plain
	cp #0x0a
	jr z,emit_plain
	cp #0x7f
	jr z,emit_del
	cp #0x20
	jr nc,emit_plain
	push af
	ld e,#'^'
	ld c,#BDOS_CONOUT
	call BDOS
	pop af
	add a,#0x40
emit_plain:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret
emit_del:
	ld e,#'^'
	ld c,#BDOS_CONOUT
	call BDOS
	ld e,#'?'
	ld c,#BDOS_CONOUT
	call BDOS
	ret

; The VDrip console does not display a printable character when CONOUT writes
; it.  text_put_printable only appends to print_run_buffer, and the run is
; published -- flushed, cursor written, OP_PRESENT sent -- from CONST and CONIN
; only.  That is deliberate batching, and every normal program gets it for free
; because the CCP and BDOS poll console input constantly.
;
; This program does not: it polls the IOC through IOCALL and never touches
; console input, so its output sat in the run buffer and became visible only
; when the *next* character's BDOS call happened to poll status.  That, and not
; anything in the USB path, is what made the display run one keystroke behind.
;
; BDOS 11 routes to BIOS CONST, which publishes the run.  It is cheap to call
; unconditionally: vdrip_console_const returns immediately when the run is
; empty, and is documented as safe for hot polling loops.
console_publish:
	push hl
	ld c,#BDOS_CONSTAT
	call BDOS
	pop hl
	ret

done:
	ld de,#msg_done
	ld c,#BDOS_PRINT
	call BDOS
	ret

transport_error:
	ld de,#msg_transport
	ld c,#BDOS_PRINT
	call BDOS
	ret

bad_reply:
	ld de,#msg_reply
	ld c,#BDOS_PRINT
	call BDOS
	ret

msg_banner:
	.ascii "IOC HID keyboard test - Ctrl-C exits\r\n$"
msg_done:
	.ascii "\r\nHID keyboard test stopped\r\n$"
msg_transport:
	.ascii "\r\nHID command transport error\r\n$"
msg_reply:
	.ascii "\r\nUnexpected HID_INPUT reply (firmware level "
	.db IOC_FW_LEVEL_DEC_HI,IOC_FW_LEVEL_DEC_LO
	.ascii " required)\r\n$"

byte_count:
	.db 0
stuck_flag:
	.db 0

	.area DATA (ABS)
	.org 0x0800
tx_frame:
	.ds 32
rx_frame:
	.ds 32
