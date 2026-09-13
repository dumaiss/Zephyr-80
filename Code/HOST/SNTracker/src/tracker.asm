; SNTRACK.COM -- native Zephyr-80 tracker player.
;
; This CP/M transient loads one bounded ZTR file at 6000h.  CTC0 publishes
; playback ticks through a callback registered with the BIOS-owned IM2
; dispatcher; row decoding, macro processing, UI output and all SN76489 writes
; remain in foreground code.

	.module sntracker
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONIN	= 0x01
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
BDOS_CONST	= 0x0b
BDOS_OPEN	= 0x0f
BDOS_CLOSE	= 0x10
BDOS_READ_SEQ	= 0x14
BDOS_SET_DMA	= 0x1a
ZB_REGISTER_ISR = 200
ZB_UNREGISTER_ISR = 201

DEFAULT_FCB	= 0x005c
FCB_BYTES	= 36
FCB_RUNTIME	= 12

	; Reuse the BIOS project's authoritative Zephyr port constants.
	.include "../CPM2.2/src/platform_zephyr80.inc"

PSG0_PORT	= SOUND_PSG0_PORT
PSG_COUNT	= SOUND_PSG_COUNT

CTC0_PORT	= CTC0_CTRL
CTC_TIMER_PORT	= CTC0_PORT
CTC_CONTROL	= 0xa7		; interrupt, timer, /256, auto, TC follows
CTC_STOP	= CTC_RESET_DISABLE
CTC_TC_180HZ	= 217
CTC_BASE_RATE	= 180

SONG_BUFFER	= 0x6000
SONG_BUFFER_END	= 0xb000
SONG_BUFFER_BYTES = SONG_BUFFER_END - SONG_BUFFER
PRIVATE_STACK	= 0xbff0

; The callback and every byte it touches live in the transient's 1 KiB common
; reservation.  All decoding and PSG work remains in foreground banked memory.
COMMON_CALLBACK = 0xe000
COMMON_GUARD_LO = 0xe03f
COMMON_STATE_BASE = 0xe040
tick_phase	= COMMON_STATE_BASE + 0
ticks_pending	= COMMON_STATE_BASE + 1
tick_rate	= COMMON_STATE_BASE + 2
COMMON_GUARD_HI = 0xe043

SONG_GUARD	= SONG_BUFFER_END
GUARD_LO_VALUE	= 0xa5
GUARD_HI_VALUE	= 0x5a

ZTR_VERSION	= 1
ZTR_HEADER_BYTES = 64
ZTR_CHANNELS	= 16
ZTR_NOTE_COUNT	= 96
ZTR_INSTRUMENT_BYTES = 16
ZTR_PATTERN_BYTES = 8

ZH_VERSION	= 4
ZH_HEADER_SIZE	= 5
ZH_FLAGS	= 6
ZH_CHANNELS	= 7
ZH_TICK_RATE	= 8
ZH_SPEED	= 10
ZH_SOURCE_CHANNELS = 11
ZH_PATTERN_LENGTH = 12
ZH_ORDER_COUNT	= 14
ZH_PATTERN_COUNT = 16
ZH_INSTRUMENT_COUNT = 18
ZH_TUNING	= 20
ZH_PSG_CLOCK	= 24
ZH_TITLE_OFFSET = 28
ZH_ORDER_OFFSET = 34
ZH_INSTRUMENT_OFFSET = 36
ZH_MACRO_OFFSET = 38
ZH_PATTERN_DIR_OFFSET = 40
ZH_PATTERN_DATA_OFFSET = 42
ZH_NOTE_TABLE_OFFSET = 44
ZH_FILE_SIZE	= 46
ZH_ORDER_BYTES	= 50
ZH_INSTRUMENT_BYTES = 51
ZH_PATTERN_BYTES = 52
ZH_NOTE_COUNT	= 53

EVENT_NOTE	= 0x80
EVENT_INSTRUMENT = 0x40
EVENT_VOLUME	= 0x20
EVENT_EFFECT	= 0x10
EVENT_OFF	= 0x08
EVENT_RELEASE	= 0x04
EVENT_LEGATO	= 0x02
EVENT_MODIFIERS = 0x01

MOD_RESET	= 0x80
MOD_ARP_SET	= 0x40
MOD_ARP_CLEAR	= 0x20
MOD_HAIRPIN_SET = 0x10
MOD_HAIRPIN_CLEAR = 0x08

