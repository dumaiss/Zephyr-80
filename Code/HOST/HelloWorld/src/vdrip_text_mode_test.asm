; ===========================================================================
; Zephyr-80 Virtual Drip text console driver (monitor-loaded test version)
; ===========================================================================
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; This file has two sections:
;
;   A. Monitor-loaded test harness (top — small, disposable)
;   B. Virtual Drip console driver code (lower — BIOS-shaped)
;
; Load with monitor:
;   L
;   G 8000
;
; Driver entry points (public BIOS-shaped):
;   vdrip_console_init    — Init VDP, font, cursor, SIO transport
;   vdrip_console_poll    — Kick SIO RX, drain ring, parse packets, enqueue input
;   vdrip_console_const   — Return A=0xff if input available, A=0x00 if not
;   vdrip_console_conin   — Return next queued input byte in A (blocks if empty)
;   vdrip_console_conout  — Output byte in A to the text console
;
; Calling convention for vdrip_console_conout: byte in A.
; Hardcoded BIOS helper addresses preserved until BIOS build integration.

	.module vdrip_text_console
	.area CODE (ABS)
	.org 0x8000

; ===========================================================================
; Constants
; ===========================================================================

; SIO0/B, matching monitor / Virtual Drip wiring.
VDRIP_DATA		    = 0x22
VDRIP_CTRL		    = 0x23
SIO_RR0_TX_EMPTY	= 0x04

; Virtual Drip packet protocol.
; Wire format:  A5 5A LEN TYPE PAYLOAD... CRC
; LEN = LEN + TYPE + PAYLOAD + CRC  (zero-payload LEN = 3)
PACKET_SYNC0		    = 0xa5
PACKET_SYNC1		    = 0x5a
PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_TERMINAL_INPUT	= 0x05
PACKET_RESET		    = 0x06
PACKET_PING		        = 0x07
PACKET_FRAME_MARK	    = 0x08
PACKET_CURSOR_COMMAND	= 0x09
PACKET_PROXY_READY	= 0x0a

CURSOR_ENABLE		= 0x01
CURSOR_SHOW			= 0x02
CURSOR_SET_POSITION	= 0x04
CURSOR_SET_STYLE	= 0x06
CURSOR_SET_BLINK	= 0x07
CURSOR_SET_COLOR	= 0x08
CURSOR_STYLE_UNDERLINE	= 0x01
VDRIP_WIRE_OVERHEAD	= 0x03

STARTUP_DELAY_UNITS = 0x30

; Inter-byte pacing for scroll redraw (~1 ms at 4 MHz).
VDRIP_TX_PACE_DELAY = 0x0020

; TMS9928A layout.
PATTERN_TABLE	    = 0x0000
NAME_TABLE	    = 0x3800
TEXT_PHYS_COLUMNS   = 40
TEXT_LOG_COLUMNS    = 80
TEXT_ROWS	    = 24
TEXT_PHYS_CELLS     = TEXT_PHYS_COLUMNS * TEXT_ROWS	; 960
TEXT_VIEW_COLUMNS   = TEXT_PHYS_COLUMNS
TEXT_VIEW_MAX_COL   = TEXT_LOG_COLUMNS - TEXT_PHYS_COLUMNS	; 40

; Text scrolling / shadow constants.
TEXT_SCROLL_TOP		= 0
TEXT_SCROLL_BOTTOM	= TEXT_ROWS - 1
TEXT_SCROLL_ROWS	= TEXT_ROWS
TEXT_SHADOW_SIZE	= TEXT_LOG_COLUMNS * TEXT_ROWS	; 1920

; Horizontal pan hysteresis.
TEXT_PAN_RIGHT_TARGET   = 30
TEXT_PAN_LEFT_MARGIN    = 8

; Font assumptions: 96 chars, ASCII 20h-7Fh, 8 bytes each.
FONT_FIRST_CHAR	= 0x20
FONT_CHAR_COUNT	= 0x60
FONT_BYTES		= FONT_CHAR_COUNT * 8

