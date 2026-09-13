; VGMPLAY.COM -- streamed SN76489 music player for Afternoon Blend PSG0.
; Standalone VGMPlayer project source.
;
; Usage:
;   VGMPLAY B:MUSIC.ZVG
;
; ZVG is the compact stream produced by tools/compile_vgm.py. Consecutive VGM
; waits are collapsed and quantized to the VGM metadata rate. The player uses
; 6144-byte chunks, so files are not limited by the Z80 address space or the
; CP/M 32 KiB boundary. CP/M sequential reads advance through extents normally.
;
; CTC channel 0 runs from the 10 MHz CTC system clock in timer mode:
;   10,000,000 / (256 * 217) = 180.0115 Hz
; A phase accumulator derives the ZVGC header's requested 1-180 Hz tick rate;
; 60 Hz retains an exact divide-by-three schedule.
; The BIOS owns IM2.  This transient copies its CTC callback and all state the
; callback touches into the program interrupt reservation at E000h-E3FFh, then
; registers that callback through the Zephyr BDOS facade.  The callback consumes
; a compact command ring and writes PSG0 while foreground code performs normal
; BDOS reads into the application-bank file buffers.

	.module vgmplay
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

PSG0_PORT	= 0xe0
PSG_MUTE0	= 0x9f

CTC0_PORT	= 0x40
CTC_TIMER_PORT	= CTC0_PORT
CTC_CONTROL	= 0xa7		; interrupt, timer, /256, auto, TC follows
CTC_STOP	= 0x03
CTC_TC_180HZ	= 217
CTC_BASE_RATE	= 180

BUFFER_BYTES	= 6144
BUFFER_RECORDS	= BUFFER_BYTES / 128
BUFFER0		= 0x8000
BUFFER1		= BUFFER0 + BUFFER_BYTES
PRIVATE_STACK	= 0xbff0

; The complete callback, its state, and its callees must remain in this 1 KiB
; program-owned common reservation.  Foreground-only data stays in the normal
; application bank below E000h.
COMMON_ISR_CODE = 0xe000
COMMON_STATE_BASE = 0xe120
COMMON_RING_BASE = 0xe140
COMMON_RING_LIMIT = 0xe400

playing		= COMMON_STATE_BASE + 0
tick_rate	= COMMON_STATE_BASE + 1
tick_phase	= COMMON_STATE_BASE + 2
wait_ticks	= COMMON_STATE_BASE + 3	; word
ring_head	= COMMON_STATE_BASE + 5	; word, consumer-owned
ring_tail	= COMMON_STATE_BASE + 7	; word, producer-owned
ctc_interrupt_count = COMMON_STATE_BASE + 9	; word
playback_tick_count = COMMON_STATE_BASE + 11	; word
psg_write_count = COMMON_STATE_BASE + 13	; word
underrun_count	= COMMON_STATE_BASE + 15
format_error	= COMMON_STATE_BASE + 16
bad_opcode	= COMMON_STATE_BASE + 17
key_poll_count	= COMMON_STATE_BASE + 18
key_poll_reload = COMMON_STATE_BASE + 19
key_poll_due	= COMMON_STATE_BASE + 20
pending_irqs	= COMMON_STATE_BASE + 21
io_busy		= COMMON_STATE_BASE + 22

BUF_FREE	= 0
BUF_READY	= 1
BUF_ACTIVE	= 2
BUF_FILLING	= 3

ZVG_HEADER_BYTES = 16
ZVG_VERSION_V1	= 1
ZVG_VERSION	= 2
ZVG_RATE_MAX	= CTC_BASE_RATE
ZVG_END		= 0x00
ZVG_WRITE	= 0x01
ZVG_WAIT16	= 0x02
ZVG_WAIT_SHORT0	= 0x40		; 40h..7Fh encode waits 1..64
ZVG_WAIT_SHORTN	= 0x80
ZVG_WRITE_RUN0	= 0x80		; 80h..8Fh: 1..16 following PSG bytes
ZVG_WRITE_RUNN	= 0x90

