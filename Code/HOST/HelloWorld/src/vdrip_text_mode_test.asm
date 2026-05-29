; Zephyr-80 Virtual Drip text mode hello world test.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Load with monitor:
;   L
;   G 8000
;
; This test receives Virtual Drip terminal input packets and echoes minimal
; ANSI-style text input through the TMS9928A text name table.
;
; The Z80 owns VDP sequencing because it is single-threaded: foreground code
; queues received text and emits VDP packets in controlled bursts. The proxy
; owns asynchronous keyboard gating because VNC keyboard events can arrive at
; any time while these VDP bursts are in progress.

	.module vdrip_text_hello
	.area CODE (ABS)
	.org 0x8000

; ---------------------------------------------------------------------------
; SIO0/B, matching monitor / Virtual Drip wiring.
; ---------------------------------------------------------------------------

VDRIP_DATA		= 0x22
VDRIP_CTRL		= 0x23
SIO_RR0_TX_EMPTY	= 0x04

; ---------------------------------------------------------------------------
; Virtual Drip packet protocol.
;
; Current wire format:
;   A5 5A LEN TYPE PAYLOAD... CRC
;
; LEN = LEN + TYPE + PAYLOAD + CRC
; Therefore:
;   zero-payload packet LEN = 3
;   one-byte payload packet LEN = 4
; ---------------------------------------------------------------------------

PACKET_SYNC0		= 0xa5
PACKET_SYNC1		= 0x5a

PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_TERMINAL_INPUT	= 0x05
PACKET_RESET		= 0x06
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08
PACKET_CURSOR_COMMAND	= 0x09

CURSOR_ENABLE		= 0x01
CURSOR_SHOW		= 0x02
CURSOR_SET_POSITION	= 0x04
CURSOR_SET_STYLE	= 0x06
CURSOR_SET_BLINK	= 0x07
CURSOR_SET_COLOR	= 0x08

CURSOR_STYLE_UNDERLINE	= 0x01

VDRIP_WIRE_OVERHEAD	= 0x03

STARTUP_DELAY_UNITS = 0x34

; ---------------------------------------------------------------------------
; TMS9928A layout.
; ---------------------------------------------------------------------------

PATTERN_TABLE		= 0x0000
NAME_TABLE		= 0x3800

TEXT_COLUMNS		= 40
TEXT_ROWS		= 24
TEXT_CELLS		= 960		; 40 * 24

; Font assumptions.
; msxfont.inc should provide 96 chars, ASCII 20h-7Fh, 8 bytes each.
FONT_FIRST_CHAR		= 0x20
FONT_CHAR_COUNT		= 0x60
FONT_BYTES		= FONT_CHAR_COUNT * 8

; BIOS SIO helper entry points.
BIOS_SIO_CORE_ENABLE_INTERRUPTS = 0xdd91
BIOS_SIO_REGISTER_RX_SINK       = 0xdde4
BIOS_SIO_RX_KICK                = 0xde6d
SIO_CH_CONSOLE                  = 0x00

; Parser states.
VDRIP_RX_WAIT_SYNC0 = 0x00
VDRIP_RX_WAIT_SYNC1 = 0x01
VDRIP_RX_LEN        = 0x02
VDRIP_RX_BODY       = 0x03

; Minimal terminal parser states.
TERM_STATE_NORMAL   = 0x00
TERM_STATE_ESC      = 0x01
TERM_STATE_CSI      = 0x02

; Receive ring.
VDRIP_RX_BUFFER_SIZE = 0x40
VDRIP_RX_BUFFER_MASK = VDRIP_RX_BUFFER_SIZE - 1

; Max payload = 16, plus LEN + TYPE + CRC = 3.
VDRIP_PACKET_PAYLOAD_MAX = 0x10
VDRIP_PACKET_BODY_MAX    = VDRIP_PACKET_PAYLOAD_MAX + VDRIP_WIRE_OVERHEAD

VDRIP_RX_RTS_HIGH_WATER = 0x04
VDRIP_RX_RTS_LOW_WATER  = 0x00



