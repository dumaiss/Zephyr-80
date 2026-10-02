; ===========================================================================
; Per-title cartridge patch manifest.
;
; The trace in cartscan.inc cannot reach code entered only through a computed
; jump, and it cannot rewrite a port that a title holds in a register rather
; than in an operand. A manifest named after the cartridge, with CP/M type
; PAT, supplies those sites explicitly under the same guarded expect/replace
; discipline the BIOS patch table uses.
;
; The manifest is bound to one image by length and CRC-16, and every site is
; verified before any byte is written, so a manifest that does not match the
; loaded cartridge changes nothing. A missing manifest is not an error.
;
; File layout, little-endian, padded to a whole CP/M record:
;
;   0    4    "CGP1"
;   4    2    image length in bytes, record-rounded
;   6    2    CRC-16/CCITT-FALSE of the unpatched record-rounded image
;   8    2    entry count, 1 through PAT_MAX_ENTRIES
;   10   4n   entry: offset from image start (2), expected byte, replacement
;
; Build one with tools/scan_cartridge.py. This file depends on the includer's
; FCB helpers, read_exact_records, puts and exit_error.
; ===========================================================================

PAT_HEADER_BYTES	= 10
PAT_ENTRY_BYTES		= 4
PAT_MAX_ENTRIES		= 512
PAT_RECORDS_MAX		= 17
PAT_BUFFER_BYTES	= PAT_RECORDS_MAX * 128

PAT_OFF_LENGTH		= PATCH_BUFFER + 4
PAT_OFF_CRC		= PATCH_BUFFER + 6
PAT_OFF_COUNT		= PATCH_BUFFER + 8
PAT_OFF_ENTRIES		= PATCH_BUFFER + PAT_HEADER_BYTES

; Compute and record the CRC of the cartridge exactly as it was loaded. This
; must run before the scanner rewrites any operand, so that a manifest is
; bound to the image on disk rather than to the already-adapted copy.
; Clobbers AF, BC, DE, HL. Does not block.
compute_cart_crc:
	ld hl,#CART_BUFFER
	ld bc,(cart_byte_count)
	call crc16_ccitt
	ld (cart_crc16),de
	ret

; CRC-16/CCITT-FALSE, computed bitwise so no table is needed.
; Inputs: HL = start address, BC = byte count.
; Output: DE = the CRC. Clobbers AF, BC, HL.
; Takes roughly a second over a full 32 KiB image at 10 MHz. Does not block
; in BDOS, emit I/O, or touch the takeover bank.
crc16_ccitt:
	ld de,#0xffff
crc16_next_byte:
	ld a,b
	or c
	ret z
	ld a,(hl)
	xor d
	ld d,a
	push bc
	ld b,#8
crc16_next_bit:
	sla e
	rl d
	jr nc,crc16_no_poly
	ld a,d
	xor #0x10
	ld d,a
	ld a,e
	xor #0x21
	ld e,a
crc16_no_poly:
	djnz crc16_next_bit
	pop bc
	inc hl
	dec bc
	jr crc16_next_byte

; Apply the cartridge's PAT manifest, if one exists beside it.
; Inputs: the loaded image, cart_byte_count and cart_crc16.
; Outputs: verified replacements applied to CART_BUFFER, or a return to CP/M
;   through exit_error with the takeover bank untouched. A missing manifest
;   returns quietly.
; Clobbers AF, BC, DE, HL, IX. May block in BDOS.
apply_cart_patch_file:
	call init_patch_fcb
	call open_work_fcb
	ret z				; no manifest beside this cartridge

	call compute_work_file_size
	ld a,(work_fcb + FCB_R2)
	or a
	jr nz,patch_bad_size
	ld a,(work_fcb + FCB_R1)
	or a
	jr nz,patch_bad_size
	ld a,(work_fcb + FCB_R0)
	or a
	jr z,patch_bad_size
	cp #(PAT_RECORDS_MAX + 1)
	jr nc,patch_bad_size
	ld l,a
	ld h,#0
	push hl
	call close_work_fcb
	pop hl
	jr z,patch_bad_close

	; Re-open for the data pass: function 35 has moved the FCB's record
	; fields, and the loader's other readers follow the same pattern.
	ld (records_left),hl
	call init_patch_fcb
	call open_work_fcb
	jr z,patch_bad_open
	ld hl,#PATCH_BUFFER
	ld (load_ptr),hl
	ld hl,#patch_bad_read
	ld (read_error_target),hl
	call read_exact_records
	call close_work_fcb
	jr z,patch_bad_close
	jp verify_and_apply_patch

