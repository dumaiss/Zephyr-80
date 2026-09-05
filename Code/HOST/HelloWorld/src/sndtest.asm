; SNDTEST.COM -- exercise the Percolator "Afternoon Blend" sound card.
;
; The card carries four SN76489AN PSGs plus an AD7801 PCM DAC.  IO_DECODER.pld
; routes the E0h-FFh block to SOUND on writes and to CONTROLLERS on reads, so
; this program only ever writes these ports.  Never read them expecting a PSG
; to answer; the SN76489 has no readable register and the read decode belongs
; to another device.
;
; Card-local decode uses A2:A0 only (pBITz J1 B32/B33/B34):
;
;   E0h  PSG0  U6   centre pan
;   E1h  PSG1  U7   centre pan
;   E2h  PSG2  U11  left-biased  (22k to LEFT, 47k to RIGHT)
;   E3h  PSG3  U12  right-biased (47k to LEFT, 22k to RIGHT)
;   E4h  PCM   U3   AD7801 parallel DAC, centre pan
;
; Because only A2:A0 reach the card, E8h/F0h/F8h alias back onto E0h.  Stick to
; E0h-E4h so the intent stays readable on a logic analyser.
;
; Facts that shape the code:
;
;   * All four PSGs share one 3.579545 MHz oscillator (Y1).  Tone frequency is
;     clock / (32 * N) for a 10-bit divisor N, so N = 111861 / f(Hz).
;   * The card generates its own wait states.  A PSG write asserts pBITz /WAIT
;     until that chip's open-collector READY rises, so back-to-back OUTs are
;     safe and need no software delay.  A stretched write costs roughly 32 PSG
;     clocks, about 8.9 us.
;   * Host data bits are reversed in the card wiring (DB7 -> PSG D0/MSB), so
;     software writes conventional SN76489 byte values.  Do not pre-swap here.
;   * The PSGs have no reset input on this card.  Their power-on state is
;     undefined, so software must mute all four chips before and after use.
;     This program does that on entry, between tests, on exit and on abort.
;
; SN76489 write format:
;   latch byte  1 cc t dddd   cc = channel, t = 0 tone / 1 volume, dddd = data
;   data byte   0 x dddddd    upper six bits of a 10-bit tone divisor
;   channel 3 tone latch doubles as the noise control register.
;   Attenuation runs 0 (loudest) to 15 (off).
;
; Usage:
;   SNDTEST      run tests 1-6
;   SNDTEST 1    chip identification, one voice per PSG in turn
;   SNDTEST 2    the four voices of PSG0, alone and together
;   SNDTEST 3    attenuation staircase
;   SNDTEST 4    noise generator modes
;   SNDTEST 5    tone divisor sweep
;   SNDTEST 6    /WAIT handshake stress plus a four-chip chord
;   SNDTEST P    AD7801 PCM DAC sawtooth (not part of the default run)
;
; Any keypress aborts, mutes every chip and returns to CP/M.

	.module sndtest
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02		; output char in E
BDOS_CONIN	= 0x01		; wait for and return a console char
BDOS_PRINT	= 0x09		; print '$'-terminated string at DE
BDOS_CONST	= 0x0b		; console status: A != 0 if a key is waiting

; Card ports.
PSG0		= 0xe0
PSG1		= 0xe1
PSG2		= 0xe2
PSG3		= 0xe3
PCM		= 0xe4
PSG_COUNT	= 4

; SN76489 latch bases for channel 0.  Add (channel << 5) for channels 1-3.
LATCH_TONE	= 0x80
LATCH_VOL	= 0x90
LATCH_NOISE	= 0xe0		; channel 3 tone latch = noise control
ATT_OFF		= 0x0f		; attenuation 15 = silent
ATT_MAX		= 0x00		; attenuation 0 = loudest