; SIO0/B RTS.
SIO0B_WR5_RTS_OFF = 0xe8
SIO0B_WR5_RTS_ON  = 0xea

VDRIP_RX_KICK_SPINS = 0x10

TEXTQ_SIZE		= 0x80
TEXTQ_MASK		= TEXTQ_SIZE - 1
TEXTQ_RTS_HIGH_WATER    = 0x08
TEXTQ_RTS_LOW_WATER     = 0x00

start:
	call delay_before_start

	; Hold host input while we initialize the display.
	call vdrip_rts_release_raw

	call vdrip_send_reset
	call vdrip_send_ping

	call text_init_vdp
	call text_load_font
	call text_clear_screen

	ld hl,#hello_msg
	call text_print_string

	; Echo input starts on row 1.
	xor a
	ld (text_col),a
	ld a,#0x01
	ld (text_row),a
	call vdrip_cursor_init

	call vdrip_send_frame_mark

	; Now take over SIO0/B RX.
	call vdrip_rx_init
	call vdrip_register_rx_sink
	call #BIOS_SIO_CORE_ENABLE_INTERRUPTS

	; Ready for host keyboard packets.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

main_loop:
	call vdrip_rx_kick_pending
	call vdrip_poll_rx
	call textq_render_one
	jr main_loop

delay_before_start:
	ld b,#STARTUP_DELAY_UNITS

delay_before_start_loop:
	call delay_unit
	djnz delay_before_start_loop
	ret

delay_unit:
	ld de,#0xffff

delay_unit_loop:
	dec de
	ld a,d
	or e
	jr nz,delay_unit_loop
	ret    

vdrip_rx_init:
	xor a
	ld (vdrip_rx_head),a
	ld (vdrip_rx_tail),a
	ld (vdrip_rx_count),a
	ld (vdrip_parse_state),a
	ld (vdrip_parse_len_store),a
	ld (vdrip_parse_remaining),a
	ld (vdrip_parse_payload_index),a
	ld (vdrip_rx_rts_released),a
	ld (textq_head),a
	ld (textq_tail),a
	ld (textq_count),a    
	ld (term_state),a
	ld (rx_drop_count),a
	ld (textq_drop_count),a
	ld (crc_fail_count),a
	ld (packet_ok_count),a
	ld (key_echo_count),a
	ld (rts_release_count),a
	ld (rts_assert_count),a
	ret


vdrip_register_rx_sink:
	di
	ld a,#SIO_CH_CONSOLE
	ld hl,#vdrip_rx_sink
	call #BIOS_SIO_REGISTER_RX_SINK
	ei
	ret


vdrip_rx_sink:
	cp #SIO_CH_CONSOLE
	ret nz

	ld a,(vdrip_rx_count)
	cp #VDRIP_RX_BUFFER_SIZE
	jr nc,vdrip_rx_sink_full

	ld hl,#vdrip_rx_buffer
	ld a,(vdrip_rx_head)
	ld e,a
	ld d,#0x00
	add hl,de

	ld (hl),c

	ld a,(vdrip_rx_head)
	inc a
	and #VDRIP_RX_BUFFER_MASK
	ld (vdrip_rx_head),a

	ld a,(vdrip_rx_count)
	inc a
	ld (vdrip_rx_count),a

	call vdrip_rx_maybe_release_rts
	ret


vdrip_rx_sink_full:
	ld a,(rx_drop_count)
	inc a
	ld (rx_drop_count),a

	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret


vdrip_rx_get_byte:
	di

	ld a,(vdrip_rx_count)
	or a
	jr nz,vdrip_rx_get_have_byte

	ei
	ld a,#0x01
	ret

vdrip_rx_get_have_byte:
	ld hl,#vdrip_rx_buffer
	ld a,(vdrip_rx_tail)
	ld e,a
	ld d,#0x00
	add hl,de

	ld c,(hl)

	ld a,(vdrip_rx_tail)
	inc a
	and #VDRIP_RX_BUFFER_MASK
	ld (vdrip_rx_tail),a

	ld a,(vdrip_rx_count)
	dec a
	ld (vdrip_rx_count),a

	call vdrip_rx_maybe_assert_rts

	ei
	xor a
	ret


