; Hex and line-ending print helpers for the monitor console.
;
; These routines format binary values as uppercase hexadecimal ASCII and send
; the bytes through sio_putc. They do not allocate buffers.

; Print HL as four uppercase hex digits.
; Input: HL = word to print.
; Output: four characters on the console.
; Preserves: HL. Clobbers: AF.
print_hex_word:
	push hl
	ld a,h
	call print_hex_byte
	ld a,l
	call print_hex_byte
	pop hl
	ret

; Print A as two uppercase hex digits.
; Input: A = byte to print.
; Output: two characters on the console.
; Clobbers: AF.
print_hex_byte:
	push af
	; Rotate the high nibble into the low position for the first digit, then
	; restore A and print the original low nibble.
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
	call print_hex_nibble
	ret

; Print the low nibble of A as one uppercase hex digit.
; Input: A = value whose low nibble is in range 0..15.
; Output: one character on the console.
; Clobbers: AF.
print_hex_nibble:
	cp #0x0a
	jr c,print_hex_nibble_digit
	add a,#0x37		; 'A' - 10
	call sio_putc
	ret
print_hex_nibble_digit:
	add a,#0x30
	call sio_putc
	ret

; Print the monitor's standard CRLF line ending.
; Input: none. Output: CR then LF on the console. Clobbers: AF.
print_crlf:
	ld a,#CR
	call sio_putc
	ld a,#LF
	call sio_putc
	ret

; Print two spaces, used by compact register output formatting.
; Input: none. Output: two spaces on the console. Clobbers: AF.
print_two_spaces:
	ld a,#0x20
	call sio_putc
	call sio_putc
	ret
