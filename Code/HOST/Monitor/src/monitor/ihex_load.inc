; Intel HEX loader command and load error exits.
;
; Supported input record format:
;   :llaaaatt[dd...]cc
; where ll is byte count, aaaa is the 16-bit load address, tt is record type,
; dd bytes are data, and cc is the checksum. Only type 00 data and type 01 EOF
; records are accepted.

; Intel HEX loader. Supports type 00 data and type 01 EOF records.
; Data is parsed into HEX_BUF first, checksum is validated, then RAM is written.
; Input: console lines typed or pasted after the L command.
; Output: valid type 00 data records written to RAM; EOF returns to monitor.
; Clobbers: AF, BC, DE, HL and HEX_* workspace state.
cmd_load_hex:
	ld hl,#msg_load_start
	call sio_puts
cmd_load_hex_loop:
	call sio_getline
	ld hl,#LINE_BUF
	ld a,(hl)
	cp #0x3a		; ':'
	jp nz,load_error_parse
	inc hl
	xor a
	ld (HEX_SUM),a

	; Parse record length and add it to the running checksum.
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld (HEX_COUNT),a

	; Parse the 16-bit record address from two byte fields.
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld d,a
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld e,a
	ld (HEX_ADDR),de

	; Parse the record type. Type selection happens only after the checksum
	; byte has been consumed and validated.
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld (HEX_TYPE),a

	ld de,#HEX_BUF
	ld a,(HEX_COUNT)
	or a
	jr z,load_data_parsed
	; Stage the data bytes in HEX_BUF. Nothing is written to RAM until parsing,
	; checksum validation, type validation, and range checks have all passed.
	ld b,a
load_data_parse_loop:
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld (de),a
	inc de
	djnz load_data_parse_loop

load_data_parsed:
	; The checksum byte is included in HEX_SUM. A valid Intel HEX record leaves
	; the low 8 bits of the total sum equal to zero.
	call hex_pair_from_hl
	jp c,load_error_parse
	call hex_add_sum
	ld a,(HEX_SUM)
	or a
	jp nz,load_error_checksum

	ld a,(HEX_TYPE)
	or a
	jr z,load_record_data
	cp #0x01
	jr z,load_record_eof
	jp load_error_record_type

load_record_data:
	ld a,(HEX_COUNT)
	or a
	jr z,load_record_good
	; Check the entire destination range before writing any byte. Below 6000h,
	; the board writes SRAM but reads still select ROM, so loader writes there
	; would not be visible as normal memory while ROM_DIS=0.
	ld b,a
	ld hl,(HEX_ADDR)
load_range_check_loop:
	call check_hl_writable
	jp c,load_error_rom_region
	inc hl
	djnz load_range_check_loop

	; With the record validated and the full range known writable, copy the
	; staged bytes into RAM.
	ld a,(HEX_COUNT)
	ld b,a
	ld hl,(HEX_ADDR)
	ld de,#HEX_BUF
load_write_loop:
	ld a,(de)
	ld (hl),a
	inc de
	inc hl
	djnz load_write_loop

load_record_good:
	; A valid data record is acknowledged with a dot and the loader waits for
	; the next Intel HEX line.
	ld a,#0x2e		; '.'
	call sio_putc
	call print_crlf
	jp cmd_load_hex_loop

load_record_eof:
	; EOF records must have zero data length. A valid EOF ends load mode.
	ld a,(HEX_COUNT)
	or a
	jp nz,load_error_parse
	ld hl,#msg_load_ok
	call sio_puts
	jp monitor_loop

load_error_parse:
	; All loader errors print a specific message and abandon load mode.
	ld hl,#msg_err_hex_parse
	call sio_puts
	jp monitor_loop

load_error_checksum:
	ld hl,#msg_err_checksum
	call sio_puts
	jp monitor_loop

load_error_rom_region:
	ld hl,#msg_err_rom_region
	call sio_puts
	jp monitor_loop

load_error_record_type:
	ld hl,#msg_err_record_type
	call sio_puts
	jp monitor_loop