vdrip_rx_kick_pending:
	ld b,#VDRIP_RX_KICK_SPINS

vdrip_rx_kick_pending_loop:
	ld a,#SIO_CH_CONSOLE
	call #BIOS_SIO_RX_KICK
	djnz vdrip_rx_kick_pending_loop
	ret

vdrip_rts_assert_raw:
	ld a,(rts_assert_count)
	inc a
	ld (rts_assert_count),a

	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_ON
	out (VDRIP_CTRL),a
	xor a
	ret


vdrip_rts_release_raw:
	ld a,(rts_release_count)
	inc a
	ld (rts_release_count),a

	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (VDRIP_CTRL),a
	xor a
	ret


vdrip_rx_maybe_release_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret nz

	ld a,(vdrip_rx_count)
	cp #VDRIP_RX_RTS_HIGH_WATER
	ret c

	call vdrip_rts_release_raw

	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret


vdrip_rx_maybe_assert_rts:
	jp app_maybe_resume_rts

vdrip_poll_rx:
	call vdrip_rx_get_byte
	or a
	ret nz

	ld a,c
	call vdrip_parse_rx_byte
	jr vdrip_poll_rx


vdrip_parse_rx_byte:
	ld c,a

	ld a,(vdrip_parse_state)
	cp #VDRIP_RX_WAIT_SYNC0
	jr z,vdrip_parse_wait_sync0

	cp #VDRIP_RX_WAIT_SYNC1
	jr z,vdrip_parse_wait_sync1

	cp #VDRIP_RX_LEN
	jr z,vdrip_parse_len

	cp #VDRIP_RX_BODY
	jr z,vdrip_parse_body

	xor a
	ld (vdrip_parse_state),a
	ret


vdrip_parse_wait_sync0:
	ld a,c
	cp #PACKET_SYNC0
	ret nz

	ld a,#VDRIP_RX_WAIT_SYNC1
	ld (vdrip_parse_state),a
	ret


vdrip_parse_wait_sync1:
	ld a,c
	cp #PACKET_SYNC1
	jr z,vdrip_parse_wait_sync_have

	cp #PACKET_SYNC0
	jr z,vdrip_parse_wait_sync_keep

	xor a
	ld (vdrip_parse_state),a
	ret

vdrip_parse_wait_sync_keep:
	ld a,#VDRIP_RX_WAIT_SYNC1
	ld (vdrip_parse_state),a
	ret

vdrip_parse_wait_sync_have:
	ld a,#VDRIP_RX_LEN
	ld (vdrip_parse_state),a
	ret


vdrip_parse_len:
	ld a,c
	cp #VDRIP_WIRE_OVERHEAD
	jp c,vdrip_parse_reset

	cp #VDRIP_PACKET_BODY_MAX + 1
	jp nc,vdrip_parse_reset

	; body[0] = LEN
	ld hl,#vdrip_packet_body
	ld (hl),c

	ld (vdrip_parse_len_store),a
	dec a
	ld (vdrip_parse_remaining),a

	ld a,#0x01
	ld (vdrip_parse_payload_index),a

	ld a,#VDRIP_RX_BODY
	ld (vdrip_parse_state),a
	ret


vdrip_parse_body:
	ld hl,#vdrip_packet_body
	ld a,(vdrip_parse_payload_index)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld a,(vdrip_parse_payload_index)
	inc a
	ld (vdrip_parse_payload_index),a

	ld a,(vdrip_parse_remaining)
	dec a
	ld (vdrip_parse_remaining),a
	jr z,vdrip_parse_body_done
	ret


vdrip_parse_body_done:
	call vdrip_packet_crc_valid
	jp nz,vdrip_parse_crc_failed

	ld a,(packet_ok_count)
	inc a
	ld (packet_ok_count),a

	call vdrip_parse_apply_terminal_input
	jr vdrip_parse_reset


