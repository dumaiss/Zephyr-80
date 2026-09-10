; Afternoon Blend SN76489 driver. The card selects PSG0-PSG3 at E0h-E3h and
; accepts conventional SN76489 bit order. Furnace/ZTR semantics stop here.

; sn_mute_all -- silence all four chips without changing tracker state.
;   Clobbers: AF, BC, DE. May block for the per-byte hardware settling delay.
;   Emits PSG traffic. Not ISR-safe.
sn_mute_all:
	ld c,#PSG0_PORT
	ld d,#PSG_COUNT
sn_mute_chip:
	ld a,#0x9f
	ld e,#4
sn_mute_voice:
	call sn_write
	add a,#0x20
	dec e
	jr nz,sn_mute_voice
	inc c
	dec d
	jr nz,sn_mute_chip
	ret

; sn_write -- write conventional SN76489 byte A to port C.
; The current SNDTEST bring-up path waits about 50 us after each byte. Retain
; that conservative behavior here; the hardware data-bit reversal is already
; accounted for on the card and must not be repeated in software.
;   Clobbers: AF. Preserves BC, DE, HL and IX. May block briefly.
sn_write:
	push bc
	ld b,#0				; OUT (C),A exposes BC on the physical address bus
	out (c),a
	ld b,#38
sn_write_delay:
	djnz sn_write_delay
	pop bc
	ret

; sn_render_all -- flush dirty logical channel state to its fixed PSG voice.
;   Clobbers: AF, BC, DE, HL, IX. Emits only dirty PSG values. Not ISR-safe.
sn_render_all:
	xor a
	ld (current_channel),a
sn_render_all_loop:
	call get_channel_ix
	call sn_render_channel
	ld a,(current_channel)
	inc a
	ld (current_channel),a
	cp #ZTR_CHANNELS
	jr nz,sn_render_all_loop
	ret

sn_render_channel:
	ld a,(current_channel)
	and #0x03
	cp #3
	jr z,sn_render_noise_channel
	ld a,CH_DIRTY(ix)
	and #DIRTY_PITCH
	call nz,sn_render_tone
	jr sn_render_volume_check
sn_render_noise_channel:
	ld a,CH_DIRTY(ix)
	and #(DIRTY_NOISE | DIRTY_PHASE | DIRTY_PITCH)
	call nz,sn_render_noise
sn_render_volume_check:
	ld a,CH_DIRTY(ix)
	and #DIRTY_VOLUME
	call nz,sn_render_volume
	ret

sn_get_port_voice:
	ld a,(current_channel)
	ld e,a
	and #0x03
	ld e,a
	ld a,(current_channel)
	srl a
	srl a
	add a,#PSG0_PORT
	ld c,a
	ret

sn_render_tone:
	call player_effective_note
	ld l,a
	ld h,#0
	add hl,hl
	ld de,(note_table_base)
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call sn_apply_fine_pitch
	call sn_get_port_voice
	call sn_write_tone
	ld a,CH_DIRTY(ix)
	and #0xfe
	ld CH_DIRTY(ix),a
	ret

; Apply a signed pitch macro in 1/128-semitone units. For the initial player,
; magnitudes above 63 are saturated. period*pitch/2048 is a close, cheap local
; approximation to the exponential divisor curve and preserves Night Market's
; subtle +/-32 vibrato without a floating-point or 24-bit multiply.
sn_apply_fine_pitch:
	ld a,CH_PITCH_VALUE+1(ix)
	or a
	jr z,sn_pitch_positive
	cp #0xff
	ret nz
	ld a,#1
	ld (pitch_negative),a
	ld a,CH_PITCH_VALUE(ix)
	neg
	jr sn_pitch_have_magnitude
sn_pitch_positive:
	xor a
	ld (pitch_negative),a
	ld a,CH_PITCH_VALUE(ix)