; ---------------------------------------------------------------------------
start:
	ld (entry_sp),sp
	ld sp,#PRIVATE_STACK

	ld de,#msg_banner
	call puts
	call prepare_fcb
	jp c,usage_error
	call open_file
	jp c,open_error
	call common_prepare

	xor a
	ld (file_eof),a
	ld (file_io_error),a
	ld (buf0_state),a
	ld (buf1_state),a
	ld (aborted),a
	ld (fill_active),a
	ld (producer_done),a

	xor a
	call fill_buffer
	ld a,(file_io_error)
	or a
	jp nz,read_error_open
	ld a,(buf0_state)
	cp #BUF_READY
	jp nz,format_error_open
	call validate_header
	jp c,format_error_open

	; Make buffer 0 active after its 16-byte file header. Fill buffer 1 before
	; starting the clock so normal playback begins with a complete spare chunk.
	ld a,#BUF_ACTIVE
	ld (buf0_state),a
	xor a
	ld (active_buffer),a
	ld hl,#(BUFFER0 + ZVG_HEADER_BYTES)
	ld (stream_ptr),hl
	ld de,(buf0_len)
	ld hl,#BUFFER0
	add hl,de
	ld (stream_end),hl

	ld a,#1
	call fill_buffer
	ld a,(file_io_error)
	or a
	jp nz,read_error_open
	ld a,#1
	ld (playing),a
	call producer_fill_ring
	ld a,(format_error)
	or a
	jp nz,format_error_open
	call ctc_setup
	jp c,ctc_error_open

player_loop:
	ld a,(playing)
	or a
	jr z,player_done

	; Keep the common command ring full before issuing one potentially blocking
	; disk record read.  The ISR continues consuming commands during that read.
	call producer_fill_ring
	call service_refill
	ld a,(file_io_error)
	or a
	jr z,player_check_key
	xor a
	ld (playing),a
	jr player_done

player_check_key:
	ld a,(key_poll_due)
	or a
	jr z,player_wait
	xor a
	ld (key_poll_due),a
	ld c,#BDOS_CONST
	ld a,#1
	ld (io_busy),a
	call BDOS
	ld (bdos_result),a
	call service_pending_ticks
	ld a,(bdos_result)
	or a
	jr nz,user_abort

player_wait:
	halt
	jr player_loop

user_abort:
	xor a
	ld (playing),a
	inc a
	ld (aborted),a
	ld c,#BDOS_CONIN
	call BDOS
	jr player_done

player_done:
	call ctc_stop
	call mute_psg0
	call close_file
	ld a,(aborted)
	or a
	jr z,player_done_not_aborted
	ld de,#msg_aborted
	call puts
player_done_not_aborted:
	call print_runtime_counts
	ld a,(file_io_error)
	or a
	jr z,player_done_no_io_error
	ld de,#msg_read_error
	call puts
	jr exit
player_done_no_io_error:
	ld a,(format_error)
	or a
	jr z,check_underrun
	ld de,#msg_stream_error
	call puts
	ld a,(bad_opcode)
	call puthex8
	ld de,#msg_stream_buffer
	call puts
	ld a,(bad_buffer)
	call puthex8
	ld de,#msg_stream_address
	call puts
	ld hl,(bad_address)
	ld a,h
	push hl
	call puthex8
	pop hl
	ld a,l
	call puthex8
	ld de,#msg_stream_underruns
	call puts
	ld a,(underrun_count)
	call puthex8
	ld de,#msg_crlf
	call puts
	jr exit
check_underrun:
	ld a,(underrun_count)
	or a
	jr z,clean_done
	ld de,#msg_underrun
	call puts
	jr exit
clean_done:
	ld a,(aborted)
	or a
	jr nz,exit
	ld de,#msg_done
	call puts
exit:
	ld sp,(entry_sp)
	ret

usage_error:
	ld de,#msg_usage
	call puts
	jr exit
open_error:
	ld de,#msg_open_error
	call puts
	jr exit
format_error_open:
	ld de,#msg_format_error
	call puts
	call close_file
	jr exit
read_error_open:
	ld de,#msg_read_error
	call puts
	call close_file
	jr exit
ctc_error_open:
	xor a
	ld (playing),a
	call mute_psg0
	ld de,#msg_ctc_error
	call puts
	call close_file
	jr exit

; ---------------------------------------------------------------------------
; Copy the CCP's first default FCB and clear only its runtime portion.
; Carry is set if no filename was supplied.
prepare_fcb:
	ld a,(DEFAULT_FCB + 1)
	cp #' '
	jr z,prepare_fcb_missing
	ld hl,#DEFAULT_FCB
	ld de,#file_fcb
	ld bc,#FCB_BYTES
	ldir
	xor a
	ld hl,#(file_fcb + FCB_RUNTIME)
	ld b,#(FCB_BYTES - FCB_RUNTIME)
