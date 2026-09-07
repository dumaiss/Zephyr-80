; VGMPLAY.COM -- streamed SN76489 music player for Afternoon Blend PSG0.
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
; The application uses its own IM2 page at 7F00h: CTC0 vectors through 7F00h
; and the BIOS SIO vector is mirrored from DD10h to 7F10h. This avoids changing
; occupied BIOS bytes at DD00h while keeping console interrupts operational.
;
; The ISR advances the phase and publishes a pending tick. Stream decoding,
; PSG writes, BDOS calls and buffer filling all remain in foreground code. An
; inactive buffer is marked FILLING before BDOS can write it and READY only
; after its length is published.

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

DEFAULT_FCB	= 0x005c
FCB_BYTES	= 36
FCB_RUNTIME	= 12

PSG0_PORT	= 0xe0
PSG_MUTE0	= 0x9f

CTC0_PORT	= 0x40
CTC_TIMER_PORT	= CTC0_PORT
CTC_VECTOR_BASE	= 0x00
APP_IM2_PAGE	= 0x7f
APP_IM2_BASE	= 0x7f00
CTC_VECTOR_ADDR = 0x7f00
APP_SIO_VECTOR_ADDR = 0x7f10
BIOS_SIO_VECTOR_ADDR = 0xdd10
CTC_CONTROL	= 0xa7		; interrupt, timer, /256, auto, TC follows
CTC_STOP	= 0x03
CTC_TC_180HZ	= 217
CTC_BASE_RATE	= 180

BUFFER_BYTES	= 6144
BUFFER_RECORDS	= BUFFER_BYTES / 128
BUFFER0		= 0x8000
BUFFER1		= BUFFER0 + BUFFER_BYTES
PRIVATE_STACK	= 0xbff0

BUF_FREE	= 0
BUF_READY	= 1
BUF_ACTIVE	= 2
BUF_FILLING	= 3

ZVG_HEADER_BYTES = 16
ZVG_VERSION	= 1
ZVG_RATE_MAX	= CTC_BASE_RATE
ZVG_END		= 0x00
ZVG_WRITE	= 0x01
ZVG_WAIT16	= 0x02
ZVG_WAIT_SHORT0	= 0x40		; 40h..7Fh encode waits 1..64
ZVG_WAIT_SHORTN	= 0x80

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

	xor a
	ld (file_eof),a
	ld (format_error),a
	ld (file_io_error),a
	ld (underrun_count),a
	ld (buf0_state),a
	ld (buf1_state),a
	ld (playing),a
	ld (aborted),a
	ld (fill_active),a
	ld hl,#0
	ld (ctc_interrupt_count),hl
	ld (playback_tick_count),hl
	ld (psg_write_count),hl
	ld (unexpected_interrupt_count),hl
	ld (ticks_pending),a

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
	ld hl,#0
	ld (wait_ticks),hl

	; Apply time-zero writes before the first metadata-rate tick.
	call playback_tick
	call ctc_setup

player_loop:
	ld a,(playing)
	or a
	jr z,player_done

	; Claim at most one pending playback tick atomically. Stream decoding and PSG
	; writes run here in foreground, never in the CTC ISR.
	di
	ld a,(ticks_pending)
	or a
	jr z,player_no_tick
	dec a
	ld (ticks_pending),a
	ei
	ld hl,(playback_tick_count)
	inc hl
	ld (playback_tick_count),hl
	call playback_tick
	ld a,(playing)
	or a
	jr z,player_done

	; HID input is polled through BDOS at approximately ten polls per second.
	; without flooding the shared IOC command/storage transport.
	ld a,(key_poll_count)
	dec a
	ld (key_poll_count),a
	jr nz,player_housekeeping
	ld a,(key_poll_reload)
	ld (key_poll_count),a
	ld c,#BDOS_CONST
	call BDOS
	or a
	jr nz,user_abort
	jr player_housekeeping

player_no_tick:
	ei

player_housekeeping:
	; Never begin another SD record while playback already has work queued.
	; Drain delayed ticks first, then resume the incremental refill.
	di
	ld a,(ticks_pending)
	or a
	jr nz,player_pending_now
	ei
	call service_refill
	; Do not HALT when a tick arrived during housekeeping: it is already pending
	; and no new interrupt would be needed to process it.
	di
	ld a,(ticks_pending)
	or a
	jr nz,player_pending_now
	ei
	halt
	jr player_loop
player_pending_now:
	ei
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
	ld de,(fill_ptr)
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#file_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
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
	cp #ZVG_VERSION
	jr nz,validate_failed
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
; CTC channel 0: 180.0115 Hz hardware interrupt and metadata-rate scheduler.
ctc_setup:
	di
	ld a,i
	ld (saved_i),a
	ld hl,(CTC_VECTOR_ADDR)
	ld (saved_ctc_vector),hl

	; Make every even vector in the private page safe before enabling IM2.
	; Known SIO status vectors are replaced with the real BIOS SIO handler
	; below; anything unexpected is counted and dismissed with RETI.
	ld hl,#APP_IM2_BASE
	ld de,#unexpected_isr
	ld b,#128
ctc_setup_default_vector:
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	djnz ctc_setup_default_vector

	; Mirror all eight possible SIO status-vector words, 10h through 1Eh.
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
	ei
	ret