; BIOS SIO helper entry points (hardcoded — preserved until BIOS build).
BIOS_SIO_CORE_ENABLE_INTERRUPTS = 0xdd91
BIOS_SIO_REGISTER_RX_SINK       = 0xdde4
BIOS_SIO_RX_KICK                = 0xde6d
SIO_CH_CONSOLE                  = 0x00

; Packet parser states.
VDRIP_RX_WAIT_SYNC0 = 0x00
VDRIP_RX_WAIT_SYNC1 = 0x01
VDRIP_RX_LEN        = 0x02
VDRIP_RX_BODY       = 0x03

; Terminal parser states.
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

; Console input queue.
TEXTQ_SIZE		    = 0x80
TEXTQ_MASK		    = TEXTQ_SIZE - 1
TEXTQ_RTS_HIGH_WATER    = 0x08
TEXTQ_RTS_LOW_WATER     = 0x00

; ===========================================================================
; Monitor-loaded test harness
; ===========================================================================
;
; Small disposable client that exercises the driver entry points.
; Waits a few seconds before emitting VDP traffic (proxy startup window),
; then initialises the console and echoes typed characters.
;
; This is the only section that should change when moving to the BIOS build.

start:
	call vdrip_console_init

test_client_loop:
	call vdrip_console_poll
	call vdrip_console_const
	or a
	jr z,test_client_loop

	call vdrip_console_conin
	call vdrip_console_conout
	jr test_client_loop

; ===========================================================================
; Public Virtual Drip console driver entry points
; ===========================================================================

; ---------------------------------------------------------------------------
; vdrip_console_init
;
; Initialize Virtual Drip transport, SIO RX, VDP text mode, font, cursor.
;
; Startup sequence:
;   1. Release RTS, init RX, register sink, enable interrupts.
;   2. Assert RTS and wait for PACKET_PROXY_READY from the proxy.
;   3. Once ready, release RTS and send RESET/PING/VDP init/font/cursor.
;   4. Assert RTS and enter normal interactive mode.
; ---------------------------------------------------------------------------

vdrip_console_init:
	; Release RTS — we are not ready yet.
	call vdrip_rts_release_raw

	; Initialize RX state and register the sink so we can receive
	; the proxy READY packet.
	call vdrip_rx_init
	call vdrip_register_rx_sink
	call #BIOS_SIO_CORE_ENABLE_INTERRUPTS

	; Assert RTS so the proxy knows it can send.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	; Wait for the proxy to signal readiness.
	call vdrip_wait_for_proxy_ready

	; Proxy is ready — release RTS and begin VDP initialization.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	call vdrip_send_reset
	call vdrip_send_ping
	call text_init_vdp
	call text_load_font
	call text_clear_screen

	; Cursor starts at row 0, col 0 (full-screen scrolling).
	xor a
	ld (text_col),a
	ld (text_row),a
	ld (text_view_col),a

	call vdrip_cursor_init
	call vdrip_send_frame_mark

	; Ready for interactive mode — assert RTS.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret

; ---------------------------------------------------------------------------
; vdrip_console_poll
;
; Kick pending SIO RX, drain the RX ring, parse complete Virtual Drip packets,
; and enqueue terminal input bytes into the console input queue.
;
; Does not render diagnostics or block indefinitely.
; ---------------------------------------------------------------------------

vdrip_console_poll:
	call vdrip_rx_kick_pending
	call vdrip_poll_rx
	ret

; ---------------------------------------------------------------------------
; vdrip_console_const
;
; Return A = 0xff if at least one input byte is available in the console
; input queue.
; Return A = 0x00 if no input byte is available.
; ---------------------------------------------------------------------------

vdrip_console_const:
	ld a,(textq_count)
	or a
	jr z,vdrip_console_const_empty
	ld a,#0xff
	ret

vdrip_console_const_empty:
	xor a
	ret