prepare_fcb_clear:
	ld (hl),a
	inc hl
	djnz prepare_fcb_clear
	or a
	ret
prepare_fcb_missing:
	scf
	ret

open_file:
	ld de,#file_fcb
	ld c,#BDOS_OPEN
	call BDOS
	inc a
	jr z,open_file_failed
	or a
	ret
open_file_failed:
	scf
	ret

close_file:
	ld de,#file_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	ret

; ---------------------------------------------------------------------------
; Fill one inactive 6144-byte half using 48 ordinary CP/M sequential records.
; Input: A = 0 for BUFFER0, nonzero for BUFFER1.
; The published length is record-granular; ZVG_END terminates the actual data.
; Startup calls this blocking wrapper before the CTC is enabled. Runtime refill
; uses fill_buffer_begin/fill_buffer_step so each foreground pass reads only one
; record and returns promptly to pending playback ticks.
fill_buffer:
	call fill_buffer_begin
fill_buffer_all:
	call fill_buffer_step
	ld a,(fill_active)
	or a
	jr nz,fill_buffer_all
	ret

; Start filling one free buffer. Input: A = buffer id 0 or 1.
fill_buffer_begin:
	ld (fill_id),a
	or a
	jr nz,fill_buffer1_begin
	ld a,#BUF_FILLING
	ld (buf0_state),a
	ld hl,#BUFFER0
	jr fill_begin
fill_buffer1_begin:
	ld a,#BUF_FILLING
	ld (buf1_state),a
	ld hl,#BUFFER1
fill_begin:
	ld (fill_ptr),hl
	ld hl,#0
	ld (fill_len),hl
	ld a,#BUFFER_RECORDS
	ld (fill_left),a
	ld a,#1
	ld (fill_active),a
	ret

; Read at most one 128-byte record into the buffer currently being filled.
fill_buffer_step:
	ld a,(fill_active)
	or a
	ret z
	; A full decoder/PSG callback can disrupt the timing-sensitive storage
	; transaction.  While inside BDOS, the callback queues raw CTC expirations;
	; replay them immediately after the 128-byte read returns.
	ld a,#1
	ld (io_busy),a
	ld de,(fill_ptr)
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#file_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	ld (bdos_result),a
	call service_pending_ticks
	ld a,(bdos_result)
	or a
	jr z,fill_record_ok
	cp #1
	jr z,fill_eof
	ld a,#1
	ld (file_io_error),a
	ld (file_eof),a
	jr fill_publish
fill_record_ok:
	ld hl,(fill_ptr)
	ld de,#128
	add hl,de
	ld (fill_ptr),hl
	ld hl,(fill_len)
	add hl,de
	ld (fill_len),hl
	ld a,(fill_left)
	dec a
	ld (fill_left),a
	ret nz
	jr fill_publish

fill_eof:
	ld a,#1
	ld (file_eof),a
fill_publish:
	xor a
	ld (fill_active),a
	ld hl,(fill_len)
	ld a,(fill_id)
	or a
	jr nz,fill_publish1
	ld (buf0_len),hl
	ld a,h
	or l
	jr z,fill_empty0
	ld a,#BUF_READY
	ld (buf0_state),a
	ret
fill_empty0:
	xor a
	ld (buf0_state),a
	ret
fill_publish1:
	ld (buf1_len),hl
	ld a,h
	or l
	jr z,fill_empty1
	ld a,#BUF_READY
	ld (buf1_state),a
	ret
fill_empty1:
	xor a
	ld (buf1_state),a
	ret

; Refill one inactive buffer incrementally. At most one BDOS sequential read is
; issued per call, and only one buffer may be FILLING at a time.
service_refill:
	ld a,(fill_active)
	or a
	jp nz,fill_buffer_step
	ld a,(file_eof)
	or a
	ret nz
	ld a,(buf0_state)
	or a
	jr nz,service_refill_check1
	xor a
	call fill_buffer_begin
	jp fill_buffer_step
service_refill_check1:
	ld a,(buf1_state)
	or a
	ret nz
	ld a,#1
	call fill_buffer_begin
	jp fill_buffer_step

