; SNTRACK.COM -- native Zephyr-80 tracker player.
;
; This CP/M transient loads one bounded ZTR file at 6000h.  CTC0 publishes
; playback ticks through a private IM2 page at 5E00h; row decoding, macro
; processing, UI output and all SN76489 writes remain in foreground code.

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

DEFAULT_FCB	= 0x005c
FCB_BYTES	= 36
FCB_RUNTIME	= 12

	; Reuse the BIOS project's authoritative Zephyr port constants.
	.include "../CPM2.2/src/platform_zephyr80.inc"

PSG0_PORT	= SOUND_PSG0_PORT
PSG_COUNT	= SOUND_PSG_COUNT

CTC0_PORT	= CTC0_CTRL
CTC_TIMER_PORT	= CTC0_PORT
CTC_VECTOR_BASE	= 0x00
APP_IM2_PAGE	= 0x5e
APP_IM2_BASE	= 0x5e00
APP_IM2_LIMIT	= 0x5f01	; 257 bytes: vector FFh fetches 5EFFh/5F00h
CTC_VECTOR_ADDR	= 0x5e00
APP_SIO_VECTOR_ADDR = 0x5e10
BIOS_SIO_VECTOR_ADDR = 0xdd10
UNEXPECTED_VECTOR_BYTE = 0x15	; repeated bytes form address 1515h
CTC_CONTROL	= 0xa7		; interrupt, timer, /256, auto, TC follows
CTC_STOP	= CTC_RESET_DISABLE
CTC_TC_180HZ	= 217
CTC_BASE_RATE	= 180

SONG_BUFFER	= 0x6000
SONG_BUFFER_END	= 0xb000
SONG_BUFFER_BYTES = SONG_BUFFER_END - SONG_BUFFER
PRIVATE_STACK	= 0xbff0

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
CHANNEL_STATE_BYTES = 64

; ---------------------------------------------------------------------------
start:
	ld (entry_sp),sp
	ld sp,#PRIVATE_STACK
	ld de,#msg_banner
	call puts

	call ztr_load
	jr c,start_load_error
	call ztr_init
	jr c,start_format_error
	call ui_init
	call ztr_play
	call ctc_setup

tracker_loop:
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

start_load_error:
	ld de,#msg_load_error
	call puts
	jr tracker_exit
start_format_error:
	ld de,#msg_format_error
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
ctc_setup:
	di
	ld a,i
	ld (saved_i),a
	ld hl,(CTC_VECTOR_ADDR)
	ld (saved_ctc_vector),hl

	; Fill 257 bytes, not 256: a directly wired device returns vector FFh and
	; makes the Z80 fetch its word across the page boundary at 5EFFh/5F00h.
	; Repeating 15h makes every default even vector, including FFh, resolve to
	; the fixed unexpected interrupt handler at 1515h.
	ld hl,#APP_IM2_BASE
	ld (hl),#UNEXPECTED_VECTOR_BYTE
	ld de,#(APP_IM2_BASE + 1)
	ld bc,#(APP_IM2_LIMIT - APP_IM2_BASE - 1)
	ldir

	; Preserve all eight possible BIOS SIO status-vector words.
	ld de,(BIOS_SIO_VECTOR_ADDR)
	ld hl,#APP_SIO_VECTOR_ADDR
	ld b,#8
ctc_setup_sio_vector:
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	djnz ctc_setup_sio_vector

	ld hl,#ctc_isr
	ld (CTC_VECTOR_ADDR),hl
	ld a,#CTC_VECTOR_BASE
	out (CTC0_PORT),a
	ld a,#CTC_CONTROL
	out (CTC_TIMER_PORT),a
	ld a,#CTC_TC_180HZ
	out (CTC_TIMER_PORT),a
	xor a
	ld (tick_phase),a
	ld a,#APP_IM2_PAGE
	ld i,a
	im 2
	ld a,#1
	ld (ctc_active),a
	ei
	ret

ctc_stop:
	ld a,(ctc_active)
	or a
	ret z
	di
	ld a,#CTC_STOP
	out (CTC_TIMER_PORT),a
	ld hl,(saved_ctc_vector)
	ld (CTC_VECTOR_ADDR),hl
	xor a
	out (CTC0_PORT),a
	ld a,(saved_i)
	ld i,a
	xor a
	ld (ctc_active),a
	ei
	ret

; ISR-safe: publishes a pending tick only.  No decoding, I/O or BDOS calls.
ctc_isr:
	push af
	push hl
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
	pop hl
	pop af
	ei
	reti

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
msg_done:
	.ascii "\r\nPlayback stopped.\r\n$"

ztr_magic:
	.ascii "ZTR1"

entry_sp:	.dw 0
saved_ctc_vector: .dw 0
saved_i:	.ds 1
ctc_active:	.ds 1
tick_phase:	.ds 1
ticks_pending:	.ds 1
unexpected_interrupts: .ds 1

playing:	.ds 1
aborted:	.ds 1
tick_rate:	.ds 1
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

; The default IM2 table is filled with 15h, so all unclaimed even vectors and
; the cross-page FFh vector fetch 1515h.  Keeping this handler at the matching
; address makes the entire fallback table safe without consuming song-buffer
; byte 6000h.  The preceding image must remain below this explicit placement.
	.org 0x1515
unexpected_isr:
	push af
	ld a,(unexpected_interrupts)
	cp #0xff
	jr z,unexpected_isr_done
	inc a
	ld (unexpected_interrupts),a
unexpected_isr_done:
	pop af
	ei
	reti