; ---------------------------------------------------------------------------
; vdrip_console_conin
;
; Return the next queued input byte in A.
; In the monitor-loaded test, blocks by polling until input exists.
; Keeps BIOS-compatible in spirit (caller may check CONST first).
; ---------------------------------------------------------------------------

vdrip_console_conin:
	call vdrip_console_poll
	ld a,(textq_count)
	or a
	jr z,vdrip_console_conin

	; Dequeue one byte from the console input queue.
	di
	ld hl,#textq_buffer
	ld a,(textq_tail)
	ld e,a
	ld d,#0x00
	add hl,de
	ld a,(hl)
	push af

	ld a,(textq_tail)
	inc a
	and #TEXTQ_MASK
	ld (textq_tail),a

	ld a,(textq_count)
	dec a
	ld (textq_count),a

	call app_maybe_resume_rts
	ei
	pop af
	ret

; ---------------------------------------------------------------------------
; vdrip_console_conout
;
; Output one byte to the Virtual Drip text console.
;
; Input:
;   A = byte to output
;
; Handles printable characters, CR/newline, backspace, tab, and minimal
; ANSI/CSI cursor movement. Updates virtual cursor position when the logical
; cursor moves.
;
; Does not read keyboard packets or call CONIN from CONOUT.
; ---------------------------------------------------------------------------

vdrip_console_conout:
	push af

	; Pause host input while rendering.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	pop af
	call term_process_byte
	call vdrip_send_frame_mark
	call app_maybe_resume_rts
	ret


; ===========================================================================
; Startup delay (deprecated — kept as fallback only)
; ===========================================================================
;
; DEPRECATED: The normal startup path now uses vdrip_wait_for_proxy_ready
; instead of a fixed delay. This routine is retained as a fallback for
; bring-up when no proxy is connected.

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


; ---------------------------------------------------------------------------
; vdrip_tx_pace — small inter-byte delay for scroll VDP redraw pacing.
;
; Prevents the VDP data write burst from reaching the proxy too fast
; before the FRAME_MARK.  Adjust VDRIP_TX_PACE_DELAY if needed.
; ---------------------------------------------------------------------------

vdrip_tx_pace:
	push bc
	ld bc,#VDRIP_TX_PACE_DELAY

vdrip_tx_pace_loop:
	dec bc
	ld a,b
	or c
	jr nz,vdrip_tx_pace_loop
	pop bc
	ret


; ===========================================================================
; Proxy readiness handshake
; ===========================================================================
;
; Poll RX and wait for PACKET_PROXY_READY (0x0a) from the host before
; allowing any Virtual Drip output traffic.
;
; Must be called after RX is initialized, sink registered, interrupts
; enabled, and RTS asserted so the proxy can send the ready packet.

vdrip_wait_for_proxy_ready:
	; Clear flag before waiting.
	xor a
	ld (vdrip_proxy_ready_flag),a

vdrip_wait_for_proxy_ready_loop:
	call vdrip_rx_kick_pending
	call vdrip_poll_rx
	ld a,(vdrip_proxy_ready_flag)
	or a
	jr z,vdrip_wait_for_proxy_ready_loop
	ret


; ===========================================================================
; SIO RX ring and BIOS helper integration
; ===========================================================================

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
	ld (vdrip_proxy_ready_flag),a
	ld (proxy_ready_count),a
	ld (esc_press_count),a
	ld (text_view_col),a
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


; ===========================================================================
; Virtual Drip packet transport — RX parser
; ===========================================================================

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

	; Check for proxy-ready packet first.
	ld a,(vdrip_packet_body + 1)
	cp #PACKET_PROXY_READY
	jr z,vdrip_handle_proxy_ready

	; Otherwise dispatch as terminal input.
	call vdrip_parse_apply_terminal_input
	jr vdrip_parse_reset


vdrip_handle_proxy_ready:
	; Set the ready flag and count. Do NOT enqueue into input queue.
	ld a,#0x01
	ld (vdrip_proxy_ready_flag),a
	ld a,(proxy_ready_count)
	inc a
	ld (proxy_ready_count),a
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