; Drain CTC expirations accumulated while a foreground BDOS transaction was
; active.
; io_busy remains set while the common decoder runs, so a hardware tick can
; only append to pending_irqs and cannot race the foreground ring consumer.
; The zero-pending test and io_busy release are atomic with respect to CTC0.
service_pending_ticks:
	di
	ld a,(pending_irqs)
	or a
	jr z,service_pending_done
	dec a
	ld (pending_irqs),a
	ld a,(playing)
	or a
	jr z,service_pending_stopped
	ei
	call #(COMMON_ISR_CODE + common_active_irq - common_isr_template)
	jr service_pending_ticks
service_pending_stopped:
	xor a
	ld (pending_irqs),a
service_pending_done:
	xor a
	ld (io_busy),a
	ei
	ret

; ---------------------------------------------------------------------------
; Validate the fixed 16-byte ZVG header in BUFFER0.
validate_header:
	ld hl,#BUFFER0
	ld de,#zvg_magic
	ld b,#4
validate_magic_loop:
	ld a,(de)
	cp (hl)
	jr nz,validate_failed
	inc de
	inc hl
	djnz validate_magic_loop
	ld a,(hl)
	cp #ZVG_VERSION_V1
	jr z,validate_version_ok
	cp #ZVG_VERSION
	jr nz,validate_failed
validate_version_ok:
	inc hl
	ld a,(hl)
	or a
	jr z,validate_failed
	cp #(ZVG_RATE_MAX + 1)
	jr nc,validate_failed
	ld (tick_rate),a
	ld b,#0
validate_key_poll_rate:
	inc b
	sub #10
	jr z,validate_key_poll_ready
	jr nc,validate_key_poll_rate
validate_key_poll_ready:
	ld a,b
	ld (key_poll_reload),a
	ld (key_poll_count),a
	ld a,(BUFFER0 + 7)
	cp #ZVG_HEADER_BYTES
	jr nz,validate_failed
	or a
	ret
validate_failed:
	scf
	ret

; ---------------------------------------------------------------------------
; Copy the interrupt-only player into common RAM and clear its shared state.
; This runs before the callback is registered and before the CTC is enabled.
common_prepare:
	ld hl,#common_isr_template
	ld de,#COMMON_ISR_CODE
	ld bc,#(common_isr_template_end - common_isr_template)
	ldir
	xor a
	ld hl,#COMMON_STATE_BASE
	ld b,#(COMMON_RING_BASE - COMMON_STATE_BASE)
common_prepare_clear:
	ld (hl),a
	inc hl
	djnz common_prepare_clear
	ld hl,#COMMON_RING_BASE
	ld (ring_head),hl
	ld (ring_tail),hl
	ret

; ---------------------------------------------------------------------------
; CTC channel 0: 180.0115 Hz hardware interrupt and metadata-rate scheduler.
ctc_setup:
	ld b,#0				; CTC channel 0
	ld de,#COMMON_ISR_CODE
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

; ---------------------------------------------------------------------------
; Copied verbatim to COMMON_ISR_CODE.  Every data address is in common RAM and
; every control transfer is relative, so this remains runnable while the banked
; OS is active in mode 11. It consumes only complete commands published by
; producer_fill_ring; it never calls BDOS or touches application-bank memory.
; The BIOS dispatcher preserves all registers and performs EI/RETI; this
; callback must return with RET.
common_isr_template:
	; Storage receives bytes fast enough that even the normal phase/tick
	; accounting is too expensive inside its transaction.  The busy path is a
	; bounded ~60 T-states: queue the raw CTC expiration and replay it afterwards.
	ld a,(io_busy)
	or a
	jr z,common_active_irq
	ld hl,#pending_irqs
	inc (hl)
	ret nz
	dec (hl)			; saturate at FFh
	ret

common_active_irq:
	ld hl,(ctc_interrupt_count)
	inc hl
	ld (ctc_interrupt_count),hl

	; Accumulate the header's requested tick rate against the approximately
	; 180 Hz hardware interrupt. The phase stays in the range 0..179.
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
	ld a,(playing)
	or a
	jr z,common_quick_done
	ld hl,(playback_tick_count)
	inc hl
	ld (playback_tick_count),hl

	; Schedule foreground keyboard polling without making a BDOS call here.
	ld a,(key_poll_count)
	dec a
	ld (key_poll_count),a
	jr nz,common_process_tick
	ld a,(key_poll_reload)
	ld (key_poll_count),a
	ld a,#1
	ld (key_poll_due),a

