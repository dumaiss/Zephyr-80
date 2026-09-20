; STORAGE_PROFILE temporary experiment. Removal: docs/storage-profiling.md.
; /S /P: reset + baseline before each pass; final snapshot before any report.
; Page 2 format mirrors IOC_OFF_SDPROF_* in MCU include/ioc_frame.h.
SP_PAGE = 2
SP_LEN = 16
SP_VERSION = 1

sp_begin:
	ld a,(sp_enabled)
	or a
	ret z
	ld a,#PROFILE_RESET
	call sp_request
	or a
	ret nz
	ld hl,#rx_frame + 14
	ld de,#sp_base
	ld bc,#6
	ldir
	xor a
	ret
sp_end:
	ld a,(sp_enabled)
	or a
	ret z
	xor a
	call sp_request
	or a
	ret nz
	ld hl,#rx_frame + 4
	ld de,#sp_reply
	ld bc,#SP_LEN
	ldir
	xor a
	ret

; A=control. Deferred MCU reset occurs AFTER the reset reply, so the returned
; operational counters are the baseline; new calls/ticks start at zero before
; the next command is admitted. No resetting of cache/retry/reinit counters.
sp_request:
	push af
	call zero_frames
	pop af
	ld (tx_frame + 4),a
	ld a,#SP_PAGE
	ld (tx_frame + 5),a
	ld a,#2
	ld (tx_frame + 3),a
	ld a,#CMD_PROFILE
	ld (tx_frame),a
	ld a,#0x70
	ld (fs_stage),a
	ld a,#RSP_PROFILE
	call fs_xact
	or a
	ret nz
	call sp_decode
	ret z
	ld a,#0x74
	jp set_failure

; Reject old firmware's default-page fallback and malformed page lengths.
; fs_xact already checked class/status. No field access before this check.
sp_decode:
	ld a,(rx_frame + 3)
	cp #SP_LEN
	jr nz,sp_bad_page
	ld a,(rx_frame + 4)
	cp #SP_VERSION
	jr nz,sp_bad_page
	xor a
	ret
sp_bad_page:
	ld (fail_info),a
	ld a,#1
	ret

sp_report:
	ld a,(sp_enabled)
	or a
	ret z
	ld de,#sp_msg_calls
	call puts
	ld hl,#sp_reply + 2
	call n_load_acc
	call print_dec32
	ld de,#sp_msg_ticks
	call puts
	ld hl,#sp_reply + 6
	call n_load_acc
	call print_dec32
	ld de,#sp_msg_time
	call puts
	ld hl,#sp_reply + 6
	call n_load_acc
	ld bc,#31
	call n_div16
	ld hl,#sp_ms
	call n_store_acc
	call print_dec32
	ld de,#sp_msg_avg
	call puts
	ld hl,#sp_reply + 2
	call n_load_acc
	call n_acc_is_zero
	jr z,sp_average
	ld hl,#sp_reply + 2
	call n_load_div
	ld hl,#sp_reply + 6
	call n_load_acc
	call n_div32
sp_average:
	call print_dec32
	ld de,#sp_msg_tick_units
	call puts
	ld de,#sp_msg_misses
	call puts
	ld hl,(sp_reply + 10)
	ld de,(sp_base)
	or a
	sbc hl,de
	call print_dec_word
	ld de,#sp_msg_retries
	call puts
	ld hl,(sp_reply + 12)
	ld de,(sp_base + 2)
	or a
	sbc hl,de
	call print_dec_word
	ld de,#sp_msg_reinits
	call puts
	ld hl,(sp_reply + 14)
	ld de,(sp_base + 4)
	or a
	sbc hl,de
	call print_dec_word
	call crlf
	; A recovery can exceed Timer3's wrap interval. Saturated operational
	; counters cannot prove absence of recovery either. Suppress ratio then.
	ld a,(sp_reply + 1)
	or a
	jr nz,sp_suspect
	ld hl,#sp_base + 2
	call hh_unsaturated
	jr nz,sp_suspect
	ld hl,#sp_reply + 12
	call hh_unsaturated
	jr nz,sp_suspect
	ld hl,#p_ms
	call n_load_acc
	call n_acc_is_zero
	ret z
	ld hl,#p_ms
	call n_load_div
	ld hl,#sp_ms
	call n_load_acc
	ld bc,#100
	call n_mul16
	call n_div32
	ld hl,#sp_ratio
	call n_store_acc
	ld de,#sp_msg_ratio
	call puts
	ld hl,#sp_ratio
	call n_load_acc
	call print_dec32
	ld de,#sp_msg_percent
	jp puts
sp_suspect:
	ld de,#sp_msg_suspect
	jp puts

sp_msg_calls: .ascii "  Physical SD read calls: $"
sp_msg_ticks: .ascii "\r\n  Physical SD read ticks: $"
sp_msg_time: .ascii "\r\n  Physical SD read time: $"
sp_msg_avg: .ascii " ms (nominal); average: $"
sp_msg_tick_units: .ascii " ticks/read (31000 Hz nominal)\r\n$"
sp_msg_misses: .ascii "  SD cache misses: $"
sp_msg_retries: .ascii "  read retries: $"
sp_msg_reinits: .ascii "  reinits: $"
sp_msg_ratio: .ascii "  Physical / measured I/O time: $"
sp_msg_percent: .ascii "% (nominal)\r\n$"
sp_msg_suspect: .ascii "  WARNING: recovery/error or saturated counters; SD timing suspect.\r\n$"
sp_enabled: .ds 1
sp_base: .ds 6
sp_reply: .ds SP_LEN
sp_ms: .ds 4
sp_ratio: .ds 4

; /P requires /S and a filename. /H requires a filename and forbids /S /C /P.
sp_parse_options:
	xor a
	ld (sp_enabled),a
	ld a,#'P'
	call opt_find
	jr c,sp_parse_h
	ld a,(mode)
	cp #2
	jr nz,sp_options_bad
	ld a,#1
	ld (sp_enabled),a
sp_parse_h:
	ld a,#'H'
	call opt_find
	jr c,sp_options_ok
	ld a,(mode)
	cp #1
	jr nz,sp_options_bad
	ld a,(fs_cached)
	or a
	jr nz,sp_options_bad
	ld a,#3
	ld (mode),a
sp_options_ok:
	xor a
	ret
sp_options_bad:
	ld de,#sp_msg_options
	call puts
	ld a,#1
	ret
sp_msg_options: .ascii "Use FILE /S [/C] [/P] or FILE /H; /N disables timing.\r\n$"