sn_pitch_have_magnitude:
	or a
	ret z
	cp #64
	jr c,sn_pitch_magnitude_ok
	ld a,#63
sn_pitch_magnitude_ok:
	push bc
	push de
	push hl				; original divisor
	ld b,a
	ld de,#0			; product
	ld a,#8
sn_pitch_multiply:
	srl b
	jr nc,sn_pitch_no_add
	ex de,hl
	add hl,de
	ex de,hl
sn_pitch_no_add:
	add hl,hl
	dec a
	jr nz,sn_pitch_multiply
	ex de,hl			; product in HL
	ld b,#11
sn_pitch_divide:
	srl h
	rr l
	djnz sn_pitch_divide
	ld c,l				; divisor delta
	pop hl				; original divisor
	ld a,(pitch_negative)
	or a
	jr nz,sn_pitch_add_delta
	ld a,l
	sub c
	ld l,a
	jr nc,sn_pitch_positive_done
	dec h
sn_pitch_positive_done:
	ld a,h
	or l
	jr nz,sn_pitch_adjust_done
	inc l				; SN divisor zero aliases 400h; never emit it
	jr sn_pitch_adjust_done
sn_pitch_add_delta:
	ld e,c
	ld d,#0
	add hl,de
	ld a,h
	cp #4
	jr c,sn_pitch_adjust_done
	ld hl,#1023
sn_pitch_adjust_done:
	pop de
	pop bc
	ret

; Program one tone generator. In: C=PSG port, E=voice 0-2, HL=1..1023.
sn_write_tone:
	ld a,e
	rrca
	rrca
	rrca
	or #0x80
	ld d,a
	ld a,l
	and #0x0f
	or d
	call sn_write
	ld a,l
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	ld d,a
	ld a,h
	rlca
	rlca
	rlca
	rlca
	and #0x30
	or d
	call sn_write
	ret

sn_render_noise:
	call player_effective_note
	and #0x03
	ld d,a
	ld a,CH_DUTY_VALUE(ix)
	and #0x01
	jr z,sn_noise_periodic
	ld a,d
	or #0x04			; SN white-noise bit
	ld d,a
sn_noise_periodic:
	; d&3 == 3 explicitly selects this chip's Tone 2 as the noise clock.
	call sn_get_port_voice
	ld a,d
	or #0xe0
	call sn_write
	ld a,d
	ld CH_LAST_NOISE(ix),a
	ld a,CH_DIRTY(ix)
	and #0xf2			; clear pitch/noise/phase dirty bits
	ld CH_DIRTY(ix),a
	ret

sn_render_volume:
	call sn_calculate_loudness
	ld d,a
	ld a,#15
	sub d
	ld d,a				; SN attenuation: 0 loud, 15 silent
	call sn_get_port_voice
	ld a,e
	rrca
	rrca
	rrca
	or #0x90
	or d
	call sn_write
	ld a,d
	ld CH_LAST_ATTENUATION(ix),a
	ld a,CH_DIRTY(ix)
	and #0xfd
	ld CH_DIRTY(ix),a
	ret

; Combine the channel-volume column and volume macro as (base*macro)/15.
; Output A is Furnace loudness 0..15.
sn_calculate_loudness:
	ld a,CH_FLAGS(ix)
	and #CHANNEL_ACTIVE
	jr z,sn_loudness_silent
	ld b,CH_BASE_VOLUME(ix)
	ld c,CH_MACRO_VOLUME(ix)
	xor a
	ld d,c
	or d
	jr z,sn_loudness_product_done
sn_loudness_product_loop:
	add a,b
	dec d
	jr nz,sn_loudness_product_loop
sn_loudness_product_done:
	ld c,#0
sn_loudness_divide:
	cp #15
	jr c,sn_loudness_done
	sub #15
	inc c
	jr sn_loudness_divide
sn_loudness_done:
	ld a,c
	ret
sn_loudness_silent:
	xor a
	ret