; Noise control bits, OR'd into LATCH_NOISE.
NOISE_WHITE	= 0x04		; clear for periodic
NOISE_DIV512	= 0x00
NOISE_DIV1024	= 0x01
NOISE_DIV2048	= 0x02
NOISE_TONE3	= 0x03		; noise clocked by tone generator 3 (channel 2)

; Tone divisors, N = 111861 / f.
NOTE_C4		= 428
NOTE_E4		= 339
NOTE_G4		= 285
NOTE_A4		= 254
NOTE_C5		= 214
NOTE_E5		= 170
NOTE_G5		= 143
NOTE_A5		= 127

; ===========================================================================
start:
	; CP/M leaves the CCP return address on its own shallow stack; switching
	; stacks would discard it, so save SP and restore it before returning.
	ld (entry_sp),sp
	ld sp,#stack_top

	call parse_arg
	ld de,#msg_banner
	call puts

	ld a,(sel_test)
	cp #0xfe			; parse_arg's "bad argument" marker
	jr z,usage

	; The PSGs come up in an undefined state.  Silence everything before the
	; first test so a stuck channel from a previous program is not mistaken
	; for a result of this one.
	call mute_all

	ld a,(sel_test)
	or a
	jr nz,single_test

	; Default run: tests 1 through 6.  The PCM DAC test is left out because
	; it exercises a different device on the card and is easier to judge on
	; its own.
	ld a,#1
	ld (cur_test),a
all_loop:
	call run_one
	ld a,(abort_flag)
	or a
	jr nz,finish
	ld a,(cur_test)
	inc a
	ld (cur_test),a
	cp #7
	jr c,all_loop
	jr finish

single_test:
	ld (cur_test),a
	call run_one

finish:
	; Leave the card quiet whether the run completed or was aborted.  The
	; PSGs would otherwise hold their last state until power-off.
	call mute_all
	ld a,(abort_flag)
	or a
	jr z,finish_done
	ld de,#msg_aborted
	call puts
finish_done:
	ld de,#msg_done
	call puts
	ld sp,(entry_sp)
	ret

usage:
	ld de,#msg_usage
	call puts
	ld sp,(entry_sp)
	ret

; ---------------------------------------------------------------------------
; run_one -- dispatch the test named by cur_test (1-7).
; ---------------------------------------------------------------------------
run_one:
	ld a,(cur_test)
	dec a
	add a,a
	ld l,a
	ld h,#0
	ld de,#test_table
	add hl,de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	jp (hl)			; the test's own RET returns to run_one's caller

test_table:
	.dw test_chips
	.dw test_voices
	.dw test_volume
	.dw test_noise
	.dw test_sweep
	.dw test_stress
	.dw test_pcm

; ===========================================================================
; Test 1 -- one voice per PSG in turn.
;
; Each chip plays the same note, so the operator can confirm that all four
; chip selects reach a device and that the stereo matrix places PSG2 and PSG3
; off centre.
; ===========================================================================
test_chips:
	ld de,#msg_t1
	call puts
	xor a
	ld (chip_idx),a
t1_loop:
	ld a,(chip_idx)
	call psg_select

	ld de,#msg_t1_chip
	call puts
	ld a,(chip_idx)
	add a,#'0'
	call putc
	ld de,#msg_port
	call puts
	ld a,(psg_port)
	call print_hex_byte
	ld de,#msg_space
	call puts
	ld a,(chip_idx)
	call print_pan
	call crlf

	ld e,#0
	ld hl,#NOTE_A5
	call psg_tone
	ld e,#0
	ld a,#ATT_MAX
	call psg_vol
	ld hl,#600
	call delay_ms
	call psg_mute			; gap, so the four notes stay distinct
	ld hl,#200
	call delay_ms

	ld a,(abort_flag)
	or a
	ret nz
	ld a,(chip_idx)
	inc a
	ld (chip_idx),a
	cp #PSG_COUNT
	jr c,t1_loop
	ret

