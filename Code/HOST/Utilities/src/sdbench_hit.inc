; STORAGE_PROFILE temporary experiment. Removal: docs/storage-profiling.md.
; Full CALL 5 / fn20 path, never a direct BIOS call. Requires B: default drive
; and a B: file >=512 bytes. All output, OPEN, DMA setup and warm-up precede
; the aggregate bracket. Allocation bytes 16..31 are never rewritten here.
HH_LAPS = 1024                  ; 4096 records, 512 KiB logical delivery

bench_hit:
	ld c,#BDOS_CURDSK
	call BDOS
	cp #1
	jp nz,hh_wrong_drive
	ld a,(FCB1)
	or a
	jr z,hh_drive_ok
	cp #2
	jp nz,hh_wrong_drive
hh_drive_ok:
	; Version 2 extends SYSINFO; old BIOS must not be read past its end.
	ld c,#ZB_SYSINFO
	call BDOS
	ld a,(hl)
	cp #2
	jp c,hh_old_bios
	ld de,#ZB_SYSINFO_STORAGE_PROFILE
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (hh_xport_ptr),de
	call zb_diag_iy
	push iy
	pop hl
	ld de,#12                      ; existing saturating deblock counters
	add hl,de
	ld (hh_cache_ptr),hl
	call fb_make_fcb
	ld de,#fb_fcb
	ld c,#BDOS_OPEN
	call BDOS
	inc a
	jp z,fb_no_file
	; Current ZSDOS READS uses CR, EX and the OPEN allocation map. WRITS7
	; increments CR; CR=128 opens another extent. We only use CR=0..3.
	; Save S2 including its unmodified bit; restore exactly, never zero it.
	ld a,(fb_fcb + 12)
	ld (hh_ex),a
	ld a,(fb_fcb + 14)
	ld (hh_s2),a
	ld a,(fb_fcb + 32)
	ld (hh_cr),a
	ld de,#io_buf
	ld c,#BDOS_DMA
	call BDOS
	ld de,#hh_msg_start
	call puts
	call hh_read_four               ; warm line, outside bracket
	or a
	jr nz,hh_warm_failed
	call tk_start
	or a
	jr nz,hh_clock_failed
	call hh_run
	call hh_validate
	ld (hh_invalid),a
	ld de,#fb_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	call hh_report
	jp finish
hh_clock_failed:
	push af
	ld de,#fb_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	pop af
	jp fb_no_timer
hh_warm_failed:
	ld de,#fb_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	ld de,#hh_msg_warm
	jr hh_fail
hh_wrong_drive:
	ld de,#hh_msg_drive
	jr hh_fail
hh_old_bios:
	ld de,#hh_msg_bios
hh_fail:
	call puts
	jp finish

; Silent aggregate region. tk_read once per LAP extends the polled timer:
; this is not individual-record timing. Each lap must stay under the ~104 ms
; alias-free ceiling.
; Includes rewind, loop bookkeeping and timer sampling in elapsed cost.
hh_run:
	ld hl,#0
	ld (hh_attempts),hl
	ld (hh_success),hl
	ld hl,#HH_LAPS
	ld (hh_left),hl
	ld de,#hh_before
	call hh_snapshot
	call tk_read
	ld hl,#hh_start
	call n_store_acc
hh_lap:
	call hh_rewind
	call hh_read_four
	push af
	call tk_read
	pop af
	or a
	jr nz,hh_end
	ld hl,(hh_left)
	dec hl
	ld (hh_left),hl
	ld a,h
	or l
	jr nz,hh_lap
hh_end:
	ld hl,#hh_start
	call n_load_arg
	call n_sub
	ld hl,#hh_ticks
	call n_store_acc
	call tk_stop
	ld de,#hh_after
	jp hh_snapshot

hh_rewind:
	ld a,(hh_ex)
	ld (fb_fcb + 12),a
	ld a,(hh_s2)
	ld (fb_fcb + 14),a
	ld a,(hh_cr)
	ld (fb_fcb + 32),a
	ret

hh_read_four:
	ld a,#4
	ld (hh_quarters),a
hh_record:
	ld hl,(hh_attempts)
	inc hl
	ld (hh_attempts),hl
	ld de,#fb_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	or a
	ret nz
	ld hl,(hh_success)
	inc hl
	ld (hh_success),hl
	ld hl,#hh_quarters
	dec (hl)
	jr nz,hh_record
	xor a
	ret

; No BDOS calls: DE -> eight-byte snapshot, safe common-memory pointers.
hh_snapshot:
	ld hl,(hh_cache_ptr)
	ld bc,#4
	ldir
	ld hl,(hh_xport_ptr)
	ld bc,#4
	ldir
	ret

; Produces four uint16 deltas. Reject saturation (including preexisting FFFF),
; partial runs, misses, unexpected hits and either transport entry count.
; Modulo transport deltas are unambiguous for this bounded 4096-read test.
hh_validate:
	ld hl,#hh_after
	ld de,#hh_before
	ld ix,#hh_delta
	ld b,#4
