; ZTR row decoder, macro state and foreground playback engine.

; ztr_play -- reset runtime state and start at order 0, row 0, tick 0.
;   Clobbers: AF, BC, DE, HL, IX. Emits mute traffic, then returns.
;   Does not block for timing and is not ISR-safe.
ztr_play:
	ld hl,#channel_state
	ld de,#(channel_state + 1)
	ld bc,#(ZTR_CHANNELS * CHANNEL_STATE_BYTES - 1)
	xor a
	ld (hl),a
	ldir

	xor a
	ld (current_channel),a
ztr_play_channel_init:
	call get_channel_ix
	ld a,#0xff
	ld CH_NOTE(ix),a
	ld CH_INSTRUMENT(ix),a
	ld CH_LAST_ATTENUATION(ix),a
	ld CH_LAST_NOISE(ix),a
	ld a,#15
	ld CH_BASE_VOLUME(ix),a
	ld CH_MACRO_VOLUME(ix),a
	ld a,#(DIRTY_PITCH | DIRTY_VOLUME | DIRTY_NOISE | DIRTY_PHASE)
	ld CH_DIRTY(ix),a
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,ztr_play_channel_init

	xor a
	ld (current_order),a
	ld (current_row),a
	ld (tick_in_row),a
	ld (ui_page),a
	ld (aborted),a
	ld (ticks_pending),a
	ld (elapsed_subticks),a
	ld (elapsed_seconds),a
	ld (elapsed_minutes),a
	ld hl,(order_base)
	ld (current_order_ptr),hl
	call player_setup_order
	call sn_mute_all
	ld a,#1
	ld (playing),a
	ld (row_changed),a
	ret

; ztr_stop -- stop and silence all four physical PSGs.
;   Clobbers: AF, BC, DE. May block briefly while muting. Emits PSG traffic.
;   Not ISR-safe.
ztr_stop:
	xor a
	ld (playing),a
	jp sn_mute_all

; ztr_tick -- process one song-rate tick in foreground context.
; Tick zero decodes a row; later ticks advance its effects and all ticks advance
; instrument macros. Dirty PSG state is flushed once at the end.
;   Clobbers: AF, BC, DE, HL, IX. May emit PSG traffic. Not ISR-safe.
ztr_tick:
	ld a,(playing)
	or a
	ret z
	ld a,(tick_in_row)
	or a
	call z,player_begin_row
	ld a,(playing)
	or a
	ret z
	call player_advance_effects
	call player_advance_macros
	call sn_render_all
	call player_advance_clock

	ld a,(tick_in_row)
	inc a
	ld (tick_in_row),a
	ld hl,#song_speed
	cp (hl)
	ret c
	xor a
	ld (tick_in_row),a
	jp player_advance_position

; Advance the UI clock once per song tick. Display refreshes are requested only
; at order boundaries so console traffic cannot dominate foreground playback.
player_advance_clock:
	ld a,(elapsed_subticks)
	inc a
	ld (elapsed_subticks),a
	ld hl,#tick_rate
	cp (hl)
	ret c
	xor a
	ld (elapsed_subticks),a
	ld a,(elapsed_seconds)
	inc a
	cp #60
	jr c,player_clock_store_seconds
	xor a
	ld (elapsed_seconds),a
	ld a,(elapsed_minutes)
	inc a
	cp #100
	jr c,player_clock_store_minutes
	xor a
player_clock_store_minutes:
	ld (elapsed_minutes),a
	ret
player_clock_store_seconds:
	ld (elapsed_seconds),a
	ret

; Convert current_channel into IX=&channel_state[channel].
get_channel_ix:
	ld a,(current_channel)
	ld l,a
	ld h,#0
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld de,#channel_state
	add hl,de
	push hl
	pop ix
	ret

player_begin_row:
	xor a
	ld (current_channel),a
player_begin_clear_effects:
	call get_channel_ix
	ld a,CH_EFFECT(ix)
	cp #EFFECT_ARPEGGIO
	jr nz,player_begin_no_old_arp
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
player_begin_no_old_arp:
	xor a
	ld CH_EFFECT(ix),a
	ld CH_EFFECT_PHASE(ix),a
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,player_begin_clear_effects

	xor a
	ld (current_channel),a
player_begin_decode_loop:
	call get_channel_ix
	call player_decode_channel_row
	ld a,(playing)
	or a
	ret z
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,player_begin_decode_loop
	ret