; ===========================================================================
; Test 2 -- the four voices of PSG0.
;
; Three tone channels alone, then together as a C major triad, then the noise
; channel.  A missing voice here points at the latch byte's channel field
; rather than at the chip select.
; ===========================================================================
test_voices:
	ld de,#msg_t2
	call puts
	xor a
	call psg_select

	ld e,#0
	ld hl,#NOTE_C5
	call psg_tone
	ld e,#1
	ld hl,#NOTE_E5
	call psg_tone
	ld e,#2
	ld hl,#NOTE_G5
	call psg_tone

	; Each channel alone.
	ld c,#0
t2_loop:
	ld de,#msg_t2_ch
	call puts
	ld a,c
	add a,#'0'
	call putc
	call crlf

	ld e,c
	ld a,#ATT_MAX
	call psg_vol
	ld hl,#450
	call delay_ms
	ld e,c
	ld a,#ATT_OFF
	call psg_vol
	ld hl,#120
	call delay_ms

	ld a,(abort_flag)
	or a
	ret nz
	inc c
	ld a,c
	cp #3
	jr c,t2_loop

	; All three together.
	ld de,#msg_t2_chord
	call puts
	ld e,#0
	ld a,#ATT_MAX
	call psg_vol
	ld e,#1
	ld a,#ATT_MAX
	call psg_vol
	ld e,#2
	ld a,#ATT_MAX
	call psg_vol
	ld hl,#900
	call delay_ms
	call psg_mute
	ld hl,#200
	call delay_ms
	ld a,(abort_flag)
	or a
	ret nz

	; Noise channel.
	ld de,#msg_t2_noise
	call puts
	ld a,#(NOISE_WHITE | NOISE_DIV1024)
	call psg_noise
	ld e,#3
	ld a,#ATT_MAX
	call psg_vol
	ld hl,#700
	call delay_ms
	call psg_mute
	ret

; ===========================================================================
; Test 3 -- attenuation staircase on PSG0 channel 0.
;
; Steps 0 (loudest) to 15 (off) and back.  The SN76489 attenuator is 2 dB per
; step, so the ramp should sound even rather than collapsing at one end.
; ===========================================================================
test_volume:
	ld de,#msg_t3
	call puts
	xor a
	call psg_select
	ld e,#0
	ld hl,#NOTE_A4
	call psg_tone

	ld c,#0
t3_down:
	ld a,c
	call print_hex_nibble
	ld e,#0
	ld a,c
	call psg_vol
	ld hl,#170
	call delay_ms
	ld a,(abort_flag)
	or a
	jr nz,t3_end
	inc c
	ld a,c
	cp #16
	jr c,t3_down

	call crlf
	ld c,#15
t3_up:
	ld a,c
	call print_hex_nibble
	ld e,#0
	ld a,c
	call psg_vol
	ld hl,#170
	call delay_ms
	ld a,(abort_flag)
	or a
	jr nz,t3_end
	dec c
	ld a,c
	cp #0xff
	jr nz,t3_up
t3_end:
	call crlf
	call psg_mute
	ret

; ===========================================================================
; Test 4 -- noise generator modes on PSG0 channel 3.
;
; Periodic and white noise at each of the three fixed shift rates, then the
; tone-3 clocked mode with channel 2's divisor swept.  Writing the noise
; control latch resets the shift register, which is why each mode starts
; cleanly rather than blending into the previous one.
; ===========================================================================
test_noise:
	ld de,#msg_t4
	call puts
	xor a
	call psg_select
	ld e,#3
	ld a,#ATT_MAX
	call psg_vol

	ld hl,#noise_modes
t4_loop:
	ld a,(hl)
	cp #0xff
	jr z,t4_tone3
	push hl
	call print_hex_nibble		; the control nibble actually written
	ld de,#msg_space
	call puts
	pop hl
	ld a,(hl)
	push hl
	call psg_noise
	ld hl,#600
	call delay_ms
	pop hl
	ld a,(abort_flag)
	or a
	jr nz,t4_end
	inc hl
	jr t4_loop