EFFECT_ARPEGGIO = 1
EFFECT_VOL_SLIDE = 2
EFFECT_LEGATO	= 3
EFFECT_VOL_DEC	= 4
EFFECT_FAST_VOL = 5
EFFECT_STOP	= 6

DIRTY_PITCH	= 0x01
DIRTY_VOLUME	= 0x02
DIRTY_NOISE	= 0x04
DIRTY_PHASE	= 0x08

CHANNEL_ACTIVE	= 0x01
CHANNEL_RELEASED = 0x02
CHANNEL_LEGATO	= 0x04
CHANNEL_NOTATION_ARP = 0x08

; Per-channel state is deliberately a power of two so channel*64 is cheap.
CH_NOTE		= 0
CH_INSTRUMENT	= 1
CH_BASE_VOLUME	= 2
CH_MACRO_VOLUME = 3
CH_EFFECT	= 4
CH_EFFECT_PARAM = 5
CH_FLAGS	= 6
CH_DIRTY	= 7
CH_ARP_VALUE	= 8		; signed word
CH_PITCH_VALUE	= 10		; signed word, 1/128 semitone
CH_DUTY_VALUE	= 12
CH_PHASE_VALUE	= 13
CH_VOL_TIMER	= 14
CH_PITCH_TIMER	= 15
CH_ARP_TIMER	= 16
CH_DUTY_TIMER	= 17
CH_PHASE_TIMER	= 18
CH_VOL_DELAY	= 19
CH_PITCH_DELAY	= 20
CH_ARP_DELAY	= 21
CH_DUTY_DELAY	= 22
CH_PHASE_DELAY	= 23
CH_VOL_POSITION = 24		; five word positions through offset 33
CH_PITCH_POSITION = 26
CH_ARP_POSITION = 28
CH_DUTY_POSITION = 30
CH_PHASE_POSITION = 32
CH_VOL_MACRO	= 34		; five word pointers through offset 43
CH_PITCH_MACRO	= 36
CH_ARP_MACRO	= 38
CH_DUTY_MACRO	= 40
CH_PHASE_MACRO	= 42
CH_PATTERN_CURSOR = 44
CH_PATTERN_END	= 46
CH_EFFECT_PHASE = 48
CH_ARP_FLAGS	= 49
CH_LAST_ATTENUATION = 50
CH_LAST_NOISE	= 51
CH_NOTATION_ARP_PARAM = 52
CH_NOTATION_ARP_PHASE = 53
CH_HAIRPIN_RATE = 54		; signed loudness steps per tick
CH_HAIRPIN_OFFSET = 55		; signed accumulated loudness adjustment
CH_HAIRPIN_CEILING = 56		; realized instrument loudness ceiling
CHANNEL_STATE_BYTES = 64

; ---------------------------------------------------------------------------
start:
	ld (entry_sp),sp
	ld sp,#PRIVATE_STACK
	ld de,#msg_banner
	call puts
	call common_prepare

	call ztr_load
	jp c,start_load_error
	call ztr_init
	jp c,start_format_error
	call ui_init
	call ztr_play
	call ctc_setup
	jp c,start_ctc_error

tracker_loop:
	; At this boundary every foreground call must have unwound completely.
	; Catch a damaged foreground stack before another CALL consumes it.
	ld hl,#0
	add hl,sp
	ld de,#PRIVATE_STACK
	or a
	sbc hl,de
	ld a,#1
	jp nz,tracker_fault

	ld a,(playing)
	or a
	jr z,tracker_done

	di
	ld a,(ticks_pending)
	or a
	jr z,tracker_no_tick
	dec a
	ld (ticks_pending),a
	ei
	call ztr_tick
	call runtime_check
	jp c,tracker_fault
	ld a,(row_changed)
	or a
	call nz,ui_refresh

	ld a,(key_poll_count)
	dec a
	ld (key_poll_count),a
	jr nz,tracker_loop
	ld a,(key_poll_reload)
	ld (key_poll_count),a
	call poll_key
	jr tracker_loop

tracker_no_tick:
	ei
	halt
	jr tracker_loop

tracker_done:
	call ctc_stop
	ld de,#msg_done
	call puts
	jr tracker_exit

