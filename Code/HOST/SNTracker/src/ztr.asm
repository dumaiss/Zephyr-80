; ZTR file loading and structural validation.

; ztr_load -- load the default CP/M FCB into the fixed 6000h song buffer.
;   Output: carry set on missing name, open/read failure, or invalid first page.
;   Clobbers: AF, BC, DE, HL. May block on CP/M disk I/O. Emits no PSG traffic.
;   Not ISR-safe.
ztr_load:
	call ztr_prepare_fcb
	ret c
	ld de,#file_fcb
	ld c,#BDOS_OPEN
	call BDOS
	inc a
	jr z,ztr_load_failed

	ld de,#SONG_BUFFER
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#file_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	or a
	jr nz,ztr_load_close_failed
	call ztr_validate_first_record
	jr c,ztr_load_close_failed

	; records = ceil(file_size / 128). The 20 KiB buffer needs at most 160.
	ld hl,(SONG_BUFFER + ZH_FILE_SIZE)
	ld de,#127
	add hl,de
	ld b,#7
ztr_load_shift_records:
	srl h
	rr l
	djnz ztr_load_shift_records
	ld a,l
	dec a				; first record is already resident
	ld (song_records_left),a
	ld hl,#(SONG_BUFFER + 128)
	ld (song_dma_ptr),hl

ztr_load_record_loop:
	ld a,(song_records_left)
	or a
	jr z,ztr_load_complete
	ld de,(song_dma_ptr)
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#file_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	or a
	jr nz,ztr_load_close_failed
	ld hl,(song_dma_ptr)
	ld de,#128
	add hl,de
	ld (song_dma_ptr),hl
	ld a,(song_records_left)
	dec a
	ld (song_records_left),a
	jr ztr_load_record_loop

ztr_load_complete:
	ld de,#file_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	or a				; clear carry
	ret

ztr_load_close_failed:
	ld de,#file_fcb
	ld c,#BDOS_CLOSE
	call BDOS
ztr_load_failed:
	scf
	ret

ztr_prepare_fcb:
	ld a,(DEFAULT_FCB + 1)
	cp #' '
	jr z,ztr_prepare_missing
	ld hl,#DEFAULT_FCB
	ld de,#file_fcb
	ld bc,#FCB_BYTES
	ldir
	xor a
	ld hl,#(file_fcb + FCB_RUNTIME)
	ld b,#(FCB_BYTES - FCB_RUNTIME)
ztr_prepare_clear:
	ld (hl),a
	inc hl
	djnz ztr_prepare_clear
	or a
	ret
ztr_prepare_missing:
	scf
	ret

ztr_validate_first_record:
	ld hl,#SONG_BUFFER
	ld de,#ztr_magic
	ld b,#4
ztr_validate_magic_loop:
	ld a,(de)
	cp (hl)
	jr nz,ztr_validate_first_failed
	inc de
	inc hl
	djnz ztr_validate_magic_loop
	ld a,(SONG_BUFFER + ZH_VERSION)
	cp #ZTR_VERSION
	jr nz,ztr_validate_first_failed
	ld a,(SONG_BUFFER + ZH_HEADER_SIZE)
	cp #ZTR_HEADER_BYTES
	jr nz,ztr_validate_first_failed
	ld a,(SONG_BUFFER + ZH_FLAGS)
	or a
	jr nz,ztr_validate_first_failed
	ld a,(SONG_BUFFER + ZH_CHANNELS)
	cp #ZTR_CHANNELS
	jr nz,ztr_validate_first_failed

	ld hl,(SONG_BUFFER + ZH_FILE_SIZE)
	ld a,h
	or a
	jr z,ztr_validate_first_failed	; a valid file is at least one record here
	ld de,#SONG_BUFFER_BYTES
	or a
	sbc hl,de
	jr c,ztr_validate_first_ok
	jr z,ztr_validate_first_ok
ztr_validate_first_failed:
	scf
	ret
ztr_validate_first_ok:
	or a
	ret

; ztr_init -- validate loaded ZTR structures and publish runtime pointers.
;   Output: carry set for an unsupported or malformed ZTR file.
;   Clobbers: AF, BC, DE, HL. Does not block or emit PSG traffic.
;   Not ISR-safe; call before enabling playback interrupts.
ztr_init:
	call ztr_validate_first_record
	jp c,ztr_init_failed

	ld a,(SONG_BUFFER + ZH_TICK_RATE + 1)
	or a
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_TICK_RATE)
	or a
	jp z,ztr_init_failed
	cp #(CTC_BASE_RATE + 1)
	jp nc,ztr_init_failed
	ld (tick_rate),a

	ld a,(SONG_BUFFER + ZH_SPEED)
	or a
	jp z,ztr_init_failed
	ld (song_speed),a
	ld a,(SONG_BUFFER + ZH_SOURCE_CHANNELS)
	or a
	jp z,ztr_init_failed
	cp #(ZTR_CHANNELS + 1)
	jp nc,ztr_init_failed

	ld a,(SONG_BUFFER + ZH_PATTERN_LENGTH)
	ld (pattern_length_lo),a
	ld a,(SONG_BUFFER + ZH_PATTERN_LENGTH + 1)
	ld (pattern_length_hi),a
	cp #1
	jr c,ztr_init_pattern_small
	jp nz,ztr_init_failed
	ld a,(pattern_length_lo)
	or a
	jp nz,ztr_init_failed		; only 0100h is accepted above 255
	jr ztr_init_pattern_ok