patch_bad_size:
	call close_work_fcb
	ld de,#msg_pat_size
	jp exit_error
patch_bad_open:
	ld de,#msg_pat_open
	jp exit_error
patch_bad_close:
	ld de,#msg_pat_close
	jp exit_error
patch_bad_read:
	call close_work_fcb
	ld de,#msg_pat_read
	jp exit_error

; Build the working FCB for the cartridge's manifest: the cartridge's drive
; and name with the type replaced by PAT.
; Clobbers AF, BC, DE, HL.
init_patch_fcb:
	ld hl,#cart_fcb_name
	call init_work_fcb
	ld hl,#(work_fcb + 9)
	ld (hl),#'P'
	inc hl
	ld (hl),#'A'
	inc hl
	ld (hl),#'T'
	ret

; Validate the whole manifest, then apply it. Nothing is written until every
; site has been checked, so a manifest that fails leaves the image as the
; scanner left it.
verify_and_apply_patch:
	ld hl,#PATCH_BUFFER
	ld de,#pat_magic
	ld b,#4
patch_magic_loop:
	ld a,(de)
	cp (hl)
	jr nz,patch_bad_format
	inc hl
	inc de
	djnz patch_magic_loop

	; The manifest names exactly one image.
	ld hl,(cart_byte_count)
	ld de,(PAT_OFF_LENGTH)
	or a
	sbc hl,de
	jr nz,patch_bad_rom
	ld hl,(cart_crc16)
	ld de,(PAT_OFF_CRC)
	or a
	sbc hl,de
	jr nz,patch_bad_rom

	ld hl,(PAT_OFF_COUNT)
	ld a,h
	or l
	jr z,patch_bad_format
	ld de,#(PAT_MAX_ENTRIES + 1)
	or a
	sbc hl,de
	jr nc,patch_bad_format

	; Pass one: verify every site.
	ld ix,#PAT_OFF_ENTRIES
	ld bc,(PAT_OFF_COUNT)
patch_verify_loop:
	ld a,b
	or c
	jr z,patch_verify_done
	call patch_entry_address
	jr c,patch_bad_range
	ld a,(hl)
	cp 2(ix)
	jr nz,patch_bad_expect
	ld de,#PAT_ENTRY_BYTES
	add ix,de
	dec bc
	jr patch_verify_loop
patch_verify_done:

	; Pass two: the manifest is known good, so apply it.
	ld ix,#PAT_OFF_ENTRIES
	ld bc,(PAT_OFF_COUNT)
patch_apply_loop:
	ld a,b
	or c
	jr z,patch_apply_done
	call patch_entry_address
	ld a,3(ix)
	ld (hl),a
	ld de,#PAT_ENTRY_BYTES
	add ix,de
	dec bc
	jr patch_apply_loop
patch_apply_done:
	ld de,#msg_pat_applied
	call puts
	ld hl,(PAT_OFF_COUNT)
	call print_u16
	ld de,#msg_pat_entries
	jp puts

patch_bad_format:
	ld de,#msg_pat_format
	jp exit_error
patch_bad_rom:
	ld de,#msg_pat_rom
	jp exit_error
patch_bad_range:
	ld de,#msg_pat_range
	jp exit_error
patch_bad_expect:
	ld de,#msg_pat_expect
	jp exit_error

; Inputs: IX = a manifest entry.
; Output: HL = the image byte it names, with CF clear; CF set when the entry's
;   offset lies outside the loaded image. Clobbers AF, DE.
patch_entry_address:
	ld l,0(ix)
	ld h,1(ix)
	ld de,(cart_byte_count)
	or a
	sbc hl,de
	jr c,patch_entry_in_range
	scf
	ret