t4_tone3:
	call crlf
	ld de,#msg_t4_tone3
	call puts
	; Channel 2 clocks the noise generator in this mode.  Its own output is
	; muted so only the noise is heard.
	ld e,#2
	ld a,#ATT_OFF
	call psg_vol
	ld a,#(NOISE_WHITE | NOISE_TONE3)
	call psg_noise
	ld hl,#100
t4_sweep:
	push hl
	ld e,#2
	call psg_tone
	ld hl,#60
	call delay_ms
	pop hl
	ld a,(abort_flag)
	or a
	jr nz,t4_end
	ld de,#60
	add hl,de
	ld de,#900
	push hl
	or a				; clear carry before the 16-bit compare
	sbc hl,de
	pop hl
	jr c,t4_sweep
t4_end:
	call crlf
	call psg_mute
	ret

noise_modes:
	.db NOISE_DIV512		; periodic, fastest shift
	.db NOISE_DIV1024
	.db NOISE_DIV2048
	.db NOISE_WHITE | NOISE_DIV512
	.db NOISE_WHITE | NOISE_DIV1024
	.db NOISE_WHITE | NOISE_DIV2048
	.db 0xff			; end marker

; ===========================================================================
; Test 5 -- tone divisor sweep on PSG0 channel 0.
;
; Walks the full 10-bit divisor range, so every write exercises both the latch
; byte's low nibble and the second data byte's upper six bits.  A sweep that
; jumps in octaves or sticks at one pitch means the second byte is not landing.
; ===========================================================================
test_sweep:
	ld de,#msg_t5
	call puts
	xor a
	call psg_select
	ld e,#0
	ld a,#ATT_MAX
	call psg_vol

	ld hl,#1000			; low pitch
t5_up:
	push hl
	ld e,#0
	call psg_tone
	ld hl,#25
	call delay_ms
	pop hl
	ld a,(abort_flag)
	or a
	jr nz,t5_end
	ld de,#20
	or a
	sbc hl,de
	ld de,#60			; high pitch limit
	push hl
	or a
	sbc hl,de
	pop hl
	jr nc,t5_up

	; The loop exits one step past the limit, so step back to the last
	; divisor actually played before reversing.
	ld de,#20
	add hl,de
t5_down:
	push hl
	ld e,#0
	call psg_tone
	ld hl,#25
	call delay_ms
	pop hl
	ld a,(abort_flag)
	or a
	jr nz,t5_end
	ld de,#20
	add hl,de
	ld de,#1000
	push hl
	or a
	sbc hl,de
	pop hl
	jr c,t5_down
t5_end:
	call psg_mute
	ret

; ===========================================================================
; Test 6 -- /WAIT handshake stress, then a four-chip chord.
;
; Every PSG write is stretched by the card's wait-state generator until the
; selected chip's READY rises.  This loop issues 16384 of them back to back
; across all four chip selects with no software spacing at all.  Reaching the
; line after the loop is the result: the FF1/FF2 state machine armed, cleared
; and rearmed 16384 times without leaving /WAIT asserted.  Expect roughly
; 150 ms of stretched bus time.
; ===========================================================================
test_stress:
	ld de,#msg_t6
	call puts

	; Give every chip an audible voice first, so the stress loop is also a
	; listening test: the tone must stay steady through it.
	ld c,#0
	ld hl,#chord_notes
t6_setup:
	ld a,c
	call psg_select
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	push hl
	ex de,hl
	ld e,#0
	call psg_tone
	ld e,#0
	ld a,#ATT_MAX
	call psg_vol
	pop hl
	inc c
	ld a,c
	cp #PSG_COUNT
	jr c,t6_setup

	ld hl,#400
	call delay_ms
	ld a,(abort_flag)
	or a
	jr nz,t6_end

	ld de,#msg_t6_stress
	call puts

	; Immediate-port OUTs here rather than psg_out: this loop is about bus
	; behaviour, so the port numbers are spelled out and nothing sits between
	; the writes.  The value rewrites channel 0 volume at full level, which is
	; already what each chip holds, so the audio does not change.
	ld bc,#4096