ztr_init_pattern_small:
	ld a,(pattern_length_lo)
	or a
	jp z,ztr_init_failed
ztr_init_pattern_ok:

	ld a,(SONG_BUFFER + ZH_ORDER_COUNT + 1)
	or a
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_ORDER_COUNT)
	or a
	jp z,ztr_init_failed
	ld (order_count),a
	ld hl,(SONG_BUFFER + ZH_PATTERN_COUNT)
	ld (pattern_count),hl
	ld a,(SONG_BUFFER + ZH_INSTRUMENT_COUNT + 1)
	or a
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_INSTRUMENT_COUNT)
	cp #(ZTR_CHANNELS + 1)
	jp nc,ztr_init_failed
	ld (instrument_count),a

	ld a,(SONG_BUFFER + ZH_PSG_CLOCK)
	cp #0x99
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_PSG_CLOCK + 1)
	cp #0x9e
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_PSG_CLOCK + 2)
	cp #0x36
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_PSG_CLOCK + 3)
	or a
	jp nz,ztr_init_failed

	ld a,(SONG_BUFFER + ZH_ORDER_BYTES)
	cp #ZTR_CHANNELS
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_INSTRUMENT_BYTES)
	cp #ZTR_INSTRUMENT_BYTES
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_PATTERN_BYTES)
	cp #ZTR_PATTERN_BYTES
	jp nz,ztr_init_failed
	ld a,(SONG_BUFFER + ZH_NOTE_COUNT)
	cp #ZTR_NOTE_COUNT
	jp nz,ztr_init_failed

	; Exact fixed-size sections make malformed counts fail before playback.
	ld hl,(SONG_BUFFER + ZH_ORDER_COUNT)
	ld h,l
	ld l,#0
	srl h
	rr l				; low-byte count * 128
	srl h
	rr l				; * 64
	srl h
	rr l				; * 32
	srl h
	rr l				; * 16
	ld de,(SONG_BUFFER + ZH_ORDER_OFFSET)
	add hl,de
	ld de,(SONG_BUFFER + ZH_INSTRUMENT_OFFSET)
	or a
	sbc hl,de
	jp nz,ztr_init_failed

	ld hl,(SONG_BUFFER + ZH_INSTRUMENT_COUNT)
	ld h,l
	ld l,#0
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l				; instrument count * 16
	ld de,(SONG_BUFFER + ZH_INSTRUMENT_OFFSET)
	add hl,de
	ld de,(SONG_BUFFER + ZH_MACRO_OFFSET)
	or a
	sbc hl,de
	jp nz,ztr_init_failed

	ld hl,(SONG_BUFFER + ZH_PATTERN_COUNT)
	add hl,hl
	add hl,hl
	add hl,hl			; pattern count * 8
	ld de,(SONG_BUFFER + ZH_PATTERN_DIR_OFFSET)
	add hl,de
	ld de,(SONG_BUFFER + ZH_PATTERN_DATA_OFFSET)
	or a
	sbc hl,de
	jp nz,ztr_init_failed

	ld hl,(SONG_BUFFER + ZH_NOTE_TABLE_OFFSET)
	ld de,#(ZTR_NOTE_COUNT * 2)
	add hl,de
	ld de,(SONG_BUFFER + ZH_FILE_SIZE)
	or a
	sbc hl,de
	jp nz,ztr_init_failed

	ld hl,#(SONG_BUFFER + ZH_ORDER_OFFSET)
	call ztr_resolve_word
	ld (order_base),hl
	ld hl,#(SONG_BUFFER + ZH_INSTRUMENT_OFFSET)
	call ztr_resolve_word
	ld (instrument_base),hl
	ld hl,#(SONG_BUFFER + ZH_PATTERN_DIR_OFFSET)
	call ztr_resolve_word
	ld (pattern_dir_base),hl
	ld hl,#(SONG_BUFFER + ZH_NOTE_TABLE_OFFSET)
	call ztr_resolve_word
	ld (note_table_base),hl
	ld hl,#(SONG_BUFFER + ZH_TITLE_OFFSET)
	call ztr_resolve_word
	ld (title_ptr),hl

	; Poll CP/M console status once per second, never from the ISR. A tracker
	; heartbeat does not need a hot input loop, and this keeps the active BIOS
	; console/IOC path out of the timing-critical foreground as much as possible.
	ld a,(tick_rate)
	ld (key_poll_reload),a
	ld (key_poll_count),a
	xor a
	ld (ctc_active),a
	ld (aborted),a
	ld (ticks_pending),a
	ld (unexpected_interrupts),a
	or a
	ret
ztr_init_failed:
	scf
	ret

; Resolve a little-endian file offset at HL into a memory pointer in HL.
ztr_resolve_word:
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	ld de,#SONG_BUFFER
	add hl,de
	ret