hh_delta_loop:
	push bc
	push hl
	ld c,(hl)
	inc hl
	ld b,(hl)
	ex de,hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	push hl
	ld h,b
	ld l,c
	or a
	sbc hl,de
	ld 0(ix),l
	ld 1(ix),h
	inc ix
	inc ix
	pop de
	pop hl
	inc hl
	inc hl
	pop bc
	djnz hh_delta_loop
	ld hl,#hh_before
	call hh_unsaturated
	jr nz,hh_bad
	ld hl,#hh_after
	call hh_unsaturated
	jr nz,hh_bad
	ld hl,(hh_success)
	ld de,#HH_LAPS * 4
	or a
	sbc hl,de
	jr nz,hh_bad
	ld hl,(hh_attempts)
	or a
	sbc hl,de
	jr nz,hh_bad
	ld hl,(hh_delta)
	or a
	sbc hl,de
	jr nz,hh_bad
	ld hl,#hh_delta + 2
	ld b,#6
	xor a
hh_zero_deltas:
	or (hl)
	inc hl
	djnz hh_zero_deltas
	ret
hh_bad:
	ld a,#1
	ret
hh_unsaturated:
	ld b,#2
hh_sat_loop:
	ld a,(hl)
	inc hl
	and (hl)
	inc hl
	cp #0xff
	jr z,hh_bad
	djnz hh_sat_loop
	xor a
	ret

hh_report:
	ld de,#hh_msg_valid
	ld a,(hh_invalid)
	or a
	jr z,hh_label
	ld de,#hh_msg_invalid
hh_label:
	call puts
	ld de,#hh_msg_attempts
	call puts
	ld hl,(hh_attempts)
	call print_dec_word
	ld de,#hh_msg_success
	call puts
	ld hl,(hh_success)
	call print_dec_word
	ld de,#hh_msg_bytes
	call puts
	ld hl,(hh_success)
	call n_acc_from_hl
	ld bc,#128
	call n_mul16
	call print_dec32
	ld a,(no_timer)
	or a
	jr nz,hh_no_time
	ld de,#hh_msg_elapsed
	call puts
	ld hl,#hh_ticks
	call n_load_acc
	call msx100_from_ticks
	ld hl,#hh_ms100
	call n_store_acc
	call print_x100
	ld de,#hh_msg_per
	call puts
	ld hl,#hh_ms100
	call n_load_acc
	ld bc,(hh_success)
	ld a,b
	or c
	jr z,hh_no_average
	call n_div16
hh_no_average:
	call print_x100
	ld de,#hh_msg_ms
	call puts
	jr hh_counts
hh_no_time:
	ld de,#msg_timer_off
	call puts
hh_counts:
	ld de,#hh_msg_hits
	call puts
	ld hl,(hh_delta)
	call print_dec_word
	ld de,#hh_msg_misses
	call puts
	ld hl,(hh_delta + 2)
	call print_dec_word
	ld de,#hh_msg_call
	call puts
	ld hl,(hh_delta + 4)
	call print_dec_word
	ld de,#hh_msg_bulk
	call puts
	ld hl,(hh_delta + 6)
	call print_dec_word
	jp crlf

hh_msg_start: .ascii "Warming four records; then 1024 silent laps...\r\n$"
hh_msg_drive: .ascii "/H requires B: prompt and FILE or B:FILE.\r\n$"
hh_msg_bios: .ascii "/H needs SYSINFO v2 storage counters.\r\n$"
hh_msg_warm: .ascii "Warm-up failed: need a readable file >=512 bytes.\r\n$"
hh_msg_valid: .ascii "HOST BDOS HIT-ONLY (counter checks passed)\r\n$"
hh_msg_invalid: .ascii "INVALID: hit-only checks failed (or counters saturated).\r\n$"
hh_msg_attempts: .ascii "  records attempted: $"
hh_msg_success: .ascii "  successful: $"
hh_msg_bytes: .ascii "\r\n  bytes delivered: $"
hh_msg_elapsed: .ascii "\r\n  elapsed: $"
hh_msg_per: .ascii " ms; average: $"
hh_msg_ms: .ascii " ms/record\r\n$"
hh_msg_hits: .ascii "  deblock hits: $"
hh_msg_misses: .ascii "  misses: $"
hh_msg_call: .ascii "\r\n  IOCALL delta: $"
hh_msg_bulk: .ascii "  IOCBULK delta: $"
hh_before: .ds 8
hh_after: .ds 8
hh_delta: .ds 8
hh_cache_ptr: .ds 2
hh_xport_ptr: .ds 2
hh_start: .ds 4
hh_ticks: .ds 4
hh_ms100: .ds 4
hh_left: .ds 2
hh_attempts: .ds 2
hh_success: .ds 2
hh_ex: .ds 1
hh_s2: .ds 1
hh_cr: .ds 1
hh_quarters: .ds 1
hh_invalid: .ds 1