vdrip_packet_crc_valid:
	ld c,#0x00
	ld hl,#vdrip_packet_body
	ld a,(vdrip_parse_len_store)
	dec a
	ld b,a

vdrip_packet_crc_loop:
	ld a,(hl)
	call crc8_update
	inc hl
	djnz vdrip_packet_crc_loop

	; HL points at received CRC.
	ld a,(hl)
	cp c
	ret


vdrip_parse_reset:
	xor a
	ld (vdrip_parse_state),a
	ret  

vdrip_parse_apply_terminal_input:
	ld a,(vdrip_packet_body + 1)
	cp #PACKET_TERMINAL_INPUT
	ret nz

	; payload_count = LEN - (LEN + TYPE + CRC)
	ld a,(vdrip_packet_body)
	sub #VDRIP_WIRE_OVERHEAD
	ret z

	ld (terminal_payload_count),a

	ld hl,#(vdrip_packet_body + 2)
	ld (terminal_payload_ptr),hl

vdrip_terminal_enqueue_loop:
	ld hl,(terminal_payload_ptr)
	ld a,(hl)
	inc hl
	ld (terminal_payload_ptr),hl

	call textq_put_ascii
	ld a,(key_echo_count)
	inc a
	ld (key_echo_count),a    

	ld a,(terminal_payload_count)
	dec a
	ld (terminal_payload_count),a
	jr nz,vdrip_terminal_enqueue_loop
	ret

; ---------------------------------------------------------------------------
; textq_put_ascii
;
; Input:
;   A = terminal input byte
;
; Called from foreground parser, not ISR.
; Fast: only enqueues into a RAM queue.
; ---------------------------------------------------------------------------

term_process_byte:
	ld c,a

	ld a,(term_state)
	cp #TERM_STATE_ESC
	jr z,term_process_esc

	cp #TERM_STATE_CSI
	jr z,term_process_csi

	ld a,c
	cp #0x1b
	jr z,term_enter_esc

	cp #0x08
	jr z,term_backspace

	cp #0x09
	jr z,term_tab

	; Enter sends CR. LF is tolerated as a newline.
	cp #0x0d
	jp z,text_put_newline

	cp #0x0a
	jp z,text_put_newline

	cp #0x20
	ret c
	cp #0x7f
	ret nc

	jr text_put_printable

term_enter_esc:
	ld a,#TERM_STATE_ESC
	ld (term_state),a
	ret

term_process_esc:
	xor a
	ld (term_state),a

	ld a,c
	cp #'[
	ret nz

	ld a,#TERM_STATE_CSI
	ld (term_state),a
	ret

