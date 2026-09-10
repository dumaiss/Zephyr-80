; Minimal CP/M console UI scaffold. The active V9958 console may be in its
; 80-column text mode; this module knows nothing about VDP ports or PSG bytes.

ui_init:
	ld de,#ui_playing
	call puts
	ld hl,(title_ptr)
	call ui_puts_z
	ld de,#ui_help
	call puts
	jp ui_refresh

; ui_refresh -- redraw one compact heartbeat at each order boundary.
;   Clobbers: AF, B, DE, HL, IX. May block on foreground BDOS output.
;   Emits no Virtual Drip frames directly and is not ISR-safe.
ui_refresh:
	ld a,(row_changed)
	or a
	ret z
	xor a
	ld (row_changed),a
	ld e,#0x0d
	call ui_putchar
	ld de,#ui_order
	call puts
	ld a,(current_order)
	call ui_puthex8
	ld de,#ui_time
	call puts
	ld a,(elapsed_minutes)
	call ui_putdec2
	ld e,#':'
	call ui_putchar
	ld a,(elapsed_seconds)
	call ui_putdec2
	ld de,#ui_interrupts
	call puts
	ld a,(unexpected_interrupts)
	call ui_puthex8
	ld de,#ui_clear_tail
	jp puts

; Print note A as C-0..B-7.
ui_put_note:
	ld c,#0
ui_note_octave_loop:
	cp #12
	jr c,ui_note_remainder
	sub #12
	inc c
	jr ui_note_octave_loop
ui_note_remainder:
	add a,a
	ld l,a
	ld h,#0
	ld de,#ui_note_names
	add hl,de
	push bc
	push hl
	ld e,(hl)
	call ui_putchar
	pop hl
	inc hl
	ld e,(hl)
	call ui_putchar
	pop bc
	ld a,c
	add a,#'0'
	ld e,a
	jp ui_putchar

ui_puts_z:
	ld a,(hl)
	or a
	ret z
	inc hl
	push hl
	ld e,a
	call ui_putchar
	pop hl
	jr ui_puts_z

ui_puthex8:
	push af
	rrca
	rrca
	rrca
	rrca
	call ui_puthex4
	pop af
ui_puthex4:
	and #0x0f
	add a,#'0'
	cp #('9' + 1)
	jr c,ui_puthex_emit
	add a,#('A' - '9' - 1)
ui_puthex_emit:
	ld e,a
ui_putchar:
	push ix
	ld c,#BDOS_CONOUT
	call BDOS
	pop ix
	ret

; Print binary A as two decimal digits. The elapsed clock keeps values below
; 100, so repeated subtraction stays bounded to nine iterations.
ui_putdec2:
	ld b,#'0'
ui_putdec2_tens:
	cp #10
	jr c,ui_putdec2_emit
	sub #10
	inc b
	jr ui_putdec2_tens
ui_putdec2_emit:
	push af
	ld e,b
	call ui_putchar
	pop af
	add a,#'0'
	ld e,a
	jp ui_putchar

ui_playing:
	.ascii "Playing: $"
ui_help:
	.ascii "\r\nQ/Esc: stop; one update per pattern block\r\n$"
ui_order:
	.ascii "O$"
ui_time:
	.ascii " T$"
ui_interrupts:
	.ascii " I$"
ui_clear_tail:
	.ascii "   $"
ui_note_names:
	.ascii "C-C#D-D#E-F-F#G-G#A-A#B-"