; ===========================================================================
; Terminal input packet handling
; ===========================================================================
;
; PACKET_TERMINAL_INPUT / keyboard input packets
;   -> Enqueue payload bytes into the console input queue only.
;   Does NOT directly move the screen cursor or draw characters.
;   That is the job of CONOUT after the test harness reads the byte.

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


; ===========================================================================
; CONOUT terminal renderer
; ===========================================================================
;
; term_process_byte interprets a single byte and renders it to the VDP
; text display. This is the core of vdrip_console_conout's output handling.

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

	; Non-Esc byte resets the triple-Esc counter.
	push af
	xor a
	ld (esc_press_count),a
	pop af

	cp #0x08
	jp z,term_backspace

	cp #0x09
	jp z,term_tab

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
	; Increment the triple-Esc counter.
	ld a,(esc_press_count)
	inc a
	ld (esc_press_count),a
	cp #3
	jp z,vdrip_reset_display

	ld a,#TERM_STATE_ESC
	ld (term_state),a
	ret

term_process_esc:
	xor a
	ld (term_state),a

	; If this is another Esc (while in ESC state), count it.
	ld a,c
	cp #0x1b
	jr z,term_enter_esc

	; Non-ESC byte while in ESC state — reset the triple-Esc counter.
	push af
	xor a
	ld (esc_press_count),a
	pop af

	cp #'[
	ret nz

	ld a,#TERM_STATE_CSI
	ld (term_state),a
	ret

term_process_csi:
	xor a
	ld (term_state),a

	; Any CSI-terminating byte resets the triple-Esc counter.
	push af
	xor a
	ld (esc_press_count),a
	pop af

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
	; Input: A = printable ASCII
	call text_put_char_at_cursor
	call text_advance_cursor
	call text_ensure_cursor_visible
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

	call text_ensure_cursor_visible
	ld a,#0x20
	call text_put_char_at_cursor
	call vdrip_cursor_set_position_current
	ret

term_tab:
	; Advance to next 4-column tab stop in logical columns.
	call text_advance_cursor
	ld a,(text_col)
	and #0x03
	jr nz,term_tab

	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_cursor_up:
	ld a,(text_row)
	or a
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
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_cursor_right:
	ld a,(text_col)
	cp #(TEXT_LOG_COLUMNS - 1)
	ret nc

	inc a
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_cursor_home:
	; Home to row 0, col 0.  Let ensure_cursor_visible handle the
	; viewport reset and redraw.
	xor a
	ld (text_col),a
	ld (text_row),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_cursor_end:
	; End of logical line.
	ld a,#(TEXT_LOG_COLUMNS - 1)
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret


; ===========================================================================
; Console input queue
; ===========================================================================

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
; text_newline — move cursor to column 0 of the next row
;
; Full-screen scrolling: rows 0..23, scrolls up when at bottom.
; ---------------------------------------------------------------------------

text_advance_cursor:
	ld a,(text_col)
	inc a
	cp #TEXT_LOG_COLUMNS
	jr c,text_advance_store_col

	xor a
	ld (text_col),a
	; Reset viewport to column 0 on wrap.  Redraw only if it changed.
	ld a,(text_view_col)
	or a
	jr z,text_advance_wrap_no_redraw

	xor a
	ld (text_view_col),a
	push af
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	call text_redraw_view
	call app_maybe_resume_rts
	pop af

text_advance_wrap_no_redraw:
	jr text_newline_from_wrap


text_newline:
	; If viewport was panned, reset it and redraw.
	ld a,(text_view_col)
	or a
	jr z,text_newline_no_redraw

	xor a
	ld (text_view_col),a
	push af
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	call text_redraw_view
	call app_maybe_resume_rts
	pop af

text_newline_no_redraw:
	xor a
	ld (text_col),a

text_newline_from_wrap:
	ld a,(text_row)
	inc a
	cp #TEXT_ROWS
	jr c,text_newline_store_row

	; Bottom of screen — scroll up.
	call text_scroll_up
	ret

