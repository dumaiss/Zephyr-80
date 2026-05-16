; Memory dump command implementation helper.
;
; This module implements the D command's formatted output. Each line contains
; an address column, sixteen possible hex byte columns, padding for short final
; lines, and a printable ASCII view.

; Dump memory at DUMP_ADDR for DUMP_LEN bytes, 16 bytes per line.
; Input: DUMP_ADDR = first address, DUMP_LEN = byte count.
; Output: formatted dump lines on the console.
; Clobbers: AF, BC, DE, HL and DUMP_* workspace state.
dump_memory:
dump_memory_loop:
	ld de,(DUMP_LEN)
	ld a,d
	or e
	ret z

	; Start each row by saving and printing the row address, followed by a
	; colon and space before the hex byte area.
	ld hl,(DUMP_ADDR)
	ld (DUMP_LINE_ADDR),hl
	call print_hex_word
	ld a,#0x3a
	call sio_putc
	ld a,#0x20
	call sio_putc

	ld de,(DUMP_LEN)
	ld a,d
	or a
	jr nz,dump_count_16
	; Full rows contain 16 bytes. The final row may be shorter when fewer than
	; 16 bytes remain.
	ld a,e
	cp #0x10
	jr nc,dump_count_16
	jr dump_count_set
dump_count_16:
	ld a,#0x10
dump_count_set:
	ld (DUMP_LINE_COUNT),a

	ld hl,(DUMP_LINE_ADDR)
	ld a,(DUMP_LINE_COUNT)
	ld b,a
	; Print each byte as two hex digits plus a trailing space, then keep
	; DUMP_ADDR at the next unread byte.
dump_hex_loop:
	ld a,(hl)
	call print_hex_byte
	ld a,#0x20
	call sio_putc
	inc hl
	djnz dump_hex_loop
	ld (DUMP_ADDR),hl

	ld a,(DUMP_LINE_COUNT)
	ld b,a
	ld a,#0x10
	sub b
	jr z,dump_no_pad
	ld b,a
dump_pad_loop:
	; Short final rows get three spaces for each missing hex byte so the ASCII
	; column stays aligned with full rows.
	ld a,#0x20
	call sio_putc
	call sio_putc
	call sio_putc
	djnz dump_pad_loop

dump_no_pad:
	ld a,#0x20
	call sio_putc
	ld hl,(DUMP_LINE_ADDR)
	ld a,(DUMP_LINE_COUNT)
	ld b,a
	; ASCII view prints bytes in the printable 20h-7Eh range directly and uses
	; '.' for control or DEL/high-bit bytes.
dump_ascii_loop:
	ld a,(hl)
	cp #0x20
	jr c,dump_ascii_dot
	cp #0x7f
	jr nc,dump_ascii_dot
	jr dump_ascii_emit
dump_ascii_dot:
	ld a,#0x2e
dump_ascii_emit:
	call sio_putc
	inc hl
	djnz dump_ascii_loop
	call print_crlf

	; Reduce the remaining length by the number of bytes emitted on this row
	; and loop until DUMP_LEN reaches zero.
	ld hl,(DUMP_LEN)
	ld a,(DUMP_LINE_COUNT)
	ld e,a
	ld d,#0x00
	or a
	sbc hl,de
	ld (DUMP_LEN),hl
	jp dump_memory_loop