player_decode_channel_row:
	ld l,CH_PATTERN_CURSOR(ix)
	ld h,CH_PATTERN_CURSOR+1(ix)
	ld a,h
	or l
	ret z
	ld e,CH_PATTERN_END(ix)
	ld d,CH_PATTERN_END+1(ix)
	ld a,h
	cp d
	jr c,player_event_cursor_active
	ret nz				; corrupt cursor beyond stream end
	ld a,l
	cp e
	ret nc

player_event_cursor_active:
	ld a,(hl)
	ld b,a
	ld a,(current_row)
	cp b
	ret nz
	inc hl
	ld a,(hl)
	inc hl
	ld (event_mask),a
	ld a,#0xff
	ld (event_note),a
	ld (event_instrument),a
	ld (event_volume),a
	xor a
	ld (event_effect),a
	ld (event_parameter),a
	ld (event_modifier_flags),a
	ld (event_arpeggio),a
	ld (event_hairpin_rate),a
	ld (event_hairpin_ceiling),a

	ld a,(event_mask)
	and #EVENT_NOTE
	jr z,player_event_no_note
	ld a,(hl)
	inc hl
	ld (event_note),a
player_event_no_note:
	ld a,(event_mask)
	and #EVENT_INSTRUMENT
	jr z,player_event_no_instrument
	ld a,(hl)
	inc hl
	ld (event_instrument),a
player_event_no_instrument:
	ld a,(event_mask)
	and #EVENT_VOLUME
	jr z,player_event_no_volume
	ld a,(hl)
	inc hl
	ld (event_volume),a
player_event_no_volume:
	ld a,(event_mask)
	and #EVENT_EFFECT
	jr z,player_event_no_effect
	ld a,(hl)
	inc hl
	ld (event_effect),a
	ld a,(hl)
	inc hl
	ld (event_parameter),a
player_event_no_effect:
	ld a,(event_mask)
	and #EVENT_MODIFIERS
	jr z,player_event_no_modifiers
	ld a,(hl)
	inc hl
	ld (event_modifier_flags),a
	and #MOD_ARP_SET
	jr z,player_event_no_arp_payload
	ld a,(hl)
	inc hl
	ld (event_arpeggio),a
player_event_no_arp_payload:
	ld a,(event_modifier_flags)
	and #MOD_HAIRPIN_SET
	jr z,player_event_no_modifiers
	ld a,(hl)
	inc hl
	ld (event_hairpin_rate),a
	ld a,(hl)
	inc hl
	ld (event_hairpin_ceiling),a
player_event_no_modifiers:
	ld CH_PATTERN_CURSOR(ix),l
	ld CH_PATTERN_CURSOR+1(ix),h

	ld a,(event_mask)
	and #EVENT_MODIFIERS
	call nz,player_process_notation_modifiers

	ld a,(event_instrument)
	cp #0xff
	jr z,player_event_keep_instrument
	ld CH_INSTRUMENT(ix),a
	call player_bind_instrument
player_event_keep_instrument:
	ld a,(event_volume)
	cp #0xff
	jr z,player_event_keep_volume
	and #0x0f
	ld b,a
	ld a,CH_BASE_VOLUME(ix)
	cp b
	jr z,player_event_keep_volume
	ld a,b
	ld CH_BASE_VOLUME(ix),a
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
player_event_keep_volume:
	ld a,(event_effect)
	or a
	call nz,player_process_effect

	ld a,(event_mask)
	and #EVENT_OFF
	jr z,player_event_not_off
	call player_note_off
	ret
player_event_not_off:
	ld a,(event_mask)
	and #EVENT_RELEASE
	jr z,player_event_not_release
	call player_note_release
	ret
player_event_not_release:
	ld a,(event_note)
	cp #0xff
	ret z
	ld b,a
	ld a,(event_mask)
	and #EVENT_LEGATO
	ld a,b
	jp nz,player_note_legato
	jp player_note_on