text_newline_store_row:
	ld (text_row),a
	ret

text_advance_store_col:
	ld (text_col),a
	ret

text_cursor_to_vram:
	ld hl,#NAME_TABLE

	ld a,(text_row)
	or a
	jr z,text_cursor_rows_done

	ld b,a
	ld de,#TEXT_PHYS_COLUMNS

text_cursor_row_loop:
	add hl,de
	djnz text_cursor_row_loop

text_cursor_rows_done:
	; Compute physical column: logical_col - view_col.
	ld a,(text_col)
	ld e,a
	ld a,(text_view_col)
	sub e
	neg
	ld e,a
	ld d,#0x00
	add hl,de

	call vdp_set_vram_write_addr
	ret


; ===========================================================================
; RTS flow control
; ===========================================================================

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


; ===========================================================================
; Shadow buffer and scroll routines
; ===========================================================================

; ---------------------------------------------------------------------------
; text_shadow_addr_current
;
; Input:  text_row, text_col
; Output: HL = address inside text_shadow for current cursor cell
; ---------------------------------------------------------------------------

text_shadow_addr_current:
	push de
	ld hl,#text_shadow
	ld a,(text_row)
	or a
	jr z,text_shadow_row_done
	ld b,a
	ld de,#TEXT_LOG_COLUMNS

text_shadow_row_loop:
	add hl,de
	djnz text_shadow_row_loop

text_shadow_row_done:
	ld a,(text_col)
	ld e,a
	ld d,#0
	add hl,de
	pop de
	ret


; ---------------------------------------------------------------------------
; text_shadow_put_current
;
; Store A into text_shadow at current row/col.
; Preserves the character while calculating the shadow address.
; ---------------------------------------------------------------------------

text_shadow_put_current:
	push af
	call text_shadow_addr_current
	pop af
	ld (hl),a
	ret


; ---------------------------------------------------------------------------
; text_put_char_at_cursor
;
; Write character A at current cursor position in both shadow buffer and,
; if the cursor falls within the visible viewport, the VDP name table.
; ---------------------------------------------------------------------------

text_put_char_at_cursor:
	push af
	call text_shadow_put_current
	; Compute physical column = text_col - text_view_col.
	; If 0 <= physical_col < TEXT_PHYS_COLUMNS, write to VDP.
	ld a,(text_col)
	ld e,a
	ld a,(text_view_col)
	sub e
	neg			; A = physical column
	cp #TEXT_PHYS_COLUMNS
	jr nc,text_put_char_at_cursor_done

	; Visible — write to VDP.
	call text_cursor_to_vram
	pop af
	call vdp_write_data_byte
	ret

text_put_char_at_cursor_done:
	pop af
	ret


; ---------------------------------------------------------------------------
; text_ensure_cursor_visible
;
; Pan the viewport so the logical cursor column becomes visible.
; If text_col < text_view_col, shift left.
; If text_col >= text_view_col + TEXT_PHYS_COLUMNS, shift right.
; Redraws the viewport only when the view changes.
; ---------------------------------------------------------------------------

text_ensure_cursor_visible:
	ld a,(text_col)
	ld e,a
	ld a,(text_view_col)
	cp e
	jr c,text_ensure_check_right	; view_col < text_col

	; text_col <= text_view_col — check left margin.
	; If text_col >= TEXT_PAN_LEFT_MARGIN, pan so cursor is at margin.
	; Otherwise pan to column 0.
	ld a,e
	cp #TEXT_PAN_LEFT_MARGIN
	jr c,text_ensure_pan_left_zero

	; Pan to cursor - margin.
	sub #TEXT_PAN_LEFT_MARGIN
	jr text_ensure_store_and_redraw

text_ensure_pan_left_zero:
	xor a
	jr text_ensure_store_and_redraw