patch_entry_in_range:
	ld l,0(ix)
	ld h,1(ix)
	ld de,#CART_BUFFER
	add hl,de
	or a
	ret

; ---------------------------------------------------------------------------
; Reporting.
; ---------------------------------------------------------------------------

; Describe the adaptation before the takeover begins. A title whose I/O the
; trace could not reach, or that drives the hardware through OUT (C), is
; reported here rather than simply misbehaving after the handoff.
; Clobbers AF, BC, DE, HL. May block in BDOS.
report_cart_scan:
	ld a,(scan_scanned)
	or a
	jr nz,report_cart_counts
	ld de,#msg_scan_no_header
	jp puts
report_cart_counts:
	ld de,#msg_scan_prefix
	call puts
	ld hl,(scan_vdp_count)
	call print_u16
	ld de,#msg_scan_vdp
	call puts
	ld hl,(scan_snd_count)
	call print_u16
	ld de,#msg_scan_sound
	call puts
	ld hl,(scan_ind_count)
	call print_u16
	ld de,#msg_scan_indirect
	call puts
	ld a,(scan_overflow)
	or a
	ret z
	ld de,#msg_scan_overflow
	jp puts

; Inputs: HL = the value to print.
; Output: the value written to the console in decimal with no padding.
; Clobbers AF, BC, DE, HL. May block in BDOS.
print_u16:
	xor a
	ld (print_u16_started),a
	ld bc,#-10000
	call print_u16_digit
	ld bc,#-1000
	call print_u16_digit
	ld bc,#-100
	call print_u16_digit
	ld bc,#-10
	call print_u16_digit
	ld a,l
	add a,#'0'
	jp putc

; Inputs: HL = the running remainder, BC = the negated place value.
; Output: one digit emitted unless it is a leading zero; HL reduced.
print_u16_digit:
	ld a,#('0' - 1)
print_u16_count:
	inc a
	add hl,bc
	jr c,print_u16_count
	sbc hl,bc			; CF is clear here, so this undoes the last add
	cp #'0'
	jr nz,print_u16_emit
	ld d,a
	ld a,(print_u16_started)
	or a
	ld a,d
	ret z
print_u16_emit:
	ld d,a
	ld a,#1
	ld (print_u16_started),a
	ld a,d
	jp putc

; Inputs: A = the character to write. Preserves BC, DE and HL.
; May block in BDOS.
putc:
	push bc
	push de
	push hl
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop de
	pop bc
	ret

pat_magic:
	.ascii "CGP1"

msg_scan_prefix:
	.ascii "Cartridge scan: $"
msg_scan_vdp:
	.ascii " VDP and $"
msg_scan_sound:
	.ascii " sound operand(s) adapted, $"
msg_scan_indirect:
	.ascii " indirect OUT (C)/IN (C) site(s) left unpatched.\r\n$"
msg_scan_no_header:
	.ascii "Cartridge has no AA55h header; the I/O scan was skipped.\r\n$"
msg_scan_overflow:
	.ascii "Warning: the trace worklist overflowed; scan coverage is partial.\r\n$"
msg_pat_applied:
	.ascii "Patch manifest: $"
msg_pat_entries:
	.ascii " entry(s) applied.\r\n$"
msg_pat_size:
	.ascii "Error: the PAT manifest is empty or too large.\r\n$"
msg_pat_open:
	.ascii "Error: cannot reopen the PAT manifest.\r\n$"
msg_pat_close:
	.ascii "Error: cannot close the PAT manifest.\r\n$"
msg_pat_read:
	.ascii "Error: failed while reading the PAT manifest.\r\n$"
msg_pat_format:
	.ascii "Error: the PAT manifest is malformed.\r\n$"
msg_pat_rom:
	.ascii "Error: the PAT manifest targets a different cartridge image.\r\n$"
msg_pat_range:
	.ascii "Error: a PAT entry lies outside the cartridge image.\r\n$"
msg_pat_expect:
	.ascii "Error: a PAT entry does not match the cartridge; nothing applied.\r\n$"