common_process_tick:
	ld hl,(wait_ticks)
	ld a,h
	or l
	jr z,common_decode_begin
	dec hl
	ld (wait_ticks),hl
	ld a,h
	or l
	jr z,common_decode_begin

common_quick_done:
	ret

ctc_phase_store:
	ld (tick_phase),a
	jr common_quick_done

common_decode_begin:
	ld hl,(ring_head)
common_decode_next:
	; The producer publishes ring_tail only after a complete command is copied.
	ld de,(ring_tail)
	ld a,h
	cp d
	jr nz,common_opcode_ready
	ld a,l
	cp e
	jr nz,common_opcode_ready
	ld a,(underrun_count)
	cp #0xff
	jr z,common_quick_done
	inc a
	ld (underrun_count),a
	jr common_quick_done
common_opcode_ready:
	ld b,(hl)
	inc hl
	ld a,h
	cp #(COMMON_RING_LIMIT >> 8)
	jr nz,common_opcode_advanced
	ld hl,#COMMON_RING_BASE
common_opcode_advanced:
	ld (ring_head),hl
	ld a,b
	cp #ZVG_END
	jr z,common_decode_end
	cp #ZVG_WRITE
	jr nz,common_not_single_write
	ld b,#1
	jr common_decode_write_run
common_not_single_write:
	cp #ZVG_WAIT16
	jr z,common_decode_wait16
	cp #ZVG_WAIT_SHORT0
	jr c,common_decode_bad
	cp #ZVG_WAIT_SHORTN
	jr c,common_decode_short
	cp #ZVG_WRITE_RUNN
	jr nc,common_decode_bad
	and #0x0f
	inc a
	ld b,a
common_decode_write_run:
	ld c,(hl)
	inc hl
	ld a,h
	cp #(COMMON_RING_LIMIT >> 8)
	jr nz,common_run_advanced
	ld hl,#COMMON_RING_BASE
common_run_advanced:
	ld (ring_head),hl
	ld a,c
	out (PSG0_PORT),a
	ld de,(psg_write_count)
	inc de
	ld (psg_write_count),de
	djnz common_decode_write_run
	jr common_decode_next

common_decode_short:
	and #0x3f
	inc a
	ld l,a
	ld h,#0
	ld (wait_ticks),hl
	jr common_isr_done

common_decode_wait16:
	ld e,(hl)
	inc hl
	ld a,h
	cp #(COMMON_RING_LIMIT >> 8)
	jr nz,common_wait_low_advanced
	ld hl,#COMMON_RING_BASE
common_wait_low_advanced:
	ld d,(hl)
	inc hl
	ld a,h
	cp #(COMMON_RING_LIMIT >> 8)
	jr nz,common_wait_high_advanced
	ld hl,#COMMON_RING_BASE
common_wait_high_advanced:
	ld (ring_head),hl
	ld a,d
	or e
	jr z,common_decode_bad
	ld (wait_ticks),de
	jr common_isr_done

common_decode_end:
	xor a
	ld (playing),a
	jr common_isr_done

common_decode_bad:
	ld (bad_opcode),a
	ld a,#1
	ld (format_error),a
	xor a
	ld (playing),a
	jr common_isr_done

common_isr_done:
	ret
common_isr_template_end:
	; The copied callback must not overlap its shared state at E120h.
	.if (common_isr_template_end - common_isr_template) - 0x0108
	.error 3
	.endif

; ---------------------------------------------------------------------------
; Copy complete compact commands from the banked file stream to the common-RAM
; producer/consumer ring.  ring_tail is published under DI only after all bytes
; of one command are present, so the ISR never observes a partial command.
producer_fill_ring:
	ld a,(producer_done)
	or a
	ret nz