; A = diagnostic code. Stop the interrupt source before using the console so a
; damaged callback cannot run again while the failure is being reported.
tracker_fault:
	ld (fault_code),a
	ld sp,#PRIVATE_STACK
	ld a,#1
	ld (ctc_active),a
	call ctc_stop
	call sn_mute_all
	ld de,#msg_runtime_fault
	call puts
	ld a,(fault_code)
	call ui_puthex8
	ld de,#ui_order
	call puts
	ld a,(current_order)
	call ui_puthex8
	ld de,#msg_runtime_row
	call puts
	ld a,(current_row)
	call ui_puthex8
	ld de,#msg_runtime_end
	call puts
	jr tracker_exit

start_load_error:
	ld de,#msg_load_error
	call puts
	jr tracker_exit
start_format_error:
	ld de,#msg_format_error
	call puts
	jr tracker_exit
start_ctc_error:
	call ztr_stop
	ld de,#msg_ctc_error
	call puts
tracker_exit:
	ld sp,(entry_sp)
	ret

; Polling is foreground-only and rate limited to once per second.
poll_key:
	ld c,#BDOS_CONST
	call BDOS
	or a
	ret z
	ld c,#BDOS_CONIN
	call BDOS
	cp #'q'
	jr z,poll_key_abort
	cp #'Q'
	jr z,poll_key_abort
	cp #0x1b
	ret nz
poll_key_abort:
	ld a,#1
	ld (aborted),a
	jp ztr_stop

; ---------------------------------------------------------------------------
; CTC0 produces approximately 180 interrupts/s.  A phase accumulator derives
; the song header's rate; 60 Hz remains an exact divide-by-three schedule.
common_prepare:
	ld hl,#ctc_callback_template
	ld de,#COMMON_CALLBACK
	ld bc,#(ctc_callback_end - ctc_callback_template)
	ldir
	xor a
	ld (tick_phase),a
	ld (ticks_pending),a
	ld (tick_rate),a
	ld a,#GUARD_LO_VALUE
	ld (COMMON_GUARD_LO),a
	ld (SONG_GUARD),a
	ld (state_guard),a
	ld a,#GUARD_HI_VALUE
	ld (COMMON_GUARD_HI),a
	ld (SONG_GUARD + 1),a
	ret

; Check the boundaries most likely to identify cumulative corruption. Called
; only after a consumed song tick, so the diagnostic cost stays bounded.
; Out: carry set and A = code: 02 song end, 03/04 common state boundaries,
;      05 static state end, 06 copied callback, 07 invalid tick rate.
runtime_check:
	ld a,(SONG_GUARD)
	cp #GUARD_LO_VALUE
	ld a,#2
	jr nz,runtime_check_failed
	ld a,(SONG_GUARD + 1)
	cp #GUARD_HI_VALUE
	ld a,#2
	jr nz,runtime_check_failed
	ld a,(COMMON_GUARD_LO)
	cp #GUARD_LO_VALUE
	ld a,#3
	jr nz,runtime_check_failed
	ld a,(COMMON_GUARD_HI)
	cp #GUARD_HI_VALUE
	ld a,#4
	jr nz,runtime_check_failed
	ld a,(state_guard)
	cp #GUARD_LO_VALUE
	ld a,#5
	jr nz,runtime_check_failed

	; Compare all 39 copied bytes, not just the entry and RET. Interrupt-time
	; instruction fetch and foreground reads of the same immutable bytes are safe.
	ld hl,#ctc_callback_template
	ld de,#COMMON_CALLBACK
	ld b,#(ctc_callback_end - ctc_callback_template)
runtime_check_callback_loop:
	ld a,(de)
	cp (hl)
	ld a,#6
	jr nz,runtime_check_failed
	inc de
	inc hl
	djnz runtime_check_callback_loop

	ld a,(tick_rate)
	or a
	ld a,#7
	jr z,runtime_check_failed
	ld a,(tick_rate)
	cp #(CTC_BASE_RATE + 1)
	ld a,#7
	jr nc,runtime_check_failed
	or a
	ret
runtime_check_failed:
	scf
	ret

ctc_setup:
	ld b,#0				; CTC channel 0
	ld de,#COMMON_CALLBACK
	ld c,#ZB_REGISTER_ISR
	call BDOS
	or a
	jr nz,ctc_setup_failed
	xor a
	ld (tick_phase),a
	ld a,#CTC_CONTROL
	out (CTC_TIMER_PORT),a
	ld a,#CTC_TC_180HZ
	out (CTC_TIMER_PORT),a
	ld a,#1
	ld (ctc_active),a
	or a
	ret