t6_loop:
	ld a,#(LATCH_VOL | ATT_MAX)
	out (PSG0),a
	out (PSG1),a
	out (PSG2),a
	out (PSG3),a
	dec bc
	ld a,b
	or c
	jr nz,t6_loop

	ld de,#msg_t6_ok
	call puts
	ld hl,#800
	call delay_ms
t6_end:
	call mute_all
	ret

chord_notes:
	.dw NOTE_C4			; PSG0, centre
	.dw NOTE_E4			; PSG1, centre
	.dw NOTE_G4			; PSG2, left
	.dw NOTE_C5			; PSG3, right

; ===========================================================================
; Test 7 -- AD7801 PCM DAC sawtooth (SNDTEST P).
;
; The DAC is at E4h and is deliberately outside the PSG wait-state generator,
; so these writes run at full bus speed and the waveform timing is entirely
; software.  LDAC is grounded, so the output updates on the rising edge of /WR
; with no separate load strobe.
;
; REFIN is tied to VDD, giving a 0-VDD output span with mid-scale at 80h.  The
; test leaves 80h loaded on exit so the DAC sits at mid-rail instead of holding
; a DC offset into the mixer.
; ===========================================================================
test_pcm:
	ld de,#msg_t7
	call puts

	ld de,#420			; sawtooth periods to emit
	ld c,#0				; current sample value
t7_period:
	ld b,#64			; 64 steps per period, +4 per step
t7_step:
	ld a,c
	out (PCM),a
	add a,#4
	ld c,a
	push bc
	ld b,#44			; ~600 T-states, about 60 us per step
t7_dwell:
	djnz t7_dwell
	pop bc
	djnz t7_step

	dec de
	ld a,d
	or e
	jr z,t7_end
	; One console poll per period keeps the abort key responsive without
	; disturbing the sample rate inside a period.
	call poll_abort
	ld a,(abort_flag)
	or a
	jr z,t7_period
t7_end:
	ld a,#0x80			; park the DAC at mid-rail
	out (PCM),a
	ld de,#msg_t7_ok
	call puts
	ret

; ===========================================================================
; PSG primitives.
;
; All of them preserve everything except AF (and D, where noted), so they can
; be called from inside loops that hold counters in BC/DE/HL.
; ===========================================================================

; psg_select -- point the primitives at chip A (0-3).
psg_select:
	push af
	and #0x03
	add a,#PSG0
	ld (psg_port),a
	pop af
	ret

; psg_out -- write A to the selected chip.
;
; Bring-up version:
; Ignore READY//WAIT and deliberately wait ~21 us after every PSG byte.
;
; 10 MHz Z80:
;     LD B,16           7 T
;     15 x DJNZ taken 195 T
;     final DJNZ         8 T
;                     -----
;                      210 T = 21.0 us

psg_out:
    push bc

    ld b,a
    ld a,(psg_port)
    ld c,a
    ld a,b
    ld b,#0
    out (c),a

    ; Let the SN76489 finish this transfer before issuing another.
    ld b,#38
psg_write_delay:
    djnz psg_write_delay

    pop bc
    ret
; psg_tone -- program a 10-bit tone divisor.
;   In:  E = channel 0-2, HL = divisor 1-1023
;   Clobbers: AF, D
psg_tone:
	ld a,e
	rrca				; channel << 5 for e < 8
	rrca
	rrca
	or #LATCH_TONE
	ld d,a
	ld a,l
	and #0x0f			; low four divisor bits ride in the latch
	or d
	call psg_out
	ld a,l				; second byte carries bits 9-4
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
	call psg_out
	ret

; psg_vol -- set channel attenuation.
;   In:  E = channel 0-3, A = attenuation 0 (loud) to 15 (off)
;   Clobbers: AF, D
psg_vol:
	and #0x0f
	ld d,a
	ld a,e
	rrca
	rrca
	rrca
	or #LATCH_VOL
	or d
	call psg_out
	ret