producer_fill_loop:
	call producer_has_command_free
	ret nc
	xor a
	ld (producer_end_pending),a
	ld hl,(stream_ptr)
	ld (command_start_ptr),hl
	ld a,(active_buffer)
	ld (command_start_buffer),a
	call stream_get_byte
	jp c,producer_not_ready
	ld (producer_command),a
	cp #ZVG_END
	jr z,producer_end
	cp #ZVG_WRITE
	jr z,producer_write
	cp #ZVG_WAIT16
	jr z,producer_wait16
	cp #ZVG_WAIT_SHORT0
	jr c,producer_bad
	cp #ZVG_WAIT_SHORTN
	jr c,producer_short
	cp #ZVG_WRITE_RUNN
	jr nc,producer_bad
	and #0x0f
	inc a
	ld b,a
	inc a
	ld (producer_command_len),a
	ld hl,#(producer_command + 1)
producer_write_run:
	push bc
	push hl
	call stream_get_byte
	pop hl
	pop bc
	jr c,producer_not_ready
	ld (hl),a
	inc hl
	djnz producer_write_run
	jr producer_publish

producer_short:
	ld a,#1
	ld (producer_command_len),a
	jr producer_publish

producer_write:
	call stream_get_byte
	jr c,producer_not_ready
	ld (producer_command + 1),a
	ld a,#2
	ld (producer_command_len),a
	jr producer_publish

producer_wait16:
	call stream_get_byte
	jr c,producer_not_ready
	ld (producer_command + 1),a
	call stream_get_byte
	jr c,producer_not_ready
	ld (producer_command + 2),a
	ld b,a
	ld a,(producer_command + 1)
	or b
	jr z,producer_bad_saved
	ld a,#3
	ld (producer_command_len),a
	jr producer_publish

producer_end:
	ld a,#1
	ld (producer_end_pending),a
	ld (producer_command_len),a
	jr producer_publish

producer_bad_saved:
	ld a,(producer_command)
producer_bad:
	ld (bad_opcode),a
	ld hl,(command_start_ptr)
	ld (bad_address),hl
	ld a,(command_start_buffer)
	ld (bad_buffer),a
	ld a,#1
	ld (format_error),a
	xor a
	ld (playing),a
	ld a,#1
	ld (producer_done),a
	ret

producer_not_ready:
	; A same-buffer partial command can be retried after more file data arrives.
	; A buffer change occurs only to a fully READY 6144-byte buffer, so it cannot
	; normally run out inside this maximum-three-byte command.
	ld a,(active_buffer)
	ld hl,#command_start_buffer
	cp (hl)
	ret nz
	ld hl,(command_start_ptr)
	ld (stream_ptr),hl
	ret

producer_publish:
	ld hl,(ring_tail)
	ld de,#producer_command
	ld a,(producer_command_len)
	ld b,a
producer_publish_loop:
	ld a,(de)
	ld (hl),a
	inc de
	call producer_advance_hl
	djnz producer_publish_loop
	; The ISR cannot interrupt the 16-bit tail publication.
	di
	ld (ring_tail),hl
	ei
	ld a,(producer_end_pending)
	or a
	jp z,producer_fill_loop
	ld a,#1
	ld (producer_done),a
	ret

; Carry set if the maximum 17-byte command can be added without head == tail.
producer_has_command_free:
	di
	ld de,(ring_head)
	ei
	ld hl,(ring_tail)
	ld b,#17
producer_space_loop:
	call producer_advance_hl
	ld a,h
	cp d
	jr nz,producer_space_next
	ld a,l
	cp e
	jr z,producer_no_space
producer_space_next:
	djnz producer_space_loop
	scf
	ret
producer_no_space:
	or a
	ret

producer_advance_hl:
	inc hl
	ld a,h
	cp #(COMMON_RING_LIMIT >> 8)
	ret nz
	ld hl,#COMMON_RING_BASE
	ret

; Return the next stream byte in A. Carry indicates that the next buffer is not
; READY yet. Buffer publication and state changes are single-byte atomic.
stream_get_byte:
	ld hl,(stream_ptr)
	ld de,(stream_end)
	ld a,h
	cp d
	jr nz,stream_byte_ready
	ld a,l
	cp e
	jr nz,stream_byte_ready

	ld a,(active_buffer)
	or a
	jr nz,stream_swap_to0
	ld a,(buf1_state)
	cp #BUF_READY
	jr nz,stream_not_ready
	xor a
	ld (buf0_state),a
	ld a,#BUF_ACTIVE
	ld (buf1_state),a
	ld a,#1
	ld (active_buffer),a
	ld hl,#BUFFER1
	ld de,(buf1_len)
	add hl,de
	ld (stream_end),hl
	ld hl,#BUFFER1
	ld (stream_ptr),hl
	jr stream_get_byte