ctc_setup_failed:
	scf
	ret

ctc_stop:
	ld a,(ctc_active)
	or a
	ret z
	; Stop the source before releasing the BIOS registration.
	ld a,#CTC_STOP
	out (CTC_TIMER_PORT),a
	ld b,#0
	ld c,#ZB_UNREGISTER_ISR
	call BDOS
	xor a
	ld (ctc_active),a
	ret

; Copied to E000h. The BIOS dispatcher preserves AF, BC, DE and HL, owns the
; interrupt stack, and performs EI/RETI. This callback publishes a pending tick
; only, touches common state only, and returns with RET.
ctc_callback_template:
	ld a,(tick_phase)
	ld hl,#tick_rate
	add a,(hl)
	jr c,ctc_phase_overflow
	cp #CTC_BASE_RATE
	jr c,ctc_phase_store
	sub #CTC_BASE_RATE
	jr ctc_tick_due
ctc_phase_overflow:
	add a,#(256 - CTC_BASE_RATE)
ctc_tick_due:
	ld (tick_phase),a
	ld a,(ticks_pending)
	cp #0xff
	jr z,ctc_isr_done
	inc a
	ld (ticks_pending),a
	jr ctc_isr_done
ctc_phase_store:
	ld (tick_phase),a
ctc_isr_done:
	ret
ctc_callback_end:
	.if (ctc_callback_end - ctc_callback_template) - 0x0027
	.error 3
	.endif

puts:
	push ix
	ld c,#BDOS_PRINT
	call BDOS
	pop ix
	ret

	.include "src/ztr.asm"
	.include "src/player.asm"
	.include "src/sn76489.asm"
	.include "src/ui.asm"

; ---------------------------------------------------------------------------
msg_banner:
	.ascii "SNTRACK 0.1 - Zephyr-80 16-channel PSG tracker\r\n$"
msg_load_error:
	.ascii "Error: cannot load ZTR file (max 20 KiB).\r\n$"
msg_format_error:
	.ascii "Error: malformed or unsupported ZTR v1 file.\r\n$"
msg_ctc_error:
	.ascii "Error: CTC channel 0 is unavailable.\r\n$"
msg_runtime_fault:
	.ascii "\r\nSNTRACK fault $"
msg_runtime_row:
	.ascii " R$"
msg_runtime_end:
	.ascii "\r\n$"
msg_done:
	.ascii "\r\nPlayback stopped.\r\n$"

ztr_magic:
	.ascii "ZTR1"

entry_sp:	.dw 0
ctc_active:	.ds 1
fault_code:	.ds 1

playing:	.ds 1
aborted:	.ds 1
song_speed:	.ds 1
tick_in_row:	.ds 1
current_order:	.ds 1
current_row:	.ds 1
order_count:	.ds 1
pattern_length_lo: .ds 1
pattern_length_hi: .ds 1
pattern_count:	.dw 0
instrument_count: .ds 1
row_changed:	.ds 1
current_channel: .ds 1
elapsed_subticks: .ds 1
elapsed_seconds: .ds 1
elapsed_minutes: .ds 1

order_base:	.dw 0
current_order_ptr: .dw 0
instrument_base: .dw 0
pattern_dir_base: .dw 0
note_table_base: .dw 0
title_ptr:	.dw 0

ui_page:	.ds 1
key_poll_reload: .ds 1
key_poll_count: .ds 1

file_fcb:	.ds FCB_BYTES
song_dma_ptr:	.dw 0
song_records_left: .ds 1

event_mask:	.ds 1
event_note:	.ds 1
event_instrument: .ds 1
event_volume:	.ds 1
event_effect:	.ds 1
event_parameter: .ds 1
event_modifier_flags: .ds 1
event_arpeggio: .ds 1
event_hairpin_rate: .ds 1
event_hairpin_ceiling: .ds 1

macro_slot:	.ds 1
macro_pointer:	.dw 0
macro_position:	.dw 0
macro_value:	.dw 0
macro_value_flags: .ds 1
macro_release_point: .dw 0
instrument_entry_pointer: .dw 0
wanted_pattern:	.ds 1
pitch_negative:	.ds 1

channel_state:	.ds (ZTR_CHANNELS * CHANNEL_STATE_BYTES)
state_guard:	.ds 1