; psg_noise -- write the channel 3 noise control register.
;   In:  A = feedback and shift-rate bits (0-7)
;   Clobbers: AF
psg_noise:
	and #0x07
	or #LATCH_NOISE
	call psg_out
	ret

; psg_mute -- silence all four channels of the selected chip.
psg_mute:
	push bc
	push de
	ld e,#0
psg_mute_ch:
	ld a,#ATT_OFF
	call psg_vol
	inc e
	ld a,e
	cp #4
	jr c,psg_mute_ch
	pop de
	pop bc
	ret

; mute_all -- silence every chip on the card.  Called on entry, on exit and
; between tests; the PSGs have no reset line, so this is the only way they
; reach a known state.
mute_all:
	push af
	push bc
	ld c,#0
mute_all_loop:
	ld a,c
	call psg_select
	call psg_mute
	inc c
	ld a,c
	cp #PSG_COUNT
	jr c,mute_all_loop
	xor a
	call psg_select			; leave PSG0 selected for the next test
	pop bc
	pop af
	ret

; ===========================================================================
; Timing and console helpers.
; ===========================================================================

; delay_ms -- wait HL milliseconds, or until a key is pressed.
;
; The inner loop is 250 iterations of a 40 T-state body: push af (11) + pop af
; (10) + inc de (6) + djnz (13) = 40, so 10000 T-states = 1.000 ms at 10 MHz.
; The outer loop's own overhead adds well under 0.5%.
;
; The console is polled every 64 ms rather than every millisecond.  On a VDrip
; console the BDOS status call is what flushes a pending print run to the
; display, so this both services the abort key and keeps the on-screen commentary
; in step with what is being heard; polling every millisecond would flood the
; serial link and distort the note lengths.
delay_ms:
	push af
	push bc
	push de
	push hl
delay_ms_loop:
	ld a,h
	or l
	jr z,delay_ms_done
	ld b,#250
delay_1ms:
	push af
	pop af
	inc de
	djnz delay_1ms
	dec hl
	ld a,l
	and #0x3f
	jr nz,delay_ms_loop
	call poll_abort
	ld a,(abort_flag)
	or a
	jr z,delay_ms_loop
delay_ms_done:
	pop hl
	pop de
	pop bc
	pop af
	ret

; poll_abort -- set abort_flag if a key is waiting, consuming the keystroke.
poll_abort:
	push bc
	push de
	push hl
	ld c,#BDOS_CONST
	call BDOS
	or a
	jr z,poll_abort_done
	ld c,#BDOS_CONIN
	call BDOS			; consume it so the CCP does not see it
	ld a,#1
	ld (abort_flag),a
poll_abort_done:
	pop hl
	pop de
	pop bc
	ret

; print_pan -- print the stereo placement of chip A, from the mixer network.
print_pan:
	push hl
	push de
	add a,a
	ld l,a
	ld h,#0
	ld de,#pan_table
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	call puts
	pop de
	pop hl
	ret

pan_table:
	.dw msg_pan_c			; PSG0 U6,  33k/33k
	.dw msg_pan_c			; PSG1 U7,  33k/33k
	.dw msg_pan_l			; PSG2 U11, 22k/47k
	.dw msg_pan_r			; PSG3 U12, 47k/22k

puts:
	push hl
	push de
	push bc
	ld c,#BDOS_PRINT
	call BDOS
	pop bc
	pop de
	pop hl
	ret

putc:
	push hl
	push de
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	pop de
	pop hl
	ret

crlf:
	push de
	ld de,#msg_crlf
	call puts
	pop de
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
print_hex_nibble:
	push af
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,print_hex_out
	add a,#0x07
print_hex_out:
	call putc
	pop af
	ret

