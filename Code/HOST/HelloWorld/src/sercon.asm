; SERCON.COM — turn the BIOS serial console tee on or off.
;
; The BIOS mirrors CONOUT to SIO0/B when the tee is armed, so a terminal on that
; port sees everything the V9958 shows.  Three ESCs typed at the terminal toggle
; input ownership and arm the tee, which is the rescue path when the screen is
; dark.  This program is the other half of that: it can arm the tee BEFORE a
; session so the terminal captures boot output, and it can turn the tee off
; again, which the ESC gesture cannot do usefully once you have unplugged the
; terminal.
;
; Turning it off matters more than it looks.  sio_send_byte's console path waits
; for TX-buffer-empty AND /CTS, and with no terminal attached /CTS never
; asserts.  The BIOS checks /CTS itself before sending, so an absent terminal is
; cheap -- but leaving the tee armed with a terminal that asserts /CTS and then
; stops reading would still cost the full timeout per character.
;
;   SERCON        report the current state
;   SERCON ON     arm the tee
;   SERCON OFF    disarm the tee, and return input to the keyboard
;
; OFF also clears the input-ownership bit.  If serial had taken over CONIN and
; you disarm from the keyboard side, leaving that bit set would strand input on
; a port nobody is watching.

	.module sercon
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_PRINT	= 0x09

; Published BIOS addresses.  SERCON_FLAGS sits above the SIO core state in
; every build, so it does not move between console backends.  See
; CPM2.2/src/cbios_defs.inc.
SERCON_FLAGS		= 0xFE78
SERCON_FLAG_TEE		= 0x01
SERCON_FLAG_INPUT	= 0x02

; CP/M upper-cases the command tail, so only the upper-case forms are matched.
CMDTAIL		= 0x0080
CMDTAIL_TEXT	= 0x0081

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; Find the first non-blank of the tail; an empty tail means "report".
	ld a,(CMDTAIL)
	or a
	jr z,report
	ld hl,#CMDTAIL_TEXT
skip_blanks:
	ld a,(hl)
	or a
	jr z,report
	cp #0x20			; space
	jr nz,have_arg
	inc hl
	jr skip_blanks

have_arg:
	; "ON" -> arm.  "OFF" -> disarm.  Anything else is reported, not guessed
	; at: this toggles a console, and a typo should not silently do the
	; opposite of what was meant.
	ld a,(hl)
	cp #'O
	jr nz,bad_arg
	inc hl
	ld a,(hl)
	cp #'N
	jr z,do_on
	cp #'F
	jr nz,bad_arg
	inc hl
	ld a,(hl)
	cp #'F
	jr nz,bad_arg
	jr do_off

do_on:
	ld a,(SERCON_FLAGS)
	or #SERCON_FLAG_TEE
	ld (SERCON_FLAGS),a
	ld de,#msg_on
	jr say_and_exit

do_off:
	; Clear input ownership with the tee: see the header.
	ld a,(SERCON_FLAGS)
	and #0xfc			; clear SERCON_FLAG_TEE and SERCON_FLAG_INPUT
	ld (SERCON_FLAGS),a
	ld de,#msg_off
	jr say_and_exit

bad_arg:
	ld de,#msg_usage
	jr say_and_exit

report:
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_TEE
	ld de,#msg_is_off
	jr z,report_input
	ld de,#msg_is_on
report_input:
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	ld de,#msg_in_kbd
	jr z,say_and_exit
	ld de,#msg_in_ser
say_and_exit:
	ld c,#BDOS_PRINT
	call BDOS
	ret

msg_banner:
	.ascii "SERCON - BIOS serial console tee"
	.db 13,10,'$'
msg_on:
	.ascii "  tee armed: CONOUT mirrors to the serial port"
	.db 13,10,'$'
msg_off:
	.ascii "  tee disarmed; input returned to the keyboard"
	.db 13,10,'$'
msg_is_on:
	.ascii "  tee       : armed"
	.db 13,10,'$'
msg_is_off:
	.ascii "  tee       : off"
	.db 13,10,'$'
msg_in_kbd:
	.ascii "  input from: USB keyboard  (ESC ESC ESC on serial toggles)"
	.db 13,10,'$'
msg_in_ser:
	.ascii "  input from: serial port   (ESC ESC ESC toggles back)"
	.db 13,10,'$'
msg_usage:
	.ascii "  usage: SERCON [ON|OFF]"
	.db 13,10,'$'