text_ensure_check_right:
	; Compute view_col + TEXT_PHYS_COLUMNS to check right edge.
	ld a,(text_view_col)
	add a,#TEXT_PHYS_COLUMNS
	cp e
	ret nc			; text_col < view_col + 40, already visible

	; Pan so cursor is at TEXT_PAN_RIGHT_TARGET.
	ld a,e
	sub #TEXT_PAN_RIGHT_TARGET
	jr nc,text_ensure_clamp
	xor a

text_ensure_clamp:
	cp #TEXT_VIEW_MAX_COL
	jr c,text_ensure_store_and_redraw
	ld a,#TEXT_VIEW_MAX_COL

text_ensure_store_and_redraw:
	ld e,a			; save new view_col
	ld a,(text_view_col)
	cp e			; compare with current
	ret z			; skip if view didn't change

	ld a,e
	ld (text_view_col),a
	; fall through to redraw

text_ensure_redraw:
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	call text_redraw_view
	jp app_maybe_resume_rts


; ---------------------------------------------------------------------------
; text_redraw_view
;
; Redraw all visible rows (rows 0..23) from the 80-column shadow buffer
; into the 40-column VDP viewport, using the current text_view_col.
;
; RTS must be released before calling this (caller's responsibility).
; Sends one FRAME_MARK after the redraw completes.
; ---------------------------------------------------------------------------

text_redraw_view:
	; Write each visible row from shadow to VDP.
	ld a,#0
	push af		; row counter on stack

text_redraw_view_row_loop:
	pop af
	push af

	; Compute VDP write address = NAME_TABLE + row * 40
	ld hl,#NAME_TABLE
	ld b,a
	or a
	jr z,text_redraw_view_vdp_row_done
	ld de,#TEXT_PHYS_COLUMNS
text_redraw_view_vdp_row_loop:
	add hl,de
	djnz text_redraw_view_vdp_row_loop
text_redraw_view_vdp_row_done:
	call vdp_set_vram_write_addr

	; Compute shadow source = text_shadow + row * 80 + view_col
	pop af
	push af
	ld hl,#text_shadow
	ld b,a
	or a
	jr z,text_redraw_view_shadow_row_done
	ld de,#TEXT_LOG_COLUMNS
text_redraw_view_shadow_row_loop:
	add hl,de
	djnz text_redraw_view_shadow_row_loop
text_redraw_view_shadow_row_done:
	ld a,(text_view_col)
	ld e,a
	ld d,#0
	add hl,de

	; Write 40 bytes from shadow to VDP with pacing.
	ld b,#TEXT_PHYS_COLUMNS
text_redraw_view_byte_loop:
	ld a,(hl)
	call vdp_write_data_byte
	call vdrip_tx_pace
	inc hl
	djnz text_redraw_view_byte_loop

	; Next row.
	pop af
	inc a
	push af
	cp #TEXT_ROWS
	jr nz,text_redraw_view_row_loop

	pop af			; discard saved row counter
	call vdrip_send_frame_mark
	ret


; ---------------------------------------------------------------------------
; text_scroll_up
;
; Scroll the entire visible area up by one row in the shadow buffer.
; Blank the bottom row. Redraw all rows to VDP. Cursor to bottom, col 0.
;
; RTS is released during the redraw burst; reasserted after FRAME_MARK.
; ---------------------------------------------------------------------------

text_scroll_up:
	; Release RTS — we will be chatty.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	; Shift rows TEXT_SCROLL_TOP+1..TEXT_SCROLL_BOTTOM up by one in the
	; shadow buffer.  Each row is TEXT_LOG_COLUMNS bytes wide.
	push bc
	push de
	push hl

	ld hl,#(text_shadow + TEXT_LOG_COLUMNS)
	ld de,#text_shadow
	ld bc,#(TEXT_SHADOW_SIZE - TEXT_LOG_COLUMNS)

text_scroll_copy_loop:
	ld a,(hl)
	ld (de),a
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,text_scroll_copy_loop

	; Blank the full 80-column bottom row in the shadow buffer.
	ld hl,#(text_shadow + (TEXT_ROWS - 1) * TEXT_LOG_COLUMNS)
	ld bc,#TEXT_LOG_COLUMNS

text_scroll_blank_loop:
	ld (hl),#0x20
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,text_scroll_blank_loop

	pop hl
	pop de
	pop bc

	; Redraw the 40-column viewport from the 80-column shadow.
	; text_view_col is reset to 0 after scroll.
	call text_redraw_view

	; Cursor to bottom row, col 0.
	xor a
	ld (text_col),a
	ld (text_view_col),a
	ld a,#(TEXT_SCROLL_BOTTOM)
	ld (text_row),a

	; Reassert RTS if both queues are drained.
	call app_maybe_resume_rts
	ret


; ===========================================================================
; VDP reset (triple-Esc)
; ===========================================================================
;
; Called when the user presses Esc three times rapidly.
; Re-initialises the VDP text mode, font, and virtual cursor.

vdrip_reset_display:
	; Reset the Esc counter.
	xor a
	ld (esc_press_count),a

	; Release RTS while we re-init the display.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	call vdrip_send_reset
	call vdrip_send_ping
	call text_init_vdp
	call text_load_font
	call text_clear_screen

	; Cursor to row 0, col 0.
	xor a
	ld (text_col),a
	ld (text_row),a
	ld (text_view_col),a

	call vdrip_cursor_init
	call vdrip_send_frame_mark

	; Reassert RTS.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


; ===========================================================================
; VDP text backend
; ===========================================================================

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
; Clear 40x24 text screen to ASCII space — clears both VDP and shadow buffer.
; ---------------------------------------------------------------------------

text_clear_screen:
	; Clear VDP name table (40x24).
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr

	ld bc,#TEXT_PHYS_CELLS
text_clear_vdp_loop:
	ld a,#0x20
	call vdp_write_data_byte
	dec bc
	ld a,b
	or c
	jr nz,text_clear_vdp_loop

	; Clear 80-column shadow buffer.
	ld hl,#text_shadow
	ld bc,#TEXT_SHADOW_SIZE
text_clear_shadow_loop:
	ld (hl),#0x20
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,text_clear_shadow_loop

	ret


; ---------------------------------------------------------------------------
; ===========================================================================
; VDP helpers over Virtual Drip
; ===========================================================================

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


; ===========================================================================
; Virtual Drip packet output — transport
; ===========================================================================

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


; ===========================================================================
; Virtual cursor command helpers
; ===========================================================================

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
	; Send physical cursor column (logical_col - view_col).
	ld hl,#packet_payload0
	ld (hl),#CURSOR_SET_POSITION
	inc hl
	ld a,(text_col)
	ld e,a
	ld a,(text_view_col)
	sub e
	neg
	ld (hl),a		; physical column
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


; ===========================================================================
; CRC-8 (polynomial 0x07) — matches proxy
;
; Input:  C = current CRC, A = next byte
; Output: C = updated CRC
; Clobbers: AF, E
; ===========================================================================

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


; ===========================================================================
; Data / buffers / font include
; ===========================================================================

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

; Horizontal viewport offset into the 80-column logical buffer.
text_view_col:
	.db 0x00

textq_head:
	.db 0x00

textq_tail:
	.db 0x00

textq_count:
	.db 0x00

textq_buffer:
	.ds TEXTQ_SIZE

; Text shadow buffer — source of truth for visible text.
; Updated on every character write; redrawn to VDP on scroll.
text_shadow:
	.ds TEXT_SHADOW_SIZE

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

; Proxy readiness handshake.
vdrip_proxy_ready_flag:
	.db 0x00
proxy_ready_count:
	.db 0x00

; Triple-Esc VDP reset counter.
esc_press_count:
	.db 0x00

    
; ---------------------------------------------------------------------------
; Font include.
;
; Expected label:
;   msx_font_20_7f:
;     96 chars * 8 bytes, for ASCII 20h-7Fh
; ---------------------------------------------------------------------------

	.include "msxfont.inc"
