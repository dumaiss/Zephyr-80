; Hex parsing, ASCII normalization, and writable range checks.
;
; The command parsers use the carry flag consistently: carry clear means
; success, carry set means invalid input. On success, HL advances past the
; consumed digits so command handlers can parse the next argument.

; Parse a whitespace-prefixed 16-bit hex value from HL.
; Input: HL = current position in LINE_BUF.
; Output: DE = value, HL advanced, carry clear on success.
; Error: carry set if no digits were found or more than four digits supplied.
; Clobbers: AF, BC, DE, HL.
parse_hex_word:
	call skip_spaces
	ld de,#0x0000
	ld b,#0x00
parse_hex_word_loop:
	ld a,(hl)
	call hex_to_nibble
	jr c,parse_hex_word_end
	ld c,a
	ld a,b
	cp #0x04
	jr nc,parse_hex_word_fail
	; Shift the accumulator in DE left by four bits, then merge the new nibble
	; into E. B counts consumed digits so empty input and overflow can be
	; rejected without accepting partial garbage.
	ld a,e
	add a,a
	ld e,a
	ld a,d
	adc a,a
	ld d,a
	ld a,e
	add a,a
	ld e,a
	ld a,d
	adc a,a
	ld d,a
	ld a,e
	add a,a
	ld e,a
	ld a,d
	adc a,a
	ld d,a
	ld a,e
	add a,a
	ld e,a
	ld a,d
	adc a,a
	ld d,a
	ld a,e
	or c
	ld e,a
	inc b
	inc hl
	jr parse_hex_word_loop

parse_hex_word_end:
	ld a,b
	or a
	jr z,parse_hex_word_fail
	or a
	ret

parse_hex_word_fail:
	scf
	ret

; Parse an 8-bit hex value from HL.
; Input: HL = current position in LINE_BUF.
; Output: A = value, HL advanced, carry clear on success.
; Error: carry set if the parsed word is invalid or greater than FFh.
; Clobbers: AF, BC, DE, HL.
parse_hex_byte:
	call parse_hex_word
	ret c
	ld a,d
	or a
	jr nz,parse_hex_byte_fail
	ld a,e
	or a
	ret
parse_hex_byte_fail:
	scf
	ret

; Parse exactly two Intel HEX digits at HL.
; Input: HL = address of the first ASCII hex digit.
; Output: A = byte, HL advanced by two, carry clear on success.
; Error: carry set if either digit is invalid.
; Preserves: BC, DE. Clobbers: AF, HL.
hex_pair_from_hl:
	push bc
	ld a,(hl)
	call hex_to_nibble
	jr c,hex_pair_fail
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a
	inc hl
	ld a,(hl)
	call hex_to_nibble
	jr c,hex_pair_fail
	or b
	inc hl
	pop bc
	or a
	ret
hex_pair_fail:
	pop bc
	scf
	ret

; Add A to the running Intel HEX checksum and return the original A.
; Input: A = byte just parsed from an Intel HEX record.
; Output: HEX_SUM updated, A restored to input value.
; Preserves: BC, DE, HL. Clobbers: F.
hex_add_sum:
	push bc
	ld b,a
	ld a,(HEX_SUM)
	add a,b
	ld (HEX_SUM),a
	ld a,b
	pop bc
	ret

; Convert ASCII hex digit in A to a nibble.
; Input: A = ASCII character.
; Output: A = 0-15 and carry clear, or carry set if invalid.
; Lowercase a-f is accepted through to_upper_a.
hex_to_nibble:
	cp #0x30		; '0'
	jr c,hex_to_nibble_bad
	cp #0x3a		; '9' + 1
	jr c,hex_to_nibble_digit
	call to_upper_a
	cp #0x41		; 'A'
	jr c,hex_to_nibble_bad
	cp #0x47		; 'F' + 1
	jr nc,hex_to_nibble_bad
	sub #0x37		; 'A' - 10
	or a
	ret
hex_to_nibble_digit:
	sub #0x30
	or a
	ret
hex_to_nibble_bad:
	scf
	ret

; Skip spaces and tabs at HL.
; Input: HL = command-line scan position.
; Output: HL at first non-space/tab. Clobbers: AF, HL.
skip_spaces:
	ld a,(hl)
	cp #0x20
	jr z,skip_spaces_next
	cp #0x09
	ret nz
skip_spaces_next:
	inc hl
	jr skip_spaces

; Convert lowercase ASCII letter in A to uppercase.
; Input: A = ASCII character.
; Output: A converted if it was 'a' through 'z'. Clobbers: AF.
to_upper_a:
	cp #0x61		; 'a'
	ret c
	cp #0x7b		; 'z' + 1
	ret nc
	sub #0x20
	ret

; Carry clear if HL is writable monitor-visible RAM.
; Input: HL = address to test.
; Output: carry clear.
; Clobbers: AF.
; Monitor runs in the current CP/M application bank. Keep this helper for
; command code that wants a single writability check point.
check_hl_writable:
	xor a
	ret