term_process_csi:
	xor a
	ld (term_state),a

	ld a,c
	cp #'A
	jp z,term_cursor_up

	cp #'B
	jp z,term_cursor_down

	cp #'C
	jp z,term_cursor_right

	cp #'D
	jp z,term_cursor_left

	cp #'H
	jp z,term_cursor_home

	cp #'F
	jp z,term_cursor_end

	; Unsupported CSI, including ESC [ 3 ~ delete, is ignored.
	ret

text_put_printable:
	; Input:
	;   A = printable ASCII

	push af

	call text_cursor_to_vram

	pop af
	call vdp_write_data_byte

	call text_advance_cursor
	call vdrip_cursor_set_position_current
	ret

text_put_newline:
	call text_newline
	call vdrip_cursor_set_position_current
	ret

term_backspace:
	ld a,(text_col)
	or a
	ret z

	dec a
	ld (text_col),a

	call text_cursor_to_vram
	ld a,#0x20
	call vdp_write_data_byte
	call vdrip_cursor_set_position_current
	ret

term_tab:
	; Minimal tab: move to the next 4-column stop, wrapping if needed.
	call text_advance_cursor
	ld a,(text_col)
	and #0x03
	jr nz,term_tab

	call vdrip_cursor_set_position_current
	ret

term_cursor_up:
	ld a,(text_row)
	cp #0x01
	ret z

	dec a
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret

term_cursor_down:
	ld a,(text_row)
	cp #(TEXT_ROWS - 1)
	ret nc

	inc a
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret

term_cursor_left:
	ld a,(text_col)
	or a
	ret z

	dec a
	ld (text_col),a
	call vdrip_cursor_set_position_current
	ret

term_cursor_right:
	ld a,(text_col)
	cp #(TEXT_COLUMNS - 1)
	ret nc

	inc a
	ld (text_col),a
	call vdrip_cursor_set_position_current
	ret

term_cursor_home:
	; Row 0 is the static HELLO WORLD header; home goes to row 1, col 0.
	xor a
	ld (text_col),a
	ld a,#0x01
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret

term_cursor_end:
	; Minimal end: end of the current editable line.
	ld a,#(TEXT_COLUMNS - 1)
	ld (text_col),a
	call vdrip_cursor_set_position_current
	ret

textq_put_ascii:
	ld c,a

	ld a,(textq_count)
	cp #TEXTQ_SIZE
	jr nc,textq_full

	ld hl,#textq_buffer
	ld a,(textq_head)
	ld e,a
	ld d,#0x00
	add hl,de

	ld (hl),c

	ld a,(textq_head)
	inc a
	and #TEXTQ_MASK
	ld (textq_head),a

	ld a,(textq_count)
	inc a
	ld (textq_count),a

	; If output queue is getting full, stop host input.
	cp #TEXTQ_RTS_HIGH_WATER
	ret c

	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret

textq_full:
	ld a,(textq_drop_count)
	inc a
	ld (textq_drop_count),a

	; Output renderer cannot keep up. Stop host.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret  

; ---------------------------------------------------------------------------
; text_newline
;
; Move cursor to column 0 of the next row.
; Does not send a frame mark; textq_render_one handles frame marks when the
; render queue drains.
; ---------------------------------------------------------------------------

text_advance_cursor:
	ld a,(text_col)
	inc a
	cp #TEXT_COLUMNS
	jr c,text_advance_store_col

	xor a
	ld (text_col),a
	jr text_newline_from_wrap


text_newline:
	xor a
	ld (text_col),a

text_newline_from_wrap:
	ld a,(text_row)
	inc a
	cp #TEXT_ROWS
	jr c,text_newline_store_row

	; Wrap to row 1 so HELLO WORLD on row 0 stays visible.
	ld a,#0x01

text_newline_store_row:
	ld (text_row),a
	ret

text_advance_store_col:
	ld (text_col),a
	ret    

; ---------------------------------------------------------------------------
; textq_render_one
;
; Render at most one queued character per main-loop pass.
;
; This keeps RX service responsive:
;   main_loop:
;     RX kick
;     RX parse
;     render one char
;     repeat
;
; RTS policy:
;   - keep host paused while rendering/backlogged
;   - send one frame mark only when the text queue becomes empty
;   - resume host only when RX ring and text queue are both empty/low
; ---------------------------------------------------------------------------

textq_render_one:
	ld a,(textq_count)
	or a
	jr nz,textq_render_have_char

	; Nothing to render. If RTS was released and both queues are now clear,
	; this may reassert RTS.
	jp app_maybe_resume_rts


textq_render_have_char:
	; Rendering is slow because it sends Virtual Drip VDP packets.
	; Pause host input while we consume this queued character.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	; C = next queued character.
	ld hl,#textq_buffer
	ld a,(textq_tail)
	ld e,a
	ld d,#0x00
	add hl,de

	ld c,(hl)

	; Advance tail.
	ld a,(textq_tail)
	inc a
	and #TEXTQ_MASK
	ld (textq_tail),a

	; Decrement count.
	ld a,(textq_count)
	dec a
	ld (textq_count),a

	; Interpret one terminal input byte and render any resulting text action.
	ld a,c
	call term_process_byte

	; If queue is now empty, emit one frame mark for the whole drained burst.
	ld a,(textq_count)
	or a
	jr nz,textq_render_no_frame

	call vdrip_send_frame_mark

textq_render_no_frame:
	call app_maybe_resume_rts
	ret

text_cursor_to_vram:
	ld hl,#NAME_TABLE

	ld a,(text_row)
	or a
	jr z,text_cursor_rows_done

	ld b,a
	ld de,#TEXT_COLUMNS

text_cursor_row_loop:
	add hl,de
	djnz text_cursor_row_loop

text_cursor_rows_done:
	ld a,(text_col)
	ld e,a
	ld d,#0x00
	add hl,de

	call vdp_set_vram_write_addr
	ret  

app_maybe_resume_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret z				; already asserted

	; RX ring must be empty.
	ld a,(vdrip_rx_count)
	or a
	ret nz

	; Text output queue must be empty.
	ld a,(textq_count)
	or a
	ret nz

	call vdrip_rts_assert_raw

	xor a
	ld (vdrip_rx_rts_released),a
	ret
; ---------------------------------------------------------------------------
; VDP text mode init.
; ---------------------------------------------------------------------------

text_init_vdp:
	; R0 = 0
	ld b,#0x00
	ld a,#0x00
	call vdp_write_register

	; R1:
	;   16K mode
	;   display on
	;   text mode
	;
	; Existing graphics mode used C0h.
	; Text mode adds bit 4, so D0h.
	ld b,#0x01
	ld a,#0xd0
	call vdp_write_register

	; R2 = name table base.
	ld b,#0x02
	ld a,#(NAME_TABLE >> 10)
	call vdp_write_register

	; R4 = pattern table base.
	ld b,#0x04
	ld a,#(PATTERN_TABLE >> 11)
	call vdp_write_register

	; R7 = foreground/background color.
	; F4h = white on blue.
	ld b,#0x07
	ld a,#0xf4
	call vdp_write_register

	ret


; ---------------------------------------------------------------------------
; Load font into pattern table.
;
; If the font blob starts at ASCII 20h, load it at pattern 20h * 8
; so writing ASCII bytes directly into the name table works.
; ---------------------------------------------------------------------------

text_load_font:
	ld hl,#(PATTERN_TABLE + (FONT_FIRST_CHAR * 8))
	call vdp_set_vram_write_addr

	ld hl,#msx_font_20_7f
	ld bc,#FONT_BYTES
	call vdp_write_data_block
	ret


; ---------------------------------------------------------------------------
; Clear 40x24 text screen to ASCII space.
; ---------------------------------------------------------------------------

text_clear_screen:
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr

	ld bc,#TEXT_CELLS
text_clear_loop:
	ld a,#0x20
	call vdp_write_data_byte

	dec bc
	ld a,b
	or c
	jr nz,text_clear_loop

	ret


; ---------------------------------------------------------------------------
; Print zero-terminated string at current VRAM address.
;
; Input:
;   HL = string pointer
; ---------------------------------------------------------------------------

text_print_string:
	; First pass: fixed address, top-left-ish.
	push hl
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr
	pop hl

text_print_string_loop:
	ld a,(hl)
	or a
	ret z

	call vdp_write_data_byte
	inc hl
	jr text_print_string_loop


; ---------------------------------------------------------------------------
; VDP helpers over Virtual Drip.
; ---------------------------------------------------------------------------

; Write TMS9928A register B with value A.
vdp_write_register:
	call vdrip_ctrl_write
	ld a,b
	or #0x80
	call vdrip_ctrl_write
	ret


; Set TMS9928A VRAM write address to HL.
vdp_set_vram_write_addr:
	ld a,l
	call vdrip_ctrl_write

	ld a,h
	and #0x3f
	or #0x40
	call vdrip_ctrl_write
	ret


; Write one byte to current TMS9928A data port.
; Input:
;   A = data byte
vdp_write_data_byte:
	jp vdrip_data_write


; Write BC bytes from HL to current TMS9928A data port address.
vdp_write_data_block:
	ld (block_ptr_store),hl
	ld (block_count_store),bc

vdp_write_data_block_loop:
	ld hl,(block_count_store)
	ld a,h
	or l
	ret z

	ld hl,(block_ptr_store)
	ld a,(hl)
	inc hl
	ld (block_ptr_store),hl

	call vdp_write_data_byte

	ld hl,(block_count_store)
	dec hl
	ld (block_count_store),hl

	jr vdp_write_data_block_loop


; ---------------------------------------------------------------------------
; Virtual Drip packet output.
; ---------------------------------------------------------------------------

vdrip_ctrl_write:
	push bc
	push de
	push hl

	ld e,a
	ld a,#PACKET_VDP_CTRL_WRITE
	call vdrip_send_packet1

	pop hl
	pop de
	pop bc
	ret


vdrip_data_write:
	push bc
	push de
	push hl

	ld e,a
	ld a,#PACKET_VDP_DATA_WRITE
	call vdrip_send_packet1

	pop hl
	pop de
	pop bc
	ret


vdrip_send_reset:
	ld a,#PACKET_RESET
	jp vdrip_send_packet0


vdrip_send_ping:
	ld a,#PACKET_PING
	jp vdrip_send_packet0


vdrip_send_frame_mark:
	ld a,#PACKET_FRAME_MARK
	jp vdrip_send_packet0


vdrip_cursor_init:
	call vdrip_cursor_set_color_yellow
	call vdrip_cursor_set_style_underline
	call vdrip_cursor_set_blink_default
	call vdrip_cursor_enable
	call vdrip_cursor_set_position_current
	call vdrip_cursor_show
	ret


vdrip_cursor_enable:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_ENABLE
	inc hl
	ld (hl),#0x01

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x02
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_cursor_show:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SHOW

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x01
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_cursor_set_position_current:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SET_POSITION
	inc hl
	ld a,(text_col)
	ld (hl),a
	inc hl
	ld a,(text_row)
	ld (hl),a

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x03
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_cursor_set_style_underline:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SET_STYLE
	inc hl
	ld (hl),#CURSOR_STYLE_UNDERLINE

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x02
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_cursor_set_blink_default:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SET_BLINK
	inc hl
	ld (hl),#0x01
	inc hl
	ld (hl),#0xf4
	inc hl
	ld (hl),#0x01

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x04
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_cursor_set_color_yellow:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SET_COLOR
	inc hl
	ld (hl),#0xff
	inc hl
	ld (hl),#0xff
	inc hl
	ld (hl),#0x00

	ld a,#PACKET_CURSOR_COMMAND
	ld b,#0x04
	ld hl,#packet_payload0
	jp vdrip_send_packet


; Send zero-payload packet.
; Input:
;   A = type
vdrip_send_packet0:
	ld b,#0x00
	ld hl,#packet_payload0
	jp vdrip_send_packet


; Send one-byte payload packet.
; Input:
;   A = type
;   E = payload byte
vdrip_send_packet1:
	push af
	ld a,e
	ld (packet_payload0),a
	pop af

	ld b,#0x01
	ld hl,#packet_payload0
	jp vdrip_send_packet


; Send Virtual Drip packet.
;
; Input:
;   A  = packet type
;   B  = payload length
;   HL = payload pointer
;
; Wire:
;   A5 5A LEN TYPE PAYLOAD CRC
;
; CRC covers:
;   LEN TYPE PAYLOAD
vdrip_send_packet:
	ld (packet_type_store),a

	ld a,b
	ld (packet_len_store),a
	add a,#VDRIP_WIRE_OVERHEAD
	ld (packet_wire_len_store),a

	ld (packet_ptr_store),hl

	push bc
	push de
	push hl

	; Calculate CRC.
	ld c,#0x00

	ld a,(packet_wire_len_store)
	call crc8_update

	ld a,(packet_type_store)
	call crc8_update

	ld hl,(packet_ptr_store)
	ld a,(packet_len_store)
	or a
	jr z,vdrip_send_packet_crc_done

	ld b,a
vdrip_send_packet_crc_loop:
	ld a,(hl)
	call crc8_update
	inc hl
	djnz vdrip_send_packet_crc_loop

vdrip_send_packet_crc_done:
	ld a,c
	ld (packet_crc_store),a

	; Send packet.
	ld a,#PACKET_SYNC0
	call vdrip_transport_putc

	ld a,#PACKET_SYNC1
	call vdrip_transport_putc

	ld a,(packet_wire_len_store)
	call vdrip_transport_putc

	ld a,(packet_type_store)
	call vdrip_transport_putc

	ld hl,(packet_ptr_store)
	ld a,(packet_len_store)
	or a
	jr z,vdrip_send_packet_send_crc

	ld b,a
vdrip_send_packet_payload_loop:
	ld a,(hl)
	call vdrip_transport_putc
	inc hl
	djnz vdrip_send_packet_payload_loop

vdrip_send_packet_send_crc:
	ld a,(packet_crc_store)
	call vdrip_transport_putc

	pop hl
	pop de
	pop bc
	ret


vdrip_transport_putc:
	push af

vdrip_transport_wait_tx:
	in a,(VDRIP_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,vdrip_transport_wait_tx

	pop af
	out (VDRIP_DATA),a
	ret

vdrip_parse_crc_failed:
	ld a,(crc_fail_count)
	inc a
	ld (crc_fail_count),a

	jp vdrip_parse_reset

; ---------------------------------------------------------------------------
; CRC-8 poly 07, same as proxy.
;
; Input:
;   C = current CRC
;   A = next byte
;
; Output:
;   C = updated CRC
;
; Clobbers:
;   AF, E
; ---------------------------------------------------------------------------

crc8_update:
	xor c
	ld c,a
	ld e,#0x08

crc8_update_bit:
	bit 7,c
	jr z,crc8_update_shift

	sla c
	ld a,c
	xor #0x07
	ld c,a
	jr crc8_update_next

crc8_update_shift:
	sla c

crc8_update_next:
	dec e
	jr nz,crc8_update_bit
	ret


; ---------------------------------------------------------------------------
; Data.
; ---------------------------------------------------------------------------

hello_msg:
	.ascii "HELLO WORLD"
	.db 0x00

packet_len_store:
	.db 0x00

packet_wire_len_store:
	.db 0x00

packet_type_store:
	.db 0x00

packet_crc_store:
	.db 0x00

packet_payload0:
	.ds 0x05

packet_ptr_store:
	.dw 0x0000

block_ptr_store:
	.dw 0x0000

block_count_store:
	.dw 0x0000
vdrip_rx_head:
	.db 0x00

vdrip_rx_tail:
	.db 0x00

vdrip_rx_count:
	.db 0x00

vdrip_rx_buffer:
	.ds VDRIP_RX_BUFFER_SIZE

vdrip_rx_rts_released:
	.db 0x00

vdrip_parse_state:
	.db VDRIP_RX_WAIT_SYNC0

vdrip_parse_len_store:
	.db 0x00

vdrip_parse_remaining:
	.db 0x00

vdrip_parse_payload_index:
	.db 0x00

vdrip_packet_body:
	.ds VDRIP_PACKET_BODY_MAX

text_col:
	.db 0x00

text_row:
	.db 0x00

textq_head:
	.db 0x00

textq_tail:
	.db 0x00

textq_count:
	.db 0x00

textq_buffer:
	.ds TEXTQ_SIZE

term_state:
	.db TERM_STATE_NORMAL

terminal_payload_ptr:
	.dw 0x0000

terminal_payload_count:
	.db 0x00

rx_drop_count:
	.db 0x00

textq_drop_count:
	.db 0x00

crc_fail_count:
	.db 0x00

packet_ok_count:
	.db 0x00

key_echo_count:
	.db 0x00

rts_release_count:
	.db 0x00

rts_assert_count:
	.db 0x00    
; ---------------------------------------------------------------------------
; Font include.
;
; Expected label:
;   msx_font_20_7f:
;     96 chars * 8 bytes, for ASCII 20h-7Fh
; ---------------------------------------------------------------------------

	.include "msxfont.inc"