ctc_stop:
	di
	ld a,#CTC_STOP
	out (CTC_TIMER_PORT),a
	ld hl,(saved_ctc_vector)
	ld (CTC_VECTOR_ADDR),hl
	xor a				; restore the conventional CTC vector base
	out (CTC0_PORT),a
	ld a,(saved_i)
	ld i,a
	ei
	ret

; Minimal ISR: only AF and HL are touched and preserved. No stream parsing, PSG
; output, BDOS call or storage transfer is permitted here.
ctc_isr:
	push af
	push hl
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

unexpected_isr:
	push af
	push hl
	ld hl,(unexpected_interrupt_count)
	inc hl
	ld (unexpected_interrupt_count),hl
	pop hl
	pop af
	ei
	reti

; ---------------------------------------------------------------------------
; Process one metadata-rate tick. Multiple PSG writes at one timestamp emit in
; the same ISR. A wait of N means the next command is eligible N ticks later.
playback_tick:
	ld a,(playing)
	or a
	ret z
	ld hl,(wait_ticks)
	ld a,h
	or l
	jr z,decode_command
	dec hl
	ld (wait_ticks),hl
	ld a,h
	or l
	ret nz

decode_command:
	; A command may straddle the active-buffer boundary. If its operand is not
	; available yet, retry the whole command on the next tick rather than
	; interpreting the operand as a new opcode.
	ld hl,(stream_ptr)
	ld (command_start_ptr),hl
	ld a,(active_buffer)
	ld (command_start_buffer),a
	call stream_get_byte
	jr c,decode_underrun
	cp #ZVG_END
	jr z,decode_end
	cp #ZVG_WRITE
	jr z,decode_write
	cp #ZVG_WAIT16
	jr z,decode_wait16
	cp #ZVG_WAIT_SHORT0
	jr c,decode_bad
	cp #ZVG_WAIT_SHORTN
	jr nc,decode_bad
	and #0x3f
	inc a
	ld l,a
	ld h,#0
	ld (wait_ticks),hl
	ret

decode_write:
	call stream_get_byte
	jr c,decode_underrun
	out (PSG0_PORT),a
	ld hl,(psg_write_count)
	inc hl
	ld (psg_write_count),hl
	jr decode_command

decode_wait16:
	call stream_get_byte
	jr c,decode_underrun
	; stream_get_byte uses DE while comparing stream_ptr with stream_end, so
	; preserve the low operand byte across the second fetch on the stack.
	push af
	call stream_get_byte
	jr c,decode_wait16_underrun
	ld d,a
	pop af
	ld e,a
	ld (wait_ticks),de
	ld a,d
	or e
	jr z,decode_bad
	ret
decode_wait16_underrun:
	pop af
	jr decode_underrun

decode_end:
	xor a
	ld (playing),a
	ret

decode_bad:
	ld (bad_opcode),a
	ld hl,(command_start_ptr)
	ld (bad_address),hl
	ld a,(command_start_buffer)
	ld (bad_buffer),a
	ld a,#1
	ld (format_error),a
	xor a
	ld (playing),a
	ret

decode_underrun:
	ld a,(file_io_error)
	or a
	jr z,decode_underrun_retry
	xor a
	ld (playing),a
	ret
decode_underrun_retry:
	; stream_get_byte cannot change buffers unless the next buffer is READY.
	; Therefore a same-buffer underrun is safe to rewind. The buffer-mismatch
	; case is retained defensively; normal 128-byte record fills cannot exhaust
	; a newly selected buffer within one two- or three-byte command.
	ld a,(active_buffer)
	ld hl,#command_start_buffer
	cp (hl)
	jr nz,decode_underrun_count
	ld hl,(command_start_ptr)
	ld (stream_ptr),hl
decode_underrun_count:
	ld a,(underrun_count)
	cp #0xff
	jr z,decode_underrun_done
	inc a
	ld (underrun_count),a
decode_underrun_done:
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
	ld de,#msg_other_irq_count
	call puts
	ld hl,(unexpected_interrupt_count)
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
msg_other_irq_count:
	.ascii " other IRQs $"
msg_crlf:
	.ascii "\r\n$"
msg_underrun:
	.ascii "Playback ended with one or more SD buffer underruns.\r\n$"
msg_aborted:
	.ascii "Playback aborted.\r\n$"
msg_done:
	.ascii "Playback complete.\r\n$"

entry_sp:	.dw 0
saved_ctc_vector: .dw 0
saved_i:	.ds 1
wait_ticks:	.dw 0
stream_ptr:	.dw 0
stream_end:	.dw 0
command_start_ptr: .dw 0
bad_address:	.dw 0
ctc_interrupt_count: .dw 0
playback_tick_count: .dw 0
psg_write_count: .dw 0
unexpected_interrupt_count: .dw 0
buf0_len:	.dw 0
buf1_len:	.dw 0
fill_ptr:	.dw 0
fill_len:	.dw 0

playing:	.ds 1
aborted:	.ds 1
file_io_error:	.ds 1
ticks_pending:	.ds 1
key_poll_count:	.ds 1
format_error:	.ds 1
underrun_count:	.ds 1
tick_rate:	.ds 1
tick_phase:	.ds 1
key_poll_reload: .ds 1
active_buffer:	.ds 1
command_start_buffer: .ds 1
bad_opcode:	.ds 1
bad_buffer:	.ds 1
buf0_state:	.ds 1
buf1_state:	.ds 1
file_eof:	.ds 1
fill_id:	.ds 1
fill_left:	.ds 1
fill_active:	.ds 1

file_fcb:	.ds FCB_BYTES