; Apply persistent CSM notation modes. These are independent of the legacy
; Furnace effect column so a note can carry articulation and dynamics together.
;   Input: IX points at the current channel; event_* contains decoded payload.
;   Output: persistent mode state updated. Clobbers AF.
;   Foreground-only; does not block or emit PSG/Virtual Drip traffic.
player_process_notation_modifiers:
	ld a,(event_modifier_flags)
	and #MOD_RESET
	call nz,player_clear_notation_modes

	ld a,(event_modifier_flags)
	and #MOD_ARP_CLEAR
	jr z,player_notation_arp_set_check
	ld a,CH_FLAGS(ix)
	and #0xf7
	ld CH_FLAGS(ix),a
	xor a
	ld CH_NOTATION_ARP_PHASE(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
player_notation_arp_set_check:
	ld a,(event_modifier_flags)
	and #MOD_ARP_SET
	jr z,player_notation_hairpin_clear_check
	ld a,(event_arpeggio)
	ld CH_NOTATION_ARP_PARAM(ix),a
	ld a,#2			; tick advance below makes the starting phase root
	ld CH_NOTATION_ARP_PHASE(ix),a
	ld a,CH_FLAGS(ix)
	or #CHANNEL_NOTATION_ARP
	ld CH_FLAGS(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
player_notation_hairpin_clear_check:
	ld a,(event_modifier_flags)
	and #MOD_HAIRPIN_CLEAR
	jr z,player_notation_hairpin_set_check
	xor a
	ld CH_HAIRPIN_RATE(ix),a
player_notation_hairpin_set_check:
	ld a,(event_modifier_flags)
	and #MOD_HAIRPIN_SET
	ret z
	ld a,(event_hairpin_rate)
	ld CH_HAIRPIN_RATE(ix),a
	ld a,(event_hairpin_ceiling)
	ld CH_HAIRPIN_CEILING(ix),a
	ret

; Clear only persistent notation state. Legacy tracker effect state retains its
; existing row-local behavior.
;   Input: IX points at a channel. Output: notation modes cleared.
;   Clobbers AF. Foreground-only; does not block or emit traffic.
player_clear_notation_modes:
	ld a,CH_FLAGS(ix)
	and #0xf7
	ld CH_FLAGS(ix),a
	xor a
	ld CH_NOTATION_ARP_PARAM(ix),a
	ld CH_NOTATION_ARP_PHASE(ix),a
	ld CH_HAIRPIN_RATE(ix),a
	ld CH_HAIRPIN_OFFSET(ix),a
	ld CH_HAIRPIN_CEILING(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_VOLUME | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	ret

player_process_effect:
	ld a,(event_effect)
	cp #EFFECT_ARPEGGIO
	jr z,player_effect_set_active
	cp #EFFECT_VOL_SLIDE
	jr z,player_effect_set_active
	cp #EFFECT_FAST_VOL
	jr z,player_effect_set_active
	cp #EFFECT_LEGATO
	jr z,player_effect_legato
	cp #EFFECT_VOL_DEC
	jr z,player_effect_one_tick_down
	cp #EFFECT_STOP
	jp z,ztr_stop
	ret
player_effect_set_active:
	ld CH_EFFECT(ix),a
	ld a,(event_parameter)
	ld CH_EFFECT_PARAM(ix),a
	xor a
	ld CH_EFFECT_PHASE(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	ret
player_effect_legato:
	ld a,(event_parameter)
	or a
	jr z,player_effect_legato_off
	ld a,CH_FLAGS(ix)
	or #CHANNEL_LEGATO
	ld CH_FLAGS(ix),a
	ret
player_effect_legato_off:
	ld a,CH_FLAGS(ix)
	and #0xfb
	ld CH_FLAGS(ix),a
	ret
player_effect_one_tick_down:
	ld a,(event_parameter)
	ld b,a
	ld a,CH_BASE_VOLUME(ix)
	sub b
	jr nc,player_effect_store_volume
	xor a
player_effect_store_volume:
	ld b,a
	ld a,CH_BASE_VOLUME(ix)
	cp b
	ret z
	ld a,b
	ld CH_BASE_VOLUME(ix),a
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
	ret

; player_note_legato -- change pitch without restarting any macro.
;   Input: A is a ZTR note number; IX points at the current channel.
;   Output: pitch/noise marked dirty. Clobbers AF, B and onset-path registers.
;   A malformed inactive-channel event becomes a normal onset. Foreground-only;
;   does not block or directly emit PSG/Virtual Drip traffic.
player_note_legato:
	ld b,a
	ld a,CH_FLAGS(ix)
	and #CHANNEL_ACTIVE
	ld a,b
	jr z,player_note_on
	ld CH_NOTE(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	ret

; A contains a ZTR note number.
player_note_on:
	ld b,a
	ld a,CH_FLAGS(ix)
	and #(CHANNEL_ACTIVE | CHANNEL_LEGATO)
	cp #(CHANNEL_ACTIVE | CHANNEL_LEGATO)
	jr nz,player_note_retrigger
	ld CH_NOTE(ix),b
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	ret
player_note_retrigger:
	ld CH_NOTE(ix),b
	ld a,CH_FLAGS(ix)
	and #CHANNEL_LEGATO
	or #CHANNEL_ACTIVE
	ld CH_FLAGS(ix),a
	ld a,#15
	ld CH_MACRO_VOLUME(ix),a
	xor a
	ld CH_ARP_VALUE(ix),a
	ld CH_ARP_VALUE+1(ix),a
	ld CH_PITCH_VALUE(ix),a
	ld CH_PITCH_VALUE+1(ix),a
	ld CH_DUTY_VALUE(ix),a
	ld CH_PHASE_VALUE(ix),a
	ld CH_ARP_FLAGS(ix),a
	call player_reset_macros
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_VOLUME | DIRTY_NOISE | DIRTY_PHASE)
	ld CH_DIRTY(ix),a
	ret

player_note_off:
	call player_clear_notation_modes
	ld a,CH_FLAGS(ix)
	and #CHANNEL_LEGATO
	ld CH_FLAGS(ix),a
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
	ret

player_note_release:
	ld a,CH_FLAGS(ix)
	or #CHANNEL_RELEASED
	ld CH_FLAGS(ix),a
	jp player_release_macros

player_advance_effects:
	xor a
	ld (current_channel),a
player_effect_tick_loop:
	call get_channel_ix
	ld a,CH_EFFECT(ix)
	cp #EFFECT_ARPEGGIO
	jr z,player_effect_tick_arp
	cp #EFFECT_VOL_SLIDE
	jr z,player_effect_tick_volume
	cp #EFFECT_FAST_VOL
	jr z,player_effect_tick_volume
	jr player_effect_tick_next
player_effect_tick_arp:
	ld a,(tick_in_row)
	or a
	jr z,player_effect_tick_next
	ld a,CH_EFFECT_PHASE(ix)
	inc a
	cp #3
	jr c,player_effect_tick_phase_ok
	xor a
player_effect_tick_phase_ok:
	ld CH_EFFECT_PHASE(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	jr player_effect_tick_next
player_effect_tick_volume:
	ld a,(tick_in_row)
	or a
	jr z,player_effect_tick_next
	ld a,CH_EFFECT_PARAM(ix)
	ld b,a
	and #0xf0
	jr z,player_effect_tick_volume_down
	rrca
	rrca
	rrca
	rrca
	ld b,a
	ld a,CH_EFFECT(ix)
	cp #EFFECT_FAST_VOL
	jr nz,player_effect_tick_volume_up_ready
	ld a,b
	add a,a
	add a,a			; FAxy is four times the 0Axy rate
	ld b,a
player_effect_tick_volume_up_ready:
	ld a,CH_BASE_VOLUME(ix)
	add a,b
	jr c,player_effect_tick_volume_up_limit
	cp #16
	jr c,player_effect_tick_volume_store
player_effect_tick_volume_up_limit:
	ld a,#15
	jr player_effect_tick_volume_store
player_effect_tick_volume_down:
	ld a,b
	and #0x0f
	ld b,a
	ld a,CH_EFFECT(ix)
	cp #EFFECT_FAST_VOL
	jr nz,player_effect_tick_volume_down_ready
	ld a,b
	add a,a
	add a,a			; FAxy is four times the 0Axy rate
	ld b,a
player_effect_tick_volume_down_ready:
	ld a,CH_BASE_VOLUME(ix)
	sub b
	jr nc,player_effect_tick_volume_store
	xor a
player_effect_tick_volume_store:
	ld b,a
	ld a,CH_BASE_VOLUME(ix)
	cp b
	jr z,player_effect_tick_next
	ld a,b
	ld CH_BASE_VOLUME(ix),a
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
player_effect_tick_next:
	call player_advance_notation_modes
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jp nz,player_effect_tick_loop
	ret

; Advance persistent CSM arpeggio and hairpin state once per playback tick.
;   Input: IX points at a channel. Output: mode phase/offset advanced.
;   Clobbers AF, BC. Foreground-only; does not block or emit traffic.
player_advance_notation_modes:
	ld a,CH_FLAGS(ix)
	and #CHANNEL_NOTATION_ARP
	jr z,player_notation_tick_hairpin
	ld a,CH_NOTATION_ARP_PHASE(ix)
	inc a
	cp #3
	jr c,player_notation_tick_arp_store
	xor a
player_notation_tick_arp_store:
	ld CH_NOTATION_ARP_PHASE(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a

player_notation_tick_hairpin:
	ld a,CH_HAIRPIN_RATE(ix)
	or a
	ret z
	ld b,a
	ld c,CH_HAIRPIN_OFFSET(ix)
	bit 7,b
	jr nz,player_notation_tick_hairpin_down
	ld a,c
	add a,b
	bit 7,a
	jr nz,player_notation_tick_hairpin_store
	cp #16
	jr c,player_notation_tick_hairpin_store
	ld a,#15
	jr player_notation_tick_hairpin_store
player_notation_tick_hairpin_down:
	ld a,c
	add a,b
	bit 7,a
	jr z,player_notation_tick_hairpin_store
	cp #0xf1			; -15 in two's complement
	jr nc,player_notation_tick_hairpin_store
	ld a,#0xf1
player_notation_tick_hairpin_store:
	cp c
	ret z
	ld CH_HAIRPIN_OFFSET(ix),a
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
	ret

player_advance_macros:
	xor a
	ld (current_channel),a
player_macro_channel_loop:
	call get_channel_ix
	ld a,CH_FLAGS(ix)
	and #CHANNEL_ACTIVE
	jr z,player_macro_channel_next
	xor a
	call macro_advance
	call c,player_apply_volume_macro
	ld a,#1
	call macro_advance
	call c,player_apply_pitch_macro
	ld a,#2
	call macro_advance
	call c,player_apply_arp_macro
	ld a,#3
	call macro_advance
	call c,player_apply_duty_macro
	ld a,#4
	call macro_advance
	call c,player_apply_phase_macro
player_macro_channel_next:
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,player_macro_channel_loop
	ret

; macro_advance -- advance macro slot A for channel IX.
; Carry is set when macro_value/macro_value_flags contain a new value.
macro_advance:
	ld (macro_slot),a
	add a,a
	add a,#CH_VOL_MACRO
	call macro_ix_address
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (macro_pointer),de
	ld a,d
	or e
	jp z,macro_advance_none

	ld a,(macro_slot)
	add a,#CH_VOL_DELAY
	call macro_ix_address
	ld a,(hl)
	or a
	jr z,macro_advance_delay_done
	dec (hl)
	jr macro_advance_none
macro_advance_delay_done:
	ld a,(macro_slot)
	add a,#CH_VOL_TIMER
	call macro_ix_address
	ld a,(hl)
	or a
	jr z,macro_advance_timer_done
	dec (hl)
	jr macro_advance_none
macro_advance_timer_done:

	ld a,(macro_slot)
	add a,a
	add a,#CH_VOL_POSITION
	call macro_ix_address
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (macro_position),de
	; Keep a damaged channel position from escaping its bounded macro. Valid
	; positions are already unchanged by this call.
	call macro_bound_position

	; Address = macro + 12-byte header + position*3.
	ld hl,(macro_position)
	ld d,h
	ld e,l
	add hl,hl
	add hl,de
	ld de,(macro_pointer)
	add hl,de
	ld de,#12
	add hl,de
	ld a,(hl)
	ld (macro_value_flags),a
	inc hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (macro_value),de

	; Reload the per-step timer as max(step_length-1, 0).
	ld hl,(macro_pointer)
	ld de,#3
	add hl,de
	ld a,(hl)
	or a
	jr z,macro_advance_timer_value
	dec a
macro_advance_timer_value:
	ld b,a
	ld a,(macro_slot)
	add a,#CH_VOL_TIMER
	call macro_ix_address
	ld (hl),b

	ld hl,(macro_position)
	inc hl
	ld (macro_position),hl
	call macro_bound_position
	ld de,(macro_position)
	push de				; macro_ix_address uses DE for the field offset
	ld a,(macro_slot)
	add a,a
	add a,#CH_VOL_POSITION
	call macro_ix_address
	pop de
	ld (hl),e
	inc hl
	ld (hl),d
	scf
	ret
macro_advance_none:
	or a
	ret

; Clamp/loop macro_position according to count, loop, release and channel state.
macro_bound_position:
	ld hl,(macro_pointer)
	ld de,#8
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (macro_release_point),de

	ld a,CH_FLAGS(ix)
	and #CHANNEL_RELEASED
	jr nz,macro_bound_count
	ld a,d
	and e
	inc a
	jr z,macro_bound_count		; FFFFh: no release point
	ld hl,(macro_position)
	or a
	sbc hl,de
	jr c,macro_bound_count
	call macro_load_loop
	ld a,d
	and e
	inc a
	jr nz,macro_bound_store_loop
	ld de,(macro_release_point)
	dec de
	jr macro_bound_store_loop

macro_bound_count:
	ld hl,(macro_pointer)
	ld de,#10
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld hl,(macro_position)
	or a
	sbc hl,de
	ret c
	ld hl,(macro_release_point)
	ld a,h
	and l
	inc a
	jr nz,macro_bound_hold_last	; released release-sequence: do not loop
	call macro_load_loop
	ld a,d
	and e
	inc a
	jr nz,macro_bound_store_loop
macro_bound_hold_last:
	ld hl,(macro_pointer)
	ld de,#10
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	dec de
macro_bound_store_loop:
	ld (macro_position),de
	ret

macro_load_loop:
	ld hl,(macro_pointer)
	ld de,#6
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ret

; Return HL = IX + unsigned A.
macro_ix_address:
	ld e,a
	ld d,#0
	push ix
	pop hl
	add hl,de
	ret

player_apply_volume_macro:
	ld a,(macro_value)
	cp #16
	jr c,player_apply_volume_ok
	ld a,#15
player_apply_volume_ok:
	ld b,a
	ld a,CH_MACRO_VOLUME(ix)
	cp b
	ret z
	ld CH_MACRO_VOLUME(ix),b
	ld a,CH_DIRTY(ix)
	or #DIRTY_VOLUME
	ld CH_DIRTY(ix),a
	ret

player_apply_pitch_macro:
	ld hl,(macro_value)
	ld a,CH_PITCH_VALUE(ix)
	cp l
	jr nz,player_apply_pitch_store
	ld a,CH_PITCH_VALUE+1(ix)
	cp h
	ret z
player_apply_pitch_store:
	ld CH_PITCH_VALUE(ix),l
	ld CH_PITCH_VALUE+1(ix),h
	ld a,CH_DIRTY(ix)
	or #DIRTY_PITCH
	ld CH_DIRTY(ix),a
	ret

player_apply_arp_macro:
	ld hl,(macro_value)
	ld a,CH_ARP_VALUE(ix)
	cp l
	jr nz,player_apply_arp_store
	ld a,CH_ARP_VALUE+1(ix)
	cp h
	jr nz,player_apply_arp_store
	ld a,(macro_value_flags)
	and #1
	ld b,a
	ld a,CH_ARP_FLAGS(ix)
	and #1
	cp b
	ret z
player_apply_arp_store:
	ld CH_ARP_VALUE(ix),l
	ld CH_ARP_VALUE+1(ix),h
	ld a,(macro_value_flags)
	and #1
	ld CH_ARP_FLAGS(ix),a
	ld a,CH_DIRTY(ix)
	or #(DIRTY_PITCH | DIRTY_NOISE)
	ld CH_DIRTY(ix),a
	ret

player_apply_duty_macro:
	ld a,(macro_value)
	and #1
	ld b,a
	ld a,CH_DUTY_VALUE(ix)
	cp b
	ret z
	ld CH_DUTY_VALUE(ix),b
	ld a,CH_DIRTY(ix)
	or #DIRTY_NOISE
	ld CH_DIRTY(ix),a
	ret

player_apply_phase_macro:
	ld a,(macro_value)
	ld CH_PHASE_VALUE(ix),a
	or a
	ret z
	ld a,(current_channel)
	and #3
	cp #3
	ret nz				; SN tone generators have no phase reset command
	ld a,CH_DIRTY(ix)
	or #DIRTY_PHASE
	ld CH_DIRTY(ix),a
	ret

player_reset_macros:
	xor a
	ld b,#5
player_reset_macro_loop:
	push bc
	push af
	call macro_reset_slot
	pop af
	inc a
	pop bc
	djnz player_reset_macro_loop
	ret

macro_reset_slot:
	ld (macro_slot),a
	add a,a
	add a,#CH_VOL_POSITION
	call macro_ix_address
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	ld a,(macro_slot)
	add a,#CH_VOL_TIMER
	call macro_ix_address
	xor a
	ld (hl),a
	ld a,(macro_slot)
	add a,a
	add a,#CH_VOL_MACRO
	call macro_ix_address
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,d
	or e
	jr z,macro_reset_no_delay
	ex de,hl
	ld de,#4
	add hl,de
	ld a,(hl)
	ld b,a
	jr macro_reset_store_delay
macro_reset_no_delay:
	ld b,#0
macro_reset_store_delay:
	ld a,(macro_slot)
	add a,#CH_VOL_DELAY
	call macro_ix_address
	ld (hl),b
	ret

player_release_macros:
	xor a
	ld b,#5
player_release_macro_loop:
	push bc
	push af
	call macro_release_slot
	pop af
	inc a
	pop bc
	djnz player_release_macro_loop
	ret

macro_release_slot:
	ld (macro_slot),a
	add a,a
	add a,#CH_VOL_MACRO
	call macro_ix_address
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,d
	or e
	ret z
	ex de,hl
	inc hl
	inc hl
	bit 0,(hl)
	ret z
	ld de,#6
	add hl,de				; macro + 8, release index
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,d
	and e
	inc a
	ret z
	push de				; macro_ix_address uses DE for the field offset
	ld a,(macro_slot)
	add a,a
	add a,#CH_VOL_POSITION
	call macro_ix_address
	pop de
	ld (hl),e
	inc hl
	ld (hl),d
	ld a,(macro_slot)
	add a,#CH_VOL_TIMER
	call macro_ix_address
	xor a
	ld (hl),a
	ld a,(macro_slot)
	add a,#CH_VOL_DELAY
	call macro_ix_address
	xor a
	ld (hl),a
	ret

; Bind the five optional macros from instrument A to channel IX.
player_bind_instrument:
	ld c,a
	ld a,(instrument_count)
	ld b,a
	ld hl,(instrument_base)
player_bind_find_loop:
	ld a,b
	or a
	jr z,player_bind_not_found
	ld a,(hl)
	cp c
	jr z,player_bind_found
	ld de,#ZTR_INSTRUMENT_BYTES
	add hl,de
	djnz player_bind_find_loop
player_bind_not_found:
	xor a
	ld CH_VOL_MACRO(ix),a
	ld CH_VOL_MACRO+1(ix),a
	ld CH_PITCH_MACRO(ix),a
	ld CH_PITCH_MACRO+1(ix),a
	ld CH_ARP_MACRO(ix),a
	ld CH_ARP_MACRO+1(ix),a
	ld CH_DUTY_MACRO(ix),a
	ld CH_DUTY_MACRO+1(ix),a
	ld CH_PHASE_MACRO(ix),a
	ld CH_PHASE_MACRO+1(ix),a
	ret
player_bind_found:
	ld (instrument_entry_pointer),hl
	ld de,#4
	add hl,de
	call player_resolve_optional
	ld CH_VOL_MACRO(ix),l
	ld CH_VOL_MACRO+1(ix),h
	ld hl,(instrument_entry_pointer)
	ld de,#6
	add hl,de
	call player_resolve_optional
	ld CH_PITCH_MACRO(ix),l
	ld CH_PITCH_MACRO+1(ix),h
	ld hl,(instrument_entry_pointer)
	ld de,#8
	add hl,de
	call player_resolve_optional
	ld CH_ARP_MACRO(ix),l
	ld CH_ARP_MACRO+1(ix),h
	ld hl,(instrument_entry_pointer)
	ld de,#10
	add hl,de
	call player_resolve_optional
	ld CH_DUTY_MACRO(ix),l
	ld CH_DUTY_MACRO+1(ix),h
	ld hl,(instrument_entry_pointer)
	ld de,#12
	add hl,de
	call player_resolve_optional
	ld CH_PHASE_MACRO(ix),l
	ld CH_PHASE_MACRO+1(ix),h
	ret

player_resolve_optional:
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,d
	or e
	jr z,player_resolve_zero
	ex de,hl
	ld de,#SONG_BUFFER
	add hl,de
	ret
player_resolve_zero:
	ld hl,#0
	ret

; Select each channel's stream for current_order_ptr.
player_setup_order:
	xor a
	ld (current_channel),a
player_setup_channel_loop:
	call get_channel_ix
	ld hl,(current_order_ptr)
	ld a,(current_channel)
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	cp #0xff
	jr z,player_setup_empty
	ld (wanted_pattern),a
	ld hl,(pattern_dir_base)
	ld bc,(pattern_count)
player_setup_find_loop:
	ld a,b
	or c
	jr z,player_setup_empty
	ld a,(hl)
	ld e,a
	ld a,(current_channel)
	cp e
	jr nz,player_setup_find_next
	inc hl
	ld a,(hl)
	dec hl
	ld e,a
	ld a,(wanted_pattern)
	cp e
	jr z,player_setup_found
player_setup_find_next:
	ld de,#ZTR_PATTERN_BYTES
	add hl,de
	dec bc
	jr player_setup_find_loop
player_setup_found:
	inc hl
	inc hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	push de
	inc hl
	ld c,(hl)
	inc hl
	ld b,(hl)
	pop hl
	ld de,#SONG_BUFFER
	add hl,de
	ld CH_PATTERN_CURSOR(ix),l
	ld CH_PATTERN_CURSOR+1(ix),h
	add hl,bc
	ld CH_PATTERN_END(ix),l
	ld CH_PATTERN_END+1(ix),h
	jr player_setup_next
player_setup_empty:
	xor a
	ld CH_PATTERN_CURSOR(ix),a
	ld CH_PATTERN_CURSOR+1(ix),a
	ld CH_PATTERN_END(ix),a
	ld CH_PATTERN_END+1(ix),a
player_setup_next:
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,player_setup_channel_loop
	ret

player_advance_position:
	ld a,(current_row)
	inc a
	ld (current_row),a
	ld b,a
	ld a,(pattern_length_hi)
	or a
	jr nz,player_position_256
	ld a,(pattern_length_lo)
	cp b
	ret nz
	jr player_position_next_order
player_position_256:
	ld a,b
	or a
	ret nz
player_position_next_order:
	xor a
	ld (current_row),a
	ld a,(current_order)
	inc a
	ld (current_order),a
	ld b,a
	ld a,(order_count)
	cp b
	jp z,ztr_stop
	ld a,#1
	ld (row_changed),a
	ld hl,(current_order_ptr)
	ld de,#ZTR_CHANNELS
	add hl,de
	ld (current_order_ptr),hl
	jp player_setup_order

; Return effective semitone note in A, clamped to C-0..B-7.
player_effective_note:
	ld a,CH_ARP_FLAGS(ix)
	and #1
	jr z,player_effective_relative
	ld a,CH_ARP_VALUE(ix)
	jr player_effective_tracker_arp
player_effective_relative:
	ld a,CH_NOTE(ix)
	ld b,CH_ARP_VALUE(ix)
	add a,b
	jp m,player_effective_low
player_effective_tracker_arp:
	ld b,a
	ld a,CH_EFFECT(ix)
	cp #EFFECT_ARPEGGIO
	ld a,b
	jr nz,player_effective_notation_arp
	ld b,a
	ld a,CH_EFFECT_PHASE(ix)
	cp #1
	jr z,player_effective_arp_high
	cp #2
	ld a,b
	jr nz,player_effective_notation_arp
	ld a,CH_EFFECT_PARAM(ix)
	and #0x0f
	jr player_effective_add
player_effective_arp_high:
	ld a,CH_EFFECT_PARAM(ix)
	and #0xf0
	rrca
	rrca
	rrca
	rrca
player_effective_add:
	add a,b
player_effective_notation_arp:
	ld b,a
	ld a,CH_FLAGS(ix)
	and #CHANNEL_NOTATION_ARP
	ld a,b
	jr z,player_effective_clamp
	ld b,a
	ld a,CH_NOTATION_ARP_PHASE(ix)
	cp #1
	jr z,player_effective_notation_arp_high
	cp #2
	ld a,b
	jr nz,player_effective_clamp
	ld a,CH_NOTATION_ARP_PARAM(ix)
	and #0x0f
	jr player_effective_notation_add
player_effective_notation_arp_high:
	ld a,CH_NOTATION_ARP_PARAM(ix)
	and #0xf0
	rrca
	rrca
	rrca
	rrca
player_effective_notation_add:
	add a,b
player_effective_clamp:
	cp #ZTR_NOTE_COUNT
	ret c
	ld a,#(ZTR_NOTE_COUNT - 1)
	ret
player_effective_low:
	xor a
	ret