stream_swap_to0:
	ld a,(buf0_state)
	cp #BUF_READY
	jr nz,stream_not_ready
	xor a
	ld (buf1_state),a
	ld a,#BUF_ACTIVE
	ld (buf0_state),a
	xor a
	ld (active_buffer),a
	ld hl,#BUFFER0
	ld de,(buf0_len)
	add hl,de
	ld (stream_end),hl
	ld hl,#BUFFER0
	ld (stream_ptr),hl
	jr stream_get_byte

stream_byte_ready:
	ld a,(hl)
	inc hl
	ld (stream_ptr),hl
	or a				; clear carry without changing the byte
	ret
stream_not_ready:
	scf
	ret

; ---------------------------------------------------------------------------
mute_psg0:
	ld a,#PSG_MUTE0
mute_psg0_loop:
	out (PSG0_PORT),a
	add a,#0x20
	jr nc,mute_psg0_loop
	ret

puts:
	ld c,#BDOS_PRINT
	jp BDOS

print_runtime_counts:
	ld de,#msg_ctc_count
	call puts
	ld hl,(ctc_interrupt_count)
	call puthex16
	ld de,#msg_tick_count
	call puts
	ld hl,(playback_tick_count)
	call puthex16
	ld de,#msg_write_count
	call puts
	ld hl,(psg_write_count)
	call puthex16
	ld de,#msg_crlf
	jp puts

puthex16:
	ld a,h
	push hl
	call puthex8
	pop hl
	ld a,l
	jp puthex8

; Print A as two uppercase hexadecimal digits through CP/M BDOS.
puthex8:
	push af
	rrca
	rrca
	rrca
	rrca
	call puthex4
	pop af
puthex4:
	and #0x0f
	add a,#'0'
	cp #('9' + 1)
	jr c,puthex4_emit
	add a,#('A' - '9' - 1)
puthex4_emit:
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

; ---------------------------------------------------------------------------
zvg_magic:
	.ascii "ZVGC"

msg_banner:
	.ascii "VGMPLAY 0.1 - streamed SN76489 player (metadata-timed CTC)\r\n$"
msg_usage:
	.ascii "Usage: VGMPLAY B:MUSIC.ZVG\r\n$"
msg_open_error:
	.ascii "Error: cannot open input file.\r\n$"
msg_format_error:
	.ascii "Error: not a supported ZVGC v1 file/rate.\r\n$"
msg_read_error:
	.ascii "Error: CP/M could not read the ZVGC file.\r\n$"
msg_ctc_error:
	.ascii "Error: CTC channel 0 is unavailable.\r\n$"
msg_stream_error:
	.ascii "Error: malformed compiled command stream; opcode $"
msg_stream_buffer:
	.ascii " buffer $"
msg_stream_address:
	.ascii " address $"
msg_stream_underruns:
	.ascii " underruns $"
msg_ctc_count:
	.ascii "CTC IRQs $"
msg_tick_count:
	.ascii " ticks $"
msg_write_count:
	.ascii " PSG writes $"
msg_crlf:
	.ascii "\r\n$"
msg_underrun:
	.ascii "Playback ended with one or more SD buffer underruns.\r\n$"
msg_aborted:
	.ascii "Playback aborted.\r\n$"
msg_done:
	.ascii "Playback complete.\r\n$"

entry_sp:	.dw 0
stream_ptr:	.dw 0
stream_end:	.dw 0
command_start_ptr: .dw 0
bad_address:	.dw 0
buf0_len:	.dw 0
buf1_len:	.dw 0
fill_ptr:	.dw 0
fill_len:	.dw 0

aborted:	.ds 1
ctc_active:	.ds 1
bdos_result:	.ds 1
file_io_error:	.ds 1
active_buffer:	.ds 1
command_start_buffer: .ds 1
bad_buffer:	.ds 1
buf0_state:	.ds 1
buf1_state:	.ds 1
file_eof:	.ds 1
fill_id:	.ds 1
fill_left:	.ds 1
fill_active:	.ds 1
producer_done:	.ds 1
producer_end_pending: .ds 1
producer_command_len: .ds 1
producer_command: .ds 17

file_fcb:	.ds FCB_BYTES