; parse_arg -- read the CP/M command tail and set sel_test.
;   0    = run tests 1-6
;   1-6  = run that test alone
;   7    = PCM DAC test ('P')
;   FEh  = unrecognised argument; print usage and exit
parse_arg:
	xor a
	ld (sel_test),a
	ld (abort_flag),a
	ld a,(0x0080)
	or a
	ret z				; no tail
	ld b,a
	ld hl,#0x0081
parse_skip:
	ld a,(hl)
	cp #' '
	jr nz,parse_got
	inc hl
	djnz parse_skip
	ret				; tail was all blanks
parse_got:
	cp #'1'
	jr c,parse_alpha
	cp #'7'
	jr nc,parse_alpha
	sub #'0'
	ld (sel_test),a
	ret
parse_alpha:
	and #0xdf			; fold to upper case
	cp #'P'
	jr nz,parse_bad
	ld a,#7
	ld (sel_test),a
	ret
parse_bad:
	ld a,#0xfe
	ld (sel_test),a
	ret

; ===========================================================================
msg_banner:
	.ascii "SNDTEST - Afternoon Blend sound card at E0h"
	.db 13,10
	.ascii "4x SN76489AN at E0h-E3h, AD7801 PCM at E4h; any key aborts."
	.db 13,10,'$'
msg_usage:
	.ascii "usage: SNDTEST [1-6|P]"
	.db 13,10
	.ascii "  1 chips  2 voices  3 volume  4 noise  5 sweep  6 wait-stress"
	.db 13,10
	.ascii "  P PCM DAC sawtooth      no argument runs 1-6"
	.db 13,10,'$'
msg_t1:
	.ascii "1: chip identification, same note on each PSG"
	.db 13,10,'$'
msg_t1_chip:
	.ascii "   PSG"
	.db '$'
msg_t2:
	.ascii "2: PSG0 voices"
	.db 13,10,'$'
msg_t2_ch:
	.ascii "   channel "
	.db '$'
msg_t2_chord:
	.ascii "   channels 0+1+2 together"
	.db 13,10,'$'
msg_t2_noise:
	.ascii "   channel 3, white noise"
	.db 13,10,'$'
msg_t3:
	.ascii "3: attenuation staircase on PSG0 channel 0, 0=loud to F=off"
	.db 13,10
	.ascii "   "
	.db '$'
msg_t4:
	.ascii "4: noise modes on PSG0 channel 3 (control nibble shown)"
	.db 13,10
	.ascii "   "
	.db '$'
msg_t4_tone3:
	.ascii "   tone-3 clocked noise, channel 2 divisor swept"
	.db 13,10,'$'
msg_t5:
	.ascii "5: tone divisor sweep, 1000 down to 60 and back"
	.db 13,10,'$'
msg_t6:
	.ascii "6: four-chip chord and /WAIT handshake stress"
	.db 13,10,'$'
msg_t6_stress:
	.ascii "   16384 wait-stretched writes across E0h-E3h..."
	.db '$'
msg_t6_ok:
	.ascii " completed"
	.db 13,10,'$'
msg_t7:
	.ascii "P: AD7801 PCM sawtooth at E4h, no wait states"
	.db 13,10,'$'
msg_t7_ok:
	.ascii "   DAC parked at mid-rail (80h)"
	.db 13,10,'$'
msg_port:
	.ascii "  port "
	.db '$'
msg_pan_c:
	.ascii "centre"
	.db '$'
msg_pan_l:
	.ascii "left-biased"
	.db '$'
msg_pan_r:
	.ascii "right-biased"
	.db '$'
msg_aborted:
	.ascii "aborted by keypress"
	.db 13,10,'$'
msg_done:
	.ascii "all chips muted."
	.db 13,10,'$'
msg_space:
	.ascii " "
	.db '$'
msg_crlf:
	.db 13,10,'$'

; ===========================================================================
entry_sp:	.ds 2
psg_port:	.ds 1
chip_idx:	.ds 1
sel_test:	.ds 1
cur_test:	.ds 1
abort_flag:	.ds 1
	.ds 96				; BDOS nesting headroom
stack_top:
