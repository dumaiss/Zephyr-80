; Intel HEX export record emission routines.
;
; The X command exports memory as Intel HEX. Data records are emitted in chunks
; of up to 16 bytes, followed by a type 01 EOF record. Each emitted byte that
; contributes to a record checksum passes through ihex_emit_sum_byte.

; Emit X_LEN bytes starting at X_ADDR as Intel HEX type 00 records plus EOF.
; Input: X_ADDR = first byte to export, X_LEN = number of bytes.
; Output: type 00 data records plus a final EOF record on the console.
; Records are at most 16 bytes. Clobbers: AF, BC, DE, HL.
emit_ihex_range:
emit_ihex_range_loop:
	ld de,(X_LEN)
	ld a,d
	or e
	jr z,emit_ihex_range_eof

	; Use 16 bytes per full record, or the remaining low-byte length for the
	; final short record.
	ld a,d
	or a
	jr nz,emit_ihex_range_16
	ld a,e
	cp #0x10
	jr nc,emit_ihex_range_16
	jr emit_ihex_range_set_count
emit_ihex_range_16:
	ld a,#0x10
emit_ihex_range_set_count:
	ld (X_REC_LEN),a

	call emit_ihex_data_record

	; Advance the export cursor and subtract the record length from X_LEN.
	ld a,(X_REC_LEN)
	ld e,a
	ld d,#0x00
	ld hl,(X_ADDR)
	add hl,de
	ld (X_ADDR),hl

	ld hl,(X_LEN)
	or a
	sbc hl,de
	ld (X_LEN),hl
	jr emit_ihex_range_loop

emit_ihex_range_eof:
	call emit_ihex_eof_record
	ret

; Emit one Intel HEX data record from X_ADDR with length X_REC_LEN.
; Input: X_ADDR = source address, X_REC_LEN = byte count.
; Output: one ":llaaaatt[dd...]cc" type 00 record.
; Clobbers: AF, BC, HL.
emit_ihex_data_record:
	ld a,#0x3a		; ':'
	call sio_putc
	xor a
	ld (X_SUM),a

	; Checksum covers length, address high, address low, type, and data bytes.
	ld a,(X_REC_LEN)
	call ihex_emit_sum_byte
	ld hl,(X_ADDR)
	ld a,h
	call ihex_emit_sum_byte
	ld a,l
	call ihex_emit_sum_byte
	xor a			; record type 00
	call ihex_emit_sum_byte

	ld a,(X_REC_LEN)
	ld b,a
	ld hl,(X_ADDR)
emit_ihex_data_loop:
	ld a,(hl)
	call ihex_emit_sum_byte
	inc hl
	djnz emit_ihex_data_loop

	; Intel HEX checksum is the two's-complement of the low 8 bits of the
	; accumulated record sum.
	ld a,(X_SUM)
	cpl
	inc a
	call print_hex_byte
	call print_crlf
	ret

; Emit Intel HEX EOF record.
; Input: none.
; Output: fixed type 01 EOF record on the console.
; Clobbers: AF, HL.
emit_ihex_eof_record:
	ld hl,#msg_ihex_eof
	call sio_puts
	ret

; Emit byte A as hex and add it to X_SUM. Returns original A.
; Input: A = record byte to print and accumulate.
; Output: A restored to input value, X_SUM updated.
; Preserves: BC, DE, HL. Clobbers: AF.
ihex_emit_sum_byte:
	push bc
	ld b,a
	call print_hex_byte
	ld a,(X_SUM)
	add a,b
	ld (X_SUM),a
	ld a,b
	pop bc
	ret
