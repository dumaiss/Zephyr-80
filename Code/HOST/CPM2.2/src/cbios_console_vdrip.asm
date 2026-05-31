; Zephyr-80 Virtual Drip text console BIOS driver.
;
; This module replaces the legacy SIO console driver as the active CP/M
; console backend. It owns the Virtual Drip packet transport, VDP text
; rendering, proxy cursor control, and terminal input queue.
;
; Major subsystems:
;   - CP/M console dispatch table consumed by cbios_console.asm.
;   - Startup VT100-style terminal readiness recognizer before normal VDP output
;     traffic.
;   - SIO0/B RX sink registration with the BIOS SIO core.
;   - Input path: proxy-to-Z80 bytes are raw terminal input bytes after
;     readiness and are enqueued into textq, the CP/M CONIN FIFO.
;   - Output path: CP/M CONOUT bytes are interpreted by an ANSI/VT100-light
;     parser and rendered to the text shadow buffer / VDP name table.
;   - Obsolete framed RX parser retained inactive during the raw-input change.
;   - Virtual cursor command helpers for the proxy renderer.
;   - RTS flow control for host-to-Z80 keyboard traffic and large VDP bursts.
;
; Input path, intended final design:
;     SIO RX interrupt
;     -> sio_core_isr
;     -> sio_core_dispatch_rx
;     -> vdrip_rx_sink
;     -> raw byte enqueue
;     -> textq FIFO
;     -> CONST checks textq_count
;     -> CONIN dequeues oldest byte
;
; Startup readiness input:
;     proxy sends raw ESC [ ? 1 ; 0 c
;     -> vdrip_rx_sink
;     -> vdrip_terminal_ready_parse_byte
;     -> vdrip_terminal_ready_flag = 1
;
; Proxy-to-Z80 input is raw bytes. Z80-to-proxy display/control output remains
; framed Virtual Drip packets. Storage or future structured commands should stay
; framed or use a separate channel later; this pass changes keyboard input only.
;
; Output path:
;     CP/M calls CONOUT
;     -> vdrip_console_conout
;     -> ANSI/VT100-light parser
;     -> text shadow / VDP name table updates
;     -> VDrip VDP packets to proxy
;     -> proxy renders display
;
; Input and output are deliberately separate. Keyboard packet payloads are raw
; terminal input bytes and must not be interpreted by the output parser. Output
; bytes may be interpreted as terminal control sequences. Keyboard packet
; handlers must not draw characters, move the screen cursor, or scroll the
; display. CONOUT must not read keyboard packets.
;
; Driver dispatch table consumed by cbios_console.asm:
;   const, conin, conout, list, punch, reader, listst
;
; Public entry points:
;   vdrip_console_init    — Init VDP, font, cursor, SIO transport
;   vdrip_console_const   — Return A=0xff if CONIN FIFO non-empty, A=0x00 if not
;   vdrip_console_conin   — Return next queued input byte in A (blocks if empty)
;   vdrip_console_conout  — Output byte in A to the text console
;
; Input architecture (interrupt-fed):
;   SIO RX ISR → vdrip_rx_sink → textq_put_ascii
;   CONST: check textq_count — no RX polling, kicking, or parsing
;   CONIN: block until textq_count > 0, dequeue oldest byte
;
; Startup sequence:
;   1. sio_core_init has already run; SIO0/B is configured but RTS is released.
;   2. Register RX sink, enable interrupts, assert RTS.
;   3. Wait for raw terminal readiness bytes: ESC [ ? 1 ; 0 c.
;   4. Once ready, release RTS and send RESET/PING/VDP init/font/cursor.
;   5. Assert RTS and enter normal interactive mode.
;
; Does not contain:
;   - monitor .org, start:, or echo loop
;   - hardcoded BIOS helper addresses
;   - demo banners or dashboard redraws

	.module vdrip_console

	.globl vdrip_console_driver
	.globl vdrip_console_init,vdrip_console_const
	.globl vdrip_console_conin,vdrip_console_conout
	.globl vdrip_rx_sink
	.globl vdrip_send_packet,vdrip_rts_assert_raw,crc8_update
	.globl vdrip_rx_rts_released
	.globl VDRIP_CONSOLE_CODE_START,VDRIP_CONSOLE_CODE_END

	; SIO core services — real BIOS symbols, not stale map addresses.
	.globl sio_core_enable_interrupts,sio_register_rx_sink,sio_rx_kick
	.globl sio_send_byte
	.globl sio0b_rts_assert,sio0b_rts_release
	.globl SIO_CH_CONSOLE

; ===========================================================================
; Constants
; ===========================================================================

; SIO0/B port aliases matching platform_zephyr80.inc / sio_core.asm.
VDRIP_DATA		= SIOB_DATA
VDRIP_CTRL		= SIOB_CTRL
SIO_RR0_TX_EMPTY	= 0x04
SIO_RR0_CTS		= 0x20

; Virtual Drip packet protocol.
; Wire format:  A5 5A LEN TYPE PAYLOAD... CRC
; LEN = LEN + TYPE + PAYLOAD + CRC  (zero-payload LEN = 3)
; Storage packets share this framing but are parsed by cbios_storage_vdrip.asm
; while the storage backend temporarily owns the SIO RX sink. The small inactive
; console RX parser below is not sized for storage replies.
PACKET_SYNC0		= 0xa5
PACKET_SYNC1		= 0x5a
PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_VDP_DATA_BLOCK	= 0x0b
PACKET_VDP_SCROLL	= 0x0c
; Obsolete for proxy->Z80 keyboard input. Raw terminal bytes now feed textq.
PACKET_TERMINAL_INPUT	= 0x05
PACKET_RESET		= 0x06
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08
PACKET_CURSOR_COMMAND	= 0x09
; Obsolete proxy->Z80 readiness packet. Readiness is now raw ESC [ ? 1 ; 0 c.
PACKET_PROXY_READY	= 0x0a
PACKET_STORAGE_READ_REQ	= 0x0d
PACKET_STORAGE_READ_REPLY = 0x0e
PACKET_STORAGE_WRITE_REQ = 0x0f
PACKET_STORAGE_WRITE_REPLY = 0x10

CURSOR_ENABLE		= 0x01
CURSOR_SHOW		= 0x02
CURSOR_HIDE		= 0x03
CURSOR_SET_POSITION	= 0x04
CURSOR_SET_STYLE	= 0x06
CURSOR_SET_BLINK	= 0x07
CURSOR_SET_COLOR	= 0x08
CURSOR_STYLE_UNDERLINE	= 0x01
VDRIP_WIRE_OVERHEAD	= 0x03

; Inter-byte pacing for scroll redraw (~1 ms at 4 MHz).
VDRIP_TX_PACE_DELAY	= 0x0001

; TMS9928A / Virtual Drip Text80 layout.
;
; The proxy exposes a 9928-like Text 2 display for an 80-column terminal. The
; logical console and physical name-table view are both 80 columns by 24 rows in
; this build, so horizontal panning constants collapse to zero-width movement.
; The font is ASCII 20h-7Fh: 96 glyphs, 8 bytes per glyph.
PATTERN_TABLE		= 0x0000
NAME_TABLE		= 0x3800
TEXT_PHYS_COLUMNS	= 80
TEXT_LOG_COLUMNS	= 80
TEXT_ROWS		= 24
TEXT_PHYS_CELLS		= TEXT_PHYS_COLUMNS * TEXT_ROWS	; 1920
TEXT_VIEW_COLUMNS	= TEXT_PHYS_COLUMNS
TEXT_VIEW_MAX_COL	= TEXT_LOG_COLUMNS - TEXT_PHYS_COLUMNS	; 0

; Text scrolling / shadow constants.
TEXT_SCROLL_TOP		= 0
TEXT_SCROLL_BOTTOM	= TEXT_ROWS - 1
TEXT_SCROLL_ROWS	= TEXT_ROWS
TEXT_SHADOW_SIZE	= TEXT_LOG_COLUMNS * TEXT_ROWS	; 1920

; Horizontal pan hysteresis.
TEXT_PAN_RIGHT_TARGET	= 0
TEXT_PAN_LEFT_MARGIN	= 0

; Font assumptions: 96 chars, ASCII 20h-7Fh, 8 bytes each.
FONT_FIRST_CHAR		= 0x20
FONT_CHAR_COUNT		= 0x60
FONT_BYTES		= FONT_CHAR_COUNT * 8

; Packet parser states.
VDRIP_RX_WAIT_SYNC0	= 0x00
VDRIP_RX_WAIT_SYNC1	= 0x01
VDRIP_RX_LEN		= 0x02
VDRIP_RX_BODY		= 0x03

; VT100-style terminal readiness recognizer.
; Expected raw bytes from proxy:
;   ESC [ ? 1 ; 0 c
; Optional accepted variant:
;   ESC [ ? 1 ; 2 c
VDRIP_READY_WAIT_ESC	= 0x00
VDRIP_READY_WAIT_LBRACKET = 0x01
VDRIP_READY_WAIT_QMARK	= 0x02
VDRIP_READY_WAIT_1	= 0x03
VDRIP_READY_WAIT_SEMI	= 0x04
VDRIP_READY_WAIT_MODE	= 0x05
VDRIP_READY_WAIT_C	= 0x06

; Terminal parser states (for ANSI/VT-100 output processing).
TERM_STATE_NORMAL	= 0x00
TERM_STATE_ESC		= 0x01
TERM_STATE_CSI		= 0x02
TERM_STATE_ESC_HASH	= 0x03
TERM_STATE_CHARSET	= 0x04

; ANSI CSI final command bytes.
CSI_CHA			= 'G	; cursor horizontal absolute
CSI_CUU			= 'A	; cursor up
CSI_CUD			= 'B	; cursor down
CSI_CUF			= 'C	; cursor forward / right
CSI_CUB			= 'D	; cursor back / left
CSI_CUP			= 'H	; cursor position
CSI_CUP_ALT		= 'f	; cursor position (alternate)
CSI_VPA			= 'd	; cursor vertical absolute
CSI_ED			= 'J	; erase in display
CSI_EL			= 'K	; erase in line
CSI_SGR			= 'm	; select graphic rendition
CSI_SAVE		= 's	; save cursor
CSI_RESTORE		= 'u	; restore cursor
CSI_DECSET		= 'h	; DEC private mode set
CSI_DECRST		= 'l	; DEC private mode reset

; ANSI maximum parameter count.
CSI_MAX_PARAMS		= 2

; Max payload for the obsolete RX parser buffer (kept small).
VDRIP_PACKET_PAYLOAD_MAX = 0x10
VDRIP_PACKET_BODY_MAX    = VDRIP_PACKET_PAYLOAD_MAX + VDRIP_WIRE_OVERHEAD

; Max payload per PACKET_VDP_DATA_BLOCK chunk for bulk VDP writes.
; 240 bytes ≈ 3 rows of 80-column text; proxy accepts up to 252.
VDRIP_DATA_BLOCK_MAX = 240

; Console input queue (CONIN FIFO, interrupt-fed).
TEXTQ_SIZE		= 0x80
TEXTQ_MASK		= TEXTQ_SIZE - 1
TEXTQ_RTS_HIGH_WATER	= 0x40
TEXTQ_RTS_LOW_WATER	= 0x00

; Stub return values for auxiliary CP/M devices.
CONSOLE_EOF		= 0x1a
CONSOLE_READY		= 0xff
; CP/M constants from cbios_defs.inc (also defined here for clarity).
CONST_NO_CHAR		= 0x00
CONST_HAS_CHAR		= 0xff


; ===========================================================================
; Driver dispatch table
; ===========================================================================
;
; Entry order must match the console facade contract:
;   const, conin, conout, list, punch, reader, listst.

	.area CODE (ABS)
	.org CBIOS_DRIVER_SLOT0_BASE

VDRIP_CONSOLE_CODE_START:

vdrip_console_driver:
	.dw vdrip_console_const
	.dw vdrip_console_conin
	.dw vdrip_console_conout
	.dw vdrip_console_list
	.dw vdrip_console_punch
	.dw vdrip_console_reader
	.dw vdrip_console_listst


; ===========================================================================
; Public Virtual Drip console driver entry points
; ===========================================================================

; ---------------------------------------------------------------------------
; vdrip_console_init
;
; Purpose:
;   Initialize the Virtual Drip console backend selected by cbios_console.asm.
;   Clears driver-owned parser/FIFO/display state, registers vdrip_rx_sink for
;   SIO_CH_CONSOLE, enables SIO RX interrupts, waits for raw VT100-style terminal
;   readiness bytes, initializes the remote VDP/Text80 state, and enters
;   interactive mode.
;
; Inputs:
;   None.
; Outputs:
;   Virtual Drip console state initialized; terminal readiness has been observed;
;   SIO0/B RTS asserted for normal input.
; Preserved registers:
;   None promised. Called during BOOT/WBOOT setup.
; Clobbers:
;   AF, BC, DE, HL.
; Blocking behavior:
;   Blocks during the terminal readiness handshake and during serial TX.
; VDrip traffic:
;   Emits RESET, PING, VDP register/font/clear packets, cursor commands, and a
;   FRAME_MARK after the proxy is ready.
; sio_rx_kick:
;   Not used here. The readiness bytes are received by the normal SIO RX
;   interrupt path and consumed by vdrip_terminal_ready_parse_byte.
;
; Startup sequence:
;   1. Release RTS, init RX, register sink, enable interrupts.
;   2. Assert RTS and wait for raw ESC [ ? 1 ; 0 c from the proxy.
;   3. Once ready, release RTS and send RESET/PING/VDP init/font/cursor.
;   4. Assert RTS and enter normal interactive mode.
;
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------

vdrip_console_init:
	; Release RTS — we are not ready yet.
	call vdrip_rts_release_raw

	; Initialize RX state and register the sink.
	call vdrip_rx_init
	call vdrip_register_rx_sink
	call sio_core_enable_interrupts

	; Assert RTS so the proxy can send.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	; Terminal readiness handshake — skip on warm boot.
	ld a,(vdrip_handshake_done)
	or a
	jr nz,vdrip_init_skip_handshake

	call vdrip_wait_for_terminal_ready
	ld a,#0x01
	ld (vdrip_handshake_done),a

vdrip_init_skip_handshake:
	; Warm boot — readiness was already confirmed; restore the flag
	; that vdrip_rx_init just zeroed so vdrip_rx_sink routes bytes
	; to textq instead of the readiness parser.
	ld a,#0x01
	ld (vdrip_terminal_ready_flag),a

	; Release RTS and begin VDP initialization.
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
	ld (current_attr),a
	ld (text_attr_saved),a
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
; vdrip_console_const
;
; Purpose:
;   CP/M CONST backend. Report whether textq, the CONIN FIFO, currently has at
;   least one byte available.
;
; Intended final design:
;   CONST should be cheap:
;     check textq_count only
;     return 0xff if non-empty
;     return 0x00 if empty
;
; Return A = 0xff if at least one input byte is available in the CONIN
; FIFO (textq), or A = 0x00 if empty.
;
; Input is interrupt-fed: the SIO RX sink parses keyboard packets and
; enqueues payload bytes directly into textq.  CONST simply checks the
; queue — no RX polling, no SIO kicking, no packet parsing.
;
; Inputs:
;   None.
; Outputs:
;   A = CONST_HAS_CHAR (0xff) if textq_count != 0, else 0x00.
; Preserved registers:
;   HL is preserved by this routine. The facade preserves DE/HL around backend
;   dispatch as well.
; Clobbers:
;   AF.
; Blocking behavior:
;   Does not block.
; VDrip traffic:
;   Emits no traffic.
; sio_rx_kick:
;   Does not call sio_rx_kick. Safe for hot BDOS/CCP/BBC BASIC CONST loops.
; ---------------------------------------------------------------------------

vdrip_console_const:
	push hl

	; Check for proxy reconnection: sequence count > 1.
	ld a,(vdrip_ready_seq_count)
	cp #0x02
	call nc,vdrip_handle_reconnect

	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr z,vdrip_console_const_empty
	ld a,#CONST_HAS_CHAR
	pop hl
	ret
vdrip_console_const_empty:
	xor a
	pop hl
	ret

; ---------------------------------------------------------------------------
; vdrip_console_conin
;
; Purpose:
;   CP/M CONIN backend. Return the oldest queued terminal byte from textq.
;
; Inputs:
;   None.
; Outputs:
;   A = oldest byte from textq.
; Preserved registers:
;   BC, DE, HL.
; Clobbers:
;   AF.
; Blocking behavior:
;   Blocks until textq_count is nonzero. It does not interpret bytes while
;   waiting; it waits for the SIO RX sink to enqueue raw input.
; VDrip traffic:
;   May assert RTS after dequeue if textq has drained to the low-water mark.
;   Does not emit VDP traffic.
; sio_rx_kick:
;   Does not call sio_rx_kick. Any future use here would be fallback behavior,
;   not the desired steady-state design.
;
; FIFO semantics:
;   Producer writes at textq_head. CONIN reads from textq_tail and consumes the
;   oldest byte. Input bytes are raw terminal bytes, for example Ctrl-X = 18h,
;   Enter = 0Dh, and arrow-up = 1Bh 5Bh 41h.
; ---------------------------------------------------------------------------

vdrip_console_conin:
	; Input is interrupt-fed — the SIO RX sink enqueues keyboard
	; bytes directly into textq.  CONIN blocks until textq is
	; non-empty, dequeues one byte, and returns.
	push bc
	push de
	push hl

	; Check for proxy reconnection before blocking.
	ld a,(vdrip_ready_seq_count)
	cp #0x02
	call nc,vdrip_handle_reconnect

vdrip_console_conin_wait:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr z,vdrip_console_conin_wait

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
	pop hl
	pop de
	pop bc
	ret

; ---------------------------------------------------------------------------
; vdrip_console_conout
;
; Purpose:
;   CP/M CONOUT backend. Render one output byte through the output-only terminal
;   parser and Virtual Drip VDP packet path.
;
; Output one byte to the Virtual Drip text console.
;
; Input:
;   C = byte to output (CP/M console facade convention)
; Outputs:
;   Display state may be updated.
; Preserved registers:
;   BC, DE, HL.
; Clobbers:
;   AF.
; Blocking behavior:
;   May block waiting for serial TX readiness and CTS while emitting VDrip
;   packets.
; VDrip traffic:
;   May emit VDP data/control packets, cursor packets, and FRAME_MARK packets for
;   burst operations.
; sio_rx_kick:
;   Does not call sio_rx_kick and must not read keyboard packets.
;
; Renders the byte on the VDP text display with ANSI/VT-100 light
; terminal emulation for cursor movement, backspace, tab, etc.
; CP/M handles line editing; the driver interprets control sequences
; for display.
;
; Does not read keyboard packets or call CONIN from CONOUT.
; ---------------------------------------------------------------------------

vdrip_console_conout:
	push bc
	push de
	push hl

	; Do not release RTS for single-character output — the burst
	; output helpers (scroll, clear, redraw) manage RTS themselves.
	; Keeping RTS asserted during single-byte CONOUT prevents the
	; proxy from flooding keyboard data that must then be serviced
	; by CONST/CONIN before the next character can be output.
	;
	; Do not send FRAME_MARK per character — the proxy's VDP
	; backend already marks the framebuffer dirty on every
	; VDP_DATA_WRITE.  FRAME_MARK is still sent by burst
	; operations (scroll, clear, redraw).

	ld a,c
	call term_process_byte
	pop hl
	pop de
	pop bc
	ret

; ---------------------------------------------------------------------------
; Auxiliary CP/M device stubs.
;
; vdrip_console_list:
;   CP/M LIST backend. Input C is ignored. Returns immediately, emits no VDrip
;   traffic, does not call sio_rx_kick.
;
; vdrip_console_punch:
;   CP/M PUNCH backend. Input C is ignored. Returns immediately, emits no VDrip
;   traffic, does not call sio_rx_kick.
;
; vdrip_console_reader:
;   CP/M READER backend. Returns CONSOLE_EOF in A. Does not block, emits no
;   VDrip traffic, does not call sio_rx_kick.
;
; vdrip_console_listst:
;   CP/M LISTST backend. Returns CONSOLE_READY in A. Does not block, emits no
;   VDrip traffic, does not call sio_rx_kick.
; ---------------------------------------------------------------------------

vdrip_console_list:
	ret

vdrip_console_punch:
	ret

vdrip_console_reader:
	ld a,#CONSOLE_EOF
	ret

vdrip_console_listst:
	ld a,#CONSOLE_READY
	ret


; ===========================================================================
; Inter-byte pacing for scroll redraw
; ===========================================================================
;
; Prevents the VDP data write burst from reaching the proxy too fast
; before the FRAME_MARK.  Adjust VDRIP_TX_PACE_DELAY if needed.

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
; Terminal readiness handshake
; ===========================================================================
;
; Wait for the proxy to send a raw VT100-style Device Attributes response before
; allowing any Virtual Drip output traffic:
;
;   ESC [ ? 1 ; 0 c
;
; The readiness bytes are raw input bytes handled by vdrip_rx_sink and consumed
; by vdrip_terminal_ready_parse_byte. They are not enqueued into textq.
;
; Must be called after RX is initialized, sink registered, interrupts
; enabled, and RTS asserted so the proxy can send the readiness bytes.

vdrip_wait_for_terminal_ready:
vdrip_wait_for_terminal_ready_loop:
	; Kick SIO to move available bytes through the ISR path.
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick

	ld a,(vdrip_terminal_ready_flag)
	or a
	jr z,vdrip_wait_for_terminal_ready_loop
	ret


; ===========================================================================
; SIO RX integration
; ===========================================================================

vdrip_rx_init:
		xor a
	ld (vdrip_parse_state),a
	ld (vdrip_parse_len_store),a
	ld (vdrip_parse_remaining),a
	ld (vdrip_parse_payload_index),a
	ld (vdrip_rx_rts_released),a
	ld (textq_head),a
	ld (textq_tail),a
	ld (textq_count),a
	ld (textq_drop_count),a
	ld (crc_fail_count),a
	ld (packet_ok_count),a
	ld (key_echo_count),a
	ld (rts_release_count),a
	ld (rts_assert_count),a
		ld (vdrip_terminal_ready_flag),a
		ld (vdrip_terminal_ready_state),a
	ld (vdrip_ready_seq_count),a
	ld (esc_press_count),a
	ld (text_view_col),a
	ld (term_state),a

	; Zero the text input queue buffer so phantom bytes
	; cannot appear if textq_count is ever corrupted.
	ld hl,#textq_buffer
	ld bc,#TEXTQ_SIZE
vdrip_rx_init_ztextq:
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	ld a,#0x00
	jr nz,vdrip_rx_init_ztextq
	ret


vdrip_register_rx_sink:
	di
	ld a,#SIO_CH_CONSOLE
	ld hl,#vdrip_rx_sink
	call sio_register_rx_sink
	ei
	ret


; SIO RX sink registered with sio_core for SIO_CH_CONSOLE.
;
; Called from:
;   - sio_core_isr, the real interrupt-fed RX path.
;   - sio_rx_kick, if a foreground caller explicitly invokes that fallback.
;
; Inputs from SIO core:
;   A = SIO channel id.
;   C = received byte.
; Preserved registers:
;   AF, BC, DE, HL are saved here as a local defensive boundary. The SIO ISR
;   also preserves them around the whole interrupt frame.
; Blocking behavior:
;   Must not block.
; VDrip traffic:
;   Must not emit VDP or cursor traffic. This routine can run inside the SIO ISR.
; Behavior:
;   Only SIO_CH_CONSOLE bytes are accepted. Before the initial terminal-ready
;   handshake, bytes feed the readiness recognizer and are consumed. After the
;   handshake, every byte is raw terminal input and is enqueued unchanged.
;   This is important for the ESC key: a standalone 1Bh must reach CONIN, not
;   remain trapped as the first byte of a possible readiness sequence.
vdrip_rx_sink:
	push af
	push bc
	push de
	push hl

	cp #SIO_CH_CONSOLE
	jr nz,vdrip_rx_sink_done

	; Once ready, bypass the readiness recognizer entirely.  It is not a
	; general input parser and would otherwise eat ESC while waiting to see
	; whether ESC starts ESC [ ? 1 ; 0 c.
	ld a,(vdrip_terminal_ready_flag)
	or a
	jr z,vdrip_rx_sink_wait_ready

	ld a,c
	call textq_put_ascii
	jr vdrip_rx_sink_done

vdrip_rx_sink_wait_ready:
	ld a,c
	call vdrip_terminal_ready_parse_byte

vdrip_rx_sink_done:
	pop hl
	pop de
	pop bc
	pop af
	ret


; ---------------------------------------------------------------------------
; vdrip_terminal_ready_parse_byte
;
; Tiny boot-time recognizer for raw VT100-style readiness:
;   ESC [ ? 1 ; 0 c
;
; Also accepts:
;   ESC [ ? 1 ; 2 c
;
; This is not a general input parser. It only runs while
; vdrip_terminal_ready_flag is zero. The recognized readiness bytes are consumed
; and never enqueued into textq. After the flag is set, vdrip_rx_sink bypasses
; this recognizer and enqueues all received bytes unchanged, including ESC.
;
; Input:
;   A = received raw byte.
; Output:
;   vdrip_terminal_ready_flag set to 1 when readiness is recognized.
; Clobbers:
;   AF, C.
; ---------------------------------------------------------------------------

vdrip_terminal_ready_parse_byte:
	ld c,a

	ld a,(vdrip_terminal_ready_state)
	cp #VDRIP_READY_WAIT_ESC
	jr z,vdrip_ready_wait_esc
	cp #VDRIP_READY_WAIT_LBRACKET
	jr z,vdrip_ready_wait_lbracket
	cp #VDRIP_READY_WAIT_QMARK
	jr z,vdrip_ready_wait_qmark
	cp #VDRIP_READY_WAIT_1
	jr z,vdrip_ready_wait_1
	cp #VDRIP_READY_WAIT_SEMI
	jr z,vdrip_ready_wait_semi
	cp #VDRIP_READY_WAIT_MODE
	jr z,vdrip_ready_wait_mode
	cp #VDRIP_READY_WAIT_C
	jr z,vdrip_ready_wait_c

	xor a
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_esc:
	ld a,c
	cp #0x1b
	ret nz
	ld a,#VDRIP_READY_WAIT_LBRACKET
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_lbracket:
	ld a,c
	cp #'[
	jr z,vdrip_ready_advance_qmark
	jr vdrip_ready_restart

vdrip_ready_advance_qmark:
	ld a,#VDRIP_READY_WAIT_QMARK
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_qmark:
	ld a,c
	cp #'?
	jr z,vdrip_ready_advance_1
	jr vdrip_ready_restart

vdrip_ready_advance_1:
	ld a,#VDRIP_READY_WAIT_1
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_1:
	ld a,c
	cp #'1
	jr z,vdrip_ready_advance_semi
	jr vdrip_ready_restart

vdrip_ready_advance_semi:
	ld a,#VDRIP_READY_WAIT_SEMI
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_semi:
	ld a,c
	cp #';
	jr z,vdrip_ready_advance_mode
	jr vdrip_ready_restart

vdrip_ready_advance_mode:
	ld a,#VDRIP_READY_WAIT_MODE
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_mode:
	ld a,c
	cp #'0
	jr z,vdrip_ready_advance_c
	cp #'2
	jr z,vdrip_ready_advance_c
	jr vdrip_ready_restart

vdrip_ready_advance_c:
	ld a,#VDRIP_READY_WAIT_C
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_wait_c:
	ld a,c
	cp #'c
	jr z,vdrip_ready_complete
	jr vdrip_ready_restart

vdrip_ready_complete:
	; Increment the sequence counter on every completion.
	; Cold boot: vdrip_wait_for_terminal_ready sees count > 0.
	; Reconnect: CONST sees count > 1.
	ld a,(vdrip_ready_seq_count)
	inc a
	ld (vdrip_ready_seq_count),a

	; Keep the readiness flag for the cold-boot wait loop.
	ld a,#0x01
	ld (vdrip_terminal_ready_flag),a

	; Reset parser state so we can detect the next sequence.
	xor a
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_restart:
	ld a,c
	cp #0x1b
	jr z,vdrip_ready_restart_after_esc
	xor a
	ld (vdrip_terminal_ready_state),a
	ret

vdrip_ready_restart_after_esc:
	ld a,#VDRIP_READY_WAIT_LBRACKET
	ld (vdrip_terminal_ready_state),a
	ret


; ===========================================================================
; RTS flow-control primitives
; ===========================================================================
;
; Naming note:
;   "Assert RTS" and "release RTS" are logical names used by this BIOS layer.
;   The actual SIO WR5 bit polarity and RS-232 electrical level can be mentally
;   inverted, so reason about these helpers by behavior:
;
;   vdrip_rts_assert_raw:
;     Tell the proxy/host that the Z80 side is ready to receive keyboard input.
;
;   vdrip_rts_release_raw:
;     Tell the proxy/host to stop or pause sending keyboard input.
;
; This driver releases RTS while it is not ready for input, when textq reaches
; its high-water mark, and around large VDP output bursts such as scroll/redraw
; where serial bandwidth is dominated by Z80-to-proxy display traffic. RTS is
; asserted again when the input queue drains to the low-water mark or after a
; burst completes.
;
; Existing counters:
;   rts_assert_count and rts_release_count are pre-existing state counters used
;   to observe RTS transitions. This documentation pass does not add new
;   diagnostics or change how they are updated.
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


; ===========================================================================
; Obsolete proxy-to-Z80 framed input parser
; ===========================================================================
;
; This code is no longer active in the keyboard input path. Proxy-to-Z80
; keyboard input is raw terminal bytes after the VT100-style readiness response,
; and vdrip_rx_sink does not call vdrip_parse_rx_byte. The framed packet sender
; below remains active for Z80-to-proxy display/control output.
;
; The old parser is left here temporarily to keep the diff focused while the
; input protocol changes. Do not reintroduce PACKET_TERMINAL_INPUT as a normal
; keyboard input path.
;
; State machine:
;
;   WAIT_SYNC0:
;     wait for A5.
;
;   WAIT_SYNC1:
;     wait for 5A. If another A5 arrives, remain one byte into sync so repeated
;     sync bytes can still lock onto a frame.
;
;   LEN:
;     validate packet length and initialize body buffer / counters.
;
;   BODY:
;     collect TYPE, PAYLOAD, and CRC bytes into vdrip_packet_body.
;
;   COMPLETE:
;     validate CRC, dispatch packet type, then reset parser state.
;
; Wire format:
;   A5 5A LEN TYPE PAYLOAD... CRC
;
; LEN semantics:
;   LEN includes LEN itself, TYPE, PAYLOAD, and CRC. A zero-payload packet has
;   LEN = VDRIP_WIRE_OVERHEAD = 3.
;
; vdrip_packet_body layout after LEN has been accepted:
;   +0 = LEN
;   +1 = TYPE
;   +2... = PAYLOAD bytes, if any
;   final collected byte = received CRC
;
; CRC semantics:
;   CRC covers LEN, TYPE, and PAYLOAD. It does not include A5/5A sync bytes and
;   does not include the received CRC byte itself.
;
; Obsolete BIOS-consumed proxy-to-Z80 packet types:
;   PACKET_PROXY_READY used to set a framed ready flag.
;   PACKET_TERMINAL_INPUT used to enqueue payload bytes into textq.
;
; Other packet types:
;   Valid packets with unhandled types are ignored after CRC validation.
;
; CRC failure:
;   crc_fail_count is incremented and the parser resets to WAIT_SYNC0.
;
; Historical ISR rule:
;   This parser used to be called from vdrip_rx_sink. If this code is ever
;   repurposed, it still must not emit VDP/display traffic, call CONOUT, block on
;   serial TX, redraw the screen, or touch CP/M/BDOS state directly.

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
		; Obsolete framed READY path. This parser is inactive for keyboard input,
		; but if reached accidentally, do not enqueue the packet.
		ld a,#0x01
		ld (vdrip_terminal_ready_flag),a
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
; Obsolete terminal input packet handling
; ===========================================================================
;
; PACKET_TERMINAL_INPUT / keyboard input packets
;   This is no longer active for keyboard input. Raw terminal bytes now bypass
;   the framed packet parser and enqueue directly from vdrip_rx_sink.
;
; Payload semantics:
;   Payload bytes are raw terminal input bytes. The input path does not translate
;   or interpret them. Examples:
;     Ctrl-X   -> 18h
;     Enter    -> 0Dh
;     Arrow-up -> 1Bh 5Bh 41h

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
; CONOUT terminal renderer — ANSI/VT-100 light
; ===========================================================================
;
; This parser applies to CP/M output only. It is reached from CONOUT and must
; not be used for keyboard input. Keyboard bytes remain raw in textq until CP/M
; reads them through CONIN.
;
; term_process_byte interprets a single byte and renders it to the VDP
; text display.  Supports printable characters, CR/LF, backspace, tab,
; and ANSI/CSI sequences with numeric parameters needed by Turbo Pascal
; and similar CP/M programs.
;
; Normal bytes supported:
;   printable ASCII 20h..7Eh
;   CR  = 0Dh
;   LF  = 0Ah
;   VT/FF = treated as LF
;   BS  = 08h
;   TAB = 09h
;   NUL/BEL/SO/SI and other controls are consumed, not printed
;
; ANSI/CSI sequences supported:
;   ESC c              RIS — reset terminal (triple-Esc also works)
;   ESC D/E/M          IND / NEL / RI (RI does not scroll down yet)
;   ESC H              HTS consumed; fixed tab stops remain active
;   ESC 7              save cursor position and attributes
;   ESC 8              restore saved cursor position and attributes
;   ESC Z              DECID consumed; response deferred
;   ESC = / ESC >      keypad modes consumed; input mapping unchanged
;   ESC ( B / ESC ) B  ASCII charset designation consumed
;   ESC ( 0 / ESC ) 0  DEC special graphics designation consumed
;   ESC [ row ; col H  cursor position (1-based)
;   ESC [ row ; col f  cursor position (alternate)
;   ESC [ n G          cursor horizontal absolute
;   ESC [ n d          cursor vertical absolute
;   ESC [ A/B/C/D      cursor up/down/forward/back
;   ESC [ n A/B/C/D    with repeat count (0 treated as 1)
;   ESC [ s            save cursor (CSI form)
;   ESC [ u            restore cursor (CSI form)
;   ESC [ 2 J          erase entire screen, cursor home
;   ESC [ 0 J / ESC [ J  erase from cursor to end of screen
;   ESC [ 1 J          erase from start of screen through cursor
;   ESC [ K / 0 K      erase from cursor to end of line
;   ESC [ 1 K          erase from start of line through cursor
;   ESC [ 2 K          erase entire current line
;   ESC [ n X          erase n characters from cursor position
;   ESC [ m / 0 m      reset SGR attributes (no visual effect)
;   ESC [ 1/4/5 m      bold/underline/blink consumed, no visual effect
;   ESC [ 7/27 m       reverse on/off tracked, not rendered
;   ESC [ 22/24/25 m   style-off params consumed, no visual effect
;   ESC [ 30-37/40-47 m  colors consumed, no visual effect
;   ESC [ c / 0 c      device attributes consumed; response deferred
;   ESC [ 5 n / 6 n    device status consumed; response deferred
;   ESC [ ? 25 h       show cursor (DEC private)
;   ESC [ ? 25 l       hide cursor
;   ESC [ ? 1/3/6/7 h/l  DEC private modes consumed safely
;
; Unsupported CSI / DEC private sequences are consumed safely.
; CSI parser supports '?' prefix for DEC private sequences.
; Scroll regions, insert/delete line, insert/delete character, tab clearing,
; origin mode, 132-column mode, and DEC special graphics rendering are deferred
; and are consumed where their ESC/CSI forms are recognized.
; ANSI coordinates are 1-based; internal coordinates are 0-based.
; Tab stops are 8 columns (VT100 standard).
; Text80 cannot render font effects; reverse video, bold, underline, blink, and
; color are parsed/consumed but intentionally have no visual effect.
;
; Output parser states:
;   NORMAL -> ESC (on 0x1b) -> CSI (on '[')
;   ESC_HASH and CHARSET consume one following byte, then return to NORMAL.
; CSI accumulates digits and ';' separators, dispatches on final byte.
;
; Parser state variables:
;   term_state       = NORMAL/ESC/CSI/ESC_HASH/CHARSET.
;   csi_param0      = first numeric CSI parameter.
;   csi_param1      = second numeric CSI parameter.
;   csi_param_count = number of stored numeric parameters.
;   csi_accum       = current decimal parameter being accumulated.
;   csi_have_digit  = nonzero after at least one digit in current parameter.
;   csi_private_flag = nonzero after a DEC private '?' prefix.
;   esc_press_count = triple-Esc display reset counter.

term_process_byte:
	ld c,a

	ld a,(term_state)
	cp #TERM_STATE_ESC
	jp z,term_process_esc

	cp #TERM_STATE_CSI
	jp z,term_process_csi
	cp #TERM_STATE_ESC_HASH
	jp z,term_consume_one
	cp #TERM_STATE_CHARSET
	jp z,term_consume_one

	; ---- NORMAL state ----
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

	cp #0x0d
	jp z,term_cr

	cp #0x0a
	jp z,term_lf
	cp #0x0b
	jp z,term_lf
	cp #0x0c
	jp z,term_lf

	cp #0x20
	ret c
	cp #0x7f
	ret nc

	jp text_put_printable


; ---------------------------------------------------------------------------
; ESC state
; ---------------------------------------------------------------------------

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

	; Another Esc while in ESC state — count it.
	ld a,c
	cp #0x1b
	jr z,term_enter_esc

	; Non-ESC byte — reset triple-Esc counter.
	push af
	xor a
	ld (esc_press_count),a
	pop af

	cp #'[
	jr nz,term_esc_not_csi

	; Enter CSI — reset parser variables.
	ld a,#TERM_STATE_CSI
	ld (term_state),a

	xor a
	ld (csi_param0),a
	ld (csi_param1),a
	ld (csi_param_count),a
	ld (csi_accum),a
	ld (csi_have_digit),a
	ld (csi_private_flag),a
	ret

term_esc_not_csi:
	; ESC # x — consume one character-set/screen-control final byte.
	cp #'#
	jr z,term_enter_esc_hash
	; ESC ( x / ESC ) x — consume G0/G1 character-set designation.
	cp #'(
	jr z,term_enter_charset
	cp #')
	jr z,term_enter_charset
	; ESC D — IND, index down within the current terminal model.
	cp #'D
	jp z,term_lf
	; ESC E — NEL, carriage return plus line feed.
	cp #'E
	jp z,term_nel
	; ESC M — RI, reverse index. Scroll-down-at-top is deferred.
	cp #'M
	jp z,term_reverse_index
	; ESC H — HTS, dynamic tab stops deferred; consume safely.
	cp #'H
	ret z
	; ESC 7 — save cursor and attributes.
	cp #'7
	jp z,ansi_save_cursor
	; ESC 8 — restore cursor and attributes.
	cp #'8
	jp z,ansi_restore_cursor
	; ESC Z — DECID. Response is deferred because cursor-key application
	; mode is not coupled to the proxy-side raw keyboard mapper.
	cp #'Z
	ret z
	; ESC = / ESC > — keypad modes. Input mapping is unchanged; consume.
	cp #'=
	ret z
	cp #'>
	ret z
	; ESC c — RIS (reset terminal), already handled by triple-Esc.
	cp #'c
	jp z,vdrip_reset_display
term_esc_done:
	ret

term_enter_esc_hash:
	ld a,#TERM_STATE_ESC_HASH
	ld (term_state),a
	ret

term_enter_charset:
	ld a,#TERM_STATE_CHARSET
	ld (term_state),a
	ret

term_consume_one:
	xor a
	ld (term_state),a
	ld (esc_press_count),a
	ret


; ---------------------------------------------------------------------------
; CSI parser state
; ---------------------------------------------------------------------------

term_process_csi:
	ld a,c

	; Digit '0'..'9' — accumulate.
	cp #'0
	jr c,term_csi_not_digit
	cp #'9+1
	jr nc,term_csi_not_digit

	sub #'0
	ld e,a

	ld a,(csi_accum)
	add a,a		; *2
	ld d,a
	add a,a		; *4
	add a,a		; *8
	add a,d		; *10
	add a,e
	ld (csi_accum),a

	ld a,#1
	ld (csi_have_digit),a
	ret

term_csi_not_digit:
	; Question mark — DEC private sequence prefix.
	cp #'?
	jr nz,term_csi_not_qmark
	ld a,(csi_param_count)
	or a
	jr nz,term_csi_not_qmark	; ? only valid as first char
	ld a,#0x01
	ld (csi_private_flag),a
	ret

term_csi_not_qmark:
	; Semicolon — advance to next param slot.
	cp #';
	jr nz,term_csi_final

	call ansi_store_param
	ret

term_csi_final:
	; Final command byte — store any pending param, then dispatch.
	push af		; save command byte across ansi_store_param
	call ansi_store_param

	; Reset state and triple-Esc counter.
	xor a
	ld (term_state),a
	ld (esc_press_count),a

	pop af

	call ansi_dispatch_csi
	ret


; ---------------------------------------------------------------------------
; ANSI helpers
; ---------------------------------------------------------------------------

; Store csi_accum into the current param slot (0-based index in
; csi_param_count).  Advance csi_param_count, capped at CSI_MAX_PARAMS.
; Clears csi_accum and csi_have_digit.
ansi_store_param:
	ld a,(csi_param_count)
	cp #CSI_MAX_PARAMS
	jr nc,ansi_store_param_reset

	; Select slot: 0 -> csi_param0, 1 -> csi_param1.  If no digits were
	; seen, csi_accum is zero; later default helpers treat zero as one for
	; VT100-style cursor counts and coordinates.
	ld a,(csi_accum)
	push af
	ld a,(csi_param_count)
	or a
	jr nz,ansi_store_slot1

	pop af
	ld (csi_param0),a
	jr ansi_store_inc

ansi_store_slot1:
	pop af
	ld (csi_param1),a

ansi_store_inc:
	ld a,(csi_param_count)
	inc a
	ld (csi_param_count),a

ansi_store_param_reset:
	xor a
	ld (csi_accum),a
	ld (csi_have_digit),a
	ret


; Return param0, default 1 if count == 0.
; Output: A = param value (at least 1).
ansi_param0_default_1:
	ld a,(csi_param_count)
	or a
	jr z,ansi_pd1_ret1
	ld a,(csi_param0)
	or a
	jr z,ansi_pd1_ret1
	ret
ansi_pd1_ret1:
	ld a,#1
	ret

; Return param1, default 1 if count < 2.
; Output: A = param value (at least 1).
ansi_param1_default_1:
	ld a,(csi_param_count)
	cp #2
	jr c,ansi_pd1_ret1
	ld a,(csi_param1)
	or a
	jr z,ansi_pd1_ret1
	ret


; ---------------------------------------------------------------------------
; CSI dispatch
; ---------------------------------------------------------------------------

ansi_dispatch_csi:
	ld c,a		; C = final command byte

	; DEC private mode (ESC [ ? ... h/l).
	ld a,(csi_private_flag)
	or a
	jr z,ansi_dispatch_public

	ld a,c
	cp #CSI_DECSET
	jp z,ansi_decset
	cp #CSI_DECRST
	jp z,ansi_decrst
	ret		; unsupported DEC private — consume

ansi_dispatch_public:
	ld a,c
	cp #CSI_CHA
	jp z,ansi_cha
	cp #CSI_CUU
	jp z,ansi_cuu
	cp #CSI_CUD
	jp z,ansi_cud
	cp #CSI_CUF
	jp z,ansi_cuf
	cp #CSI_CUB
	jp z,ansi_cub
	cp #CSI_CUP
	jp z,ansi_cup
	cp #CSI_CUP_ALT
	jp z,ansi_cup
	cp #CSI_VPA
	jp z,ansi_vpa
	cp #CSI_ED
	jp z,ansi_ed
	cp #CSI_EL
	jp z,ansi_el
	cp #'X
	jp z,ansi_ech
	cp #CSI_SGR
	jp z,ansi_sgr
	cp #'c
	ret z
	cp #'n
	ret z
	cp #CSI_SAVE
	jp z,ansi_save_cursor
	cp #CSI_RESTORE
	jp z,ansi_restore_cursor
	; Unsupported CSI / DEC private fallthrough — consume.
	ret


; ---- CSI CUP / CUF / CUB / CUU / CUD ----

ansi_cuu:
	call ansi_param0_default_1	; A = n
	ld b,a
ansi_cuu_loop:
	push bc
	call term_cursor_up
	pop bc
	djnz ansi_cuu_loop
	ret

ansi_cud:
	call ansi_param0_default_1
	ld b,a
ansi_cud_loop:
	push bc
	call term_cursor_down
	pop bc
	djnz ansi_cud_loop
	ret

ansi_cuf:
	call ansi_param0_default_1
	ld b,a
ansi_cuf_loop:
	push bc
	call term_cursor_right
	pop bc
	djnz ansi_cuf_loop
	ret

ansi_cub:
	call ansi_param0_default_1
	ld b,a
ansi_cub_loop:
	push bc
	call term_cursor_left
	pop bc
	djnz ansi_cub_loop
	ret

; ---- CSI CHA/VPA: absolute column / row ----

ansi_cha:
	call ansi_param0_default_1	; A = col (1-based)
	dec a
	cp #TEXT_LOG_COLUMNS
	jr c,ansi_cha_clamped
	ld a,#(TEXT_LOG_COLUMNS - 1)
ansi_cha_clamped:
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

ansi_vpa:
	call ansi_param0_default_1	; A = row (1-based)
	dec a
	cp #TEXT_ROWS
	jr c,ansi_vpa_clamped
	ld a,#(TEXT_ROWS - 1)
ansi_vpa_clamped:
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret


; ---- CSI CUP: cursor position (row;col H  or  row;col f) ----

ansi_cup:
	call ansi_param0_default_1	; A = row (1-based)
	dec a
	cp #TEXT_ROWS
	jr c,ansi_cup_row_clamped
	ld a,#(TEXT_ROWS - 1)
ansi_cup_row_clamped:
	ld (text_row),a

	call ansi_param1_default_1	; A = col (1-based)
	dec a
	cp #TEXT_LOG_COLUMNS
	jr c,ansi_cup_col_clamped
	ld a,#(TEXT_LOG_COLUMNS - 1)
ansi_cup_col_clamped:
	ld (text_col),a

	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret


; ---- CSI ED: erase in display ----

ansi_ed:
	; param0 == 0 or missing: clear from cursor to end of screen.
	; param0 == 1: clear from start of screen through cursor.
	; param0 == 2: clear whole screen. This implementation homes the cursor
	; for CP/M full-screen program compatibility.
	ld a,(csi_param_count)
	or a
	jr z,ansi_ed_to_eos

	ld a,(csi_param0)
	or a
	jr z,ansi_ed_to_eos
	dec a
	jr z,ansi_ed_from_start
	dec a
	ret nz

	call text_clear_screen_runtime
	ret

ansi_ed_to_eos:
	call text_clear_from_cursor_to_eos
	ret

ansi_ed_from_start:
	call text_clear_from_start_to_cursor
	ret


; ---- CSI EL: erase in line ----

ansi_el:
	; param0 == 0 or missing: clear to end of line.
	; param0 == 1: clear from start of line through cursor.
	; param0 == 2: clear whole line.
	ld a,(csi_param_count)
	or a
	jr z,ansi_el_to_eol		; default: clear to EOL

	ld a,(csi_param0)
	or a
	jr z,ansi_el_to_eol		; ESC [ 0 K
	dec a
	jr z,ansi_el_from_start		; ESC [ 1 K

ansi_el_whole_line:
	call text_clear_line
	ret

ansi_el_to_eol:
	call text_clear_to_eol
	ret

ansi_el_from_start:
	call text_clear_from_sol_to_cursor
	ret


; ---- CSI ECH: erase n characters from cursor to the right ----

ansi_ech:
	call ansi_param0_default_1
	ld e,a				; requested count
	ld a,(text_col)
	ld d,a
	ld a,#TEXT_LOG_COLUMNS
	sub d				; remaining columns
	ret z
	cp e
	jr nc,ansi_ech_count_ok
	ld e,a
ansi_ech_count_ok:
	call text_shadow_addr_current
	push hl
	ld b,e
	ld a,#0x20
ansi_ech_shadow_loop:
	ld (hl),a
	inc hl
	djnz ansi_ech_shadow_loop

	ld a,e
	push af
	call text_cursor_to_vram
	pop af
	pop hl
	ld c,a
	ld b,#0x00
	call vdp_write_data_block
	call vdrip_send_frame_mark
	ret


; ---- CSI SGR: select graphic rendition ----

ansi_sgr:
	; Consume SGR.  Track reverse video in current_attr.
	; 0=reset, 7=reverse on, 27=reverse off. Other font/color
	; parameters are consumed with no visual effect in Text80.
	ld a,(csi_param_count)
	or a
	jr z,ansi_sgr_reset
	ld a,(csi_param0)
	call ansi_sgr_apply_param
	ld a,(csi_param_count)
	cp #2
	ret c
	ld a,(csi_param1)
	call ansi_sgr_apply_param
	ret

ansi_sgr_apply_param:
	or a
	jr z,ansi_sgr_reset
	cp #7
	jr z,ansi_sgr_rev_on
	cp #27
	jr z,ansi_sgr_rev_off
	ret		; 1,4,5,22,24,25,30-47,etc — consume
ansi_sgr_reset:
	xor a
	ld (current_attr),a
	ret
ansi_sgr_rev_on:
	ld a,#0x01
	ld (current_attr),a
	ret
ansi_sgr_rev_off:
	xor a
	ld (current_attr),a
	ret


; ---- ANSI save/restore cursor (ESC 7/8 and CSI s/u) ----

ansi_save_cursor:
	ld a,(text_col)
	ld (text_cursor_saved_col),a
	ld a,(text_row)
	ld (text_cursor_saved_row),a
	ld a,(current_attr)
	ld (text_attr_saved),a
	ret

ansi_restore_cursor:
	ld a,(text_cursor_saved_col)
	ld (text_col),a
	ld a,(text_cursor_saved_row)
	ld (text_row),a
	ld a,(text_attr_saved)
	ld (current_attr),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret


; ---- DEC private modes (ESC [ ? ... h/l) ----

ansi_decset:
	ld a,(csi_param_count)
	or a
	ret z
	ld a,(csi_param0)
	cp #25
	jr z,ansi_show_cursor
	ret		; ?7h etc — consume

ansi_show_cursor:
	call vdrip_cursor_show
	ret

ansi_decrst:
	ld a,(csi_param_count)
	or a
	ret z
	ld a,(csi_param0)
	cp #25
	jr z,ansi_hide_cursor
	ret		; ?7l etc — consume

ansi_hide_cursor:
	call vdrip_cursor_hide
	ret


; ===========================================================================
; Terminal action helpers
; ===========================================================================

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

term_cr:
	; Carriage return — column 0, row unchanged.
	xor a
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_lf:
	; Line feed — move down one row, preserving column.
	ld a,(text_col)
	push af
	call text_newline
	pop af
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_nel:
	; Next line — CR + LF.
	xor a
	ld (text_col),a
	call text_newline
	call vdrip_cursor_set_position_current
	ret

term_reverse_index:
	; Reverse index — move up one row. Region scroll-down is deferred.
	ld a,(text_row)
	or a
	ret z
	dec a
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret

term_backspace:
	ld a,(text_col)
	or a
	ret z

	dec a
	ld (text_col),a

	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_tab:
	; Advance to next 8-column tab stop (VT100 standard).
	call text_advance_cursor
	ld a,(text_col)
	and #0x07
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
	xor a
	ld (text_col),a
	ld (text_row),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret

term_cursor_end:
	ld a,#(TEXT_LOG_COLUMNS - 1)
	ld (text_col),a
	call text_ensure_cursor_visible
	call vdrip_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_screen_runtime — clear screen at runtime (for ESC [ 2 J)
;
; Clears shadow buffer and VDP name table. Resets cursor to 0,0.
; RTS must be released before calling. Sends FRAME_MARK after.
; ---------------------------------------------------------------------------

text_clear_screen_runtime:
	; Clear shadow buffer to spaces.
	ld hl,#text_shadow
	ld bc,#TEXT_SHADOW_SIZE
	ld a,#0x20
text_clear_runtime_shadow_loop:
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	ld a,#0x20
	jr nz,text_clear_runtime_shadow_loop

	; Blast shadow to VDP.
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr

	ld hl,#text_shadow
	ld bc,#TEXT_PHYS_CELLS
	call vdp_write_data_block

	; Reset cursor and viewport.
	xor a
	ld (text_col),a
	ld (text_row),a
	ld (text_view_col),a

	call vdrip_cursor_set_position_current
	call vdrip_send_frame_mark
	ret


; ---------------------------------------------------------------------------
; text_clear_from_cursor_to_eos — ED 0: cursor through end of screen.
; Cursor position is restored after the erase.
; ---------------------------------------------------------------------------
text_clear_from_cursor_to_eos:
	ld a,(text_col)
	ld (ansi_tmp_col),a
	ld a,(text_row)
	ld (ansi_tmp_row),a

	call text_clear_to_eol

	ld a,(ansi_tmp_row)
	inc a
	cp #TEXT_ROWS
	jr nc,text_clear_eos_restore

text_clear_eos_row_loop:
	ld (text_row),a
	xor a
	ld (text_col),a
	call text_clear_to_eol
	ld a,(text_row)
	inc a
	cp #TEXT_ROWS
	jr c,text_clear_eos_row_loop

text_clear_eos_restore:
	ld a,(ansi_tmp_col)
	ld (text_col),a
	ld a,(ansi_tmp_row)
	ld (text_row),a
	call vdrip_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_from_start_to_cursor — ED 1: screen start through cursor.
; Cursor position is restored after the erase.
; ---------------------------------------------------------------------------
text_clear_from_start_to_cursor:
	ld a,(text_col)
	ld (ansi_tmp_col),a
	ld a,(text_row)
	ld (ansi_tmp_row),a
	or a
	jr z,text_clear_stc_current_row

	ld b,a
	xor a
	ld (text_row),a

text_clear_stc_row_loop:
	xor a
	ld (text_col),a
	push bc
	call text_clear_line
	pop bc
	ld a,(text_row)
	inc a
	ld (text_row),a
	djnz text_clear_stc_row_loop

text_clear_stc_current_row:
	ld a,(ansi_tmp_row)
	ld (text_row),a
	ld a,(ansi_tmp_col)
	ld (text_col),a
	call text_clear_from_sol_to_cursor
	call vdrip_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_to_eol — clear from cursor to end of logical line (ESC [ K)
; ---------------------------------------------------------------------------

text_clear_to_eol:
	; Clear shadow bytes from cursor to end of logical row.
	call text_shadow_addr_current	; HL = shadow addr for cursor
	ld a,(text_col)
	ld e,a
	ld a,#TEXT_LOG_COLUMNS
	sub e				; A = columns remaining
	jr z,text_clear_to_eol_done
	ld b,a
	push hl				; save shadow start
text_clear_to_eol_shadow_loop:
	ld (hl),#0x20
	inc hl
	djnz text_clear_to_eol_shadow_loop

	; Now blast the cleared portion to VDP from the shadow buffer.
	call text_cursor_to_vram	; set VDP write address
	pop hl				; HL = shadow source
	ld a,(text_col)
	ld e,a
	ld a,#TEXT_LOG_COLUMNS
	sub e
	ld c,a
	ld b,#0x00			; BC = count
	call vdp_write_data_block

	; FRAME_MARK so the proxy renders the updated row.
	call vdrip_send_frame_mark
	ret

text_clear_to_eol_done:
	ret


; ---------------------------------------------------------------------------
; text_clear_line — clear entire current logical line (ESC [ 2 K)
; ---------------------------------------------------------------------------

text_clear_line:
	; Save current cursor column.
	ld a,(text_col)
	push af

	; Move to column 0 on same row and clear to EOL.
	xor a
	ld (text_col),a
	call text_clear_to_eol

	; Restore cursor column.
	pop af
	ld (text_col),a
	ret


; ---------------------------------------------------------------------------
; text_clear_from_sol_to_cursor — EL 1: start of line through cursor.
; Cursor position unchanged.  Uses block write.
; ---------------------------------------------------------------------------
text_clear_from_sol_to_cursor:
	ld a,(text_col)
	ld e,a			; save original col

	xor a
	ld (text_col),a
	call text_cursor_to_vram	; VDP addr at col 0

	ld a,e
	inc a			; count = col + 1
	ld c,a
	ld b,#0x00

	call text_shadow_addr_current	; HL = shadow[row][0]
	push hl
	push bc
	ld a,#0x20
text_clear_stc_fill:
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	ld a,#0x20
	jr nz,text_clear_stc_fill

	pop bc
	pop hl
	call vdp_write_data_block

	ld a,e
	ld (text_col),a
	call vdrip_send_frame_mark
	ret


; ===========================================================================
; Console input queue
; ===========================================================================
;
; textq is the CP/M CONIN FIFO.
;
; FIFO ownership:
;   Producer:
;     vdrip_rx_sink calls textq_put_ascii directly after terminal readiness.
;     The producer may be running in the SIO ISR path.
;
;   Consumer:
;     vdrip_console_conin runs in CP/M foreground code. It removes the oldest
;     byte from textq and returns it in A.
;
; FIFO variables:
;   textq_head  = producer write index.
;   textq_tail  = consumer read index.
;   textq_count = availability indicator used by CONST.
;   textq_buffer = raw terminal byte storage.
;
; Semantics:
;   This queue is FIFO, not LIFO. CONST never consumes data; it only checks
;   textq_count. CONIN consumes exactly one oldest queued byte. Input bytes are
;   raw terminal bytes and are not interpreted here:
;     Ctrl-X   -> 18h
;     Enter    -> 0Dh
;     Arrow-up -> 1Bh 5Bh 41h
;
; Concurrency:
;   The producer must remain short and non-blocking because it can run under the
;   SIO RX ISR. The foreground consumer disables interrupts around dequeue so
;   tail/count updates cannot race the ISR producer. The producer updates
;   head/count as a small bounded operation.

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

	; Skip VDP address setup if writing to the expected next
	; address (auto-increment from previous write).
	ld a,(vdp_addr_valid)
	or a
	jr z,text_cursor_vram_do_setup

	ld de,(vdp_addr_next)
	or a		; clear carry
	sbc hl,de
	jr nz,text_cursor_vram_do_setup

	; Match — auto-increment handles it.  Update next-expected.
	inc de
	ld (vdp_addr_next),de
	ret

text_cursor_vram_do_setup:
	; Mismatch or first write — send VDP address.
	add hl,de	; restore HL from sbc
	call vdp_set_vram_write_addr
	; Track next expected address.
	inc hl
	ld (vdp_addr_next),hl
	ld a,#0x01
	ld (vdp_addr_valid),a
	ret


; ===========================================================================
; RTS flow control
; ===========================================================================
;
; Queue thresholds:
;   TEXTQ_RTS_HIGH_WATER:
;     When textq_count reaches this value, textq_put_ascii releases RTS to ask
;     the host/proxy to stop sending more terminal input.
;
;   TEXTQ_RTS_LOW_WATER:
;     When CONIN drains textq to or below this value, app_maybe_resume_rts
;     asserts RTS so host input can resume.
;
; Large VDP bursts:
;   Scroll/redraw/clear traffic can consume many bytes over a 115200 baud serial
;   link. Those routines release RTS before the burst to keep keyboard input from
;   competing with display traffic, then assert RTS after the burst or after the
;   input queue drains.

app_maybe_resume_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret z				; already asserted

	; Re-assert RTS when textq drains to/below the low-water mark.
	ld a,(textq_count)
	cp #(TEXTQ_RTS_LOW_WATER + 1)
	ret nc

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
; into the 80-column VDP viewport, using the current text_view_col.
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

		; Write one physical row from shadow to VDP as a block.
	ld bc,#TEXT_PHYS_COLUMNS
	call vdp_write_data_block

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

	; Hardware scroll: tell the proxy to shift its name table up
	; by one row.  One 7-byte packet instead of a 2084-byte screen
	; blast — scroll becomes nearly instant at 115200 baud.
	ld a,#0x01
	call vdrip_send_scroll
	call vdrip_send_frame_mark

	; The proxy scroll handler moved the VDP address pointer; our
	; auto-increment tracking is now stale.  Force a full address
	; setup on the next VDP write.
	xor a
	ld (vdp_addr_valid),a

	; Cursor to bottom row, col 0.
	xor a
	ld (text_col),a
	ld (text_view_col),a
	ld a,#(TEXT_SCROLL_BOTTOM)
	ld (text_row),a

	; Reassert RTS unconditionally after a scroll burst.
	; app_maybe_resume_rts would skip if textq has data,
	; but the scroll just finished — input MUST resume.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


; ===========================================================================
; Proxy reconnection handler
; ===========================================================================
;
; Called from CONST when vdrip_reinit_requested is set (the readiness
; parser saw a second ESC [ ? 1 ; 0 c mid-session).  Reinitializes the
; VDP, blasts the current shadow buffer to the screen, and resumes
; normal operation.
;
; Clobbers: AF, BC, DE, HL.  Emits VDrip traffic; RTS is released
; during the burst.

vdrip_handle_reconnect:
	; Reset the sequence counter so we don't re-enter.
	ld a,#0x01
	ld (vdrip_ready_seq_count),a

	; Release RTS for the burst.  rts_release_raw returns A=0.
	call vdrip_rts_release_raw
	inc a
	ld (vdrip_rx_rts_released),a

	; Reinitialize VDP mode and font.  No RESET/PING needed — the
	; proxy restarted from scratch so its emulator is already fresh.
	call text_init_vdp
	call text_load_font

	; Blast the current shadow buffer to the name table.
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr
	ld hl,#text_shadow
	ld bc,#TEXT_PHYS_CELLS
	call vdp_write_data_block

	; Restore the cursor at its current position.
	; vdrip_cursor_init already calls set_position_current.
	call vdrip_cursor_init
	call vdrip_send_frame_mark

	; Re-assert RTS.  ready_flag is already 1 from the parser.
	call vdrip_rts_assert_raw
	ld (vdrip_rx_rts_released),a
	ret


; ===========================================================================
; VDP reset (triple-Esc)
; ===========================================================================
;
; Called when Esc is pressed three times rapidly.
; Re-initialises the VDP text mode, font, and virtual cursor.

vdrip_reset_display:
	xor a
	ld (esc_press_count),a
	ld (term_state),a
	ld (csi_param0),a
	ld (csi_param1),a
	ld (csi_param_count),a
	ld (csi_accum),a
	ld (csi_have_digit),a
	ld (csi_private_flag),a
	ld (current_attr),a
	ld (text_attr_saved),a

	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	call vdrip_send_reset
	call vdrip_send_ping
	call text_init_vdp
	call text_load_font
	call text_clear_screen

	xor a
	ld (text_col),a
	ld (text_row),a
	ld (text_view_col),a

	call vdrip_cursor_init
	call vdrip_send_frame_mark

	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


; ===========================================================================
; VDP text backend
; ===========================================================================
;
; Virtual Drip display model:
;   The backend is an 80-column 9928-like/Text80 display. The logical text
;   buffer and physical name table are both 80 columns by 24 rows in this build.
;   The VDP name table stores character codes. The pattern table stores the
;   ASCII 20h-7Fh font, 96 glyphs at 8 bytes per glyph, so writing ASCII bytes
;   directly into the name table selects the expected glyphs.
;
; Shadow buffer:
;   text_shadow mirrors the terminal text state and is the source for scroll,
;   clear, and redraw operations. Single-character output writes both shadow and
;   VDP when the cursor is visible.
;
; Serial cost:
;   VDP writes are currently emitted as single-byte Virtual Drip data/control
;   packets unless a helper loops over multiple bytes. Large operations are slow
;   over 115200 baud and are paced / RTS-gated. Future block packets could reduce
;   this cost, but this documentation pass does not implement them.

text_init_vdp:
	; R0 = 0
	ld b,#0x00
	ld a,#0x00
	call vdp_write_register

	; R1:
	;   16K mode
	;   display on
	;   Text 2 mode (M1=1, M2=1 for 80 columns)
	;
	; 0xD8 = 16K | display | Text 2
	ld b,#0x01
	ld a,#0xd8
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
; Clear 80x24 text screen to ASCII space — clears both VDP and shadow buffer.
; ---------------------------------------------------------------------------

text_clear_screen:
	; Clear the 80-column shadow buffer to spaces first, then blast
	; the entire shadow to the VDP name table in large DATA_BLOCK
	; chunks (VDRIP_DATA_BLOCK_MAX bytes each).  This eliminates the
	; need for a separate space-fill buffer.
	ld hl,#text_shadow
	ld bc,#TEXT_SHADOW_SIZE
	ld a,#0x20
text_clear_shadow_loop:
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	ld a,#0x20
	jr nz,text_clear_shadow_loop

	; VDP name table ← shadow buffer.
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr

	ld hl,#text_shadow
	ld bc,#TEXT_PHYS_CELLS
	call vdp_write_data_block
	ret


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
	; Invalidate sequential-address tracking — explicit address
	; setups (clear, font load, scroll) reset the auto-increment
	; assumption.
	xor a
	ld (vdp_addr_valid),a

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


; Write BC bytes from HL to current TMS9928A data port.
; Sends data as one or more PACKET_VDP_DATA_BLOCK packets, each at most
; VDRIP_DATA_BLOCK_MAX bytes. This amortises the per-packet framing
; overhead (sync, LEN, TYPE, CRC) over multiple data bytes and dramatically
; reduces serial traffic for font upload, screen clear, scroll redraw, and
; other bulk VDP writes.
;
; Input:
;   HL = source pointer
;   BC = byte count
; Output:
;   All bytes sent as PACKET_VDP_DATA_BLOCK chunk(s).
; Clobbers:
;   AF, BC, DE, HL.
; Preserves:
;   None promised.
; ---------------------------------------------------------------------------
vdp_write_data_block:
	jp vdrip_data_write_block

vdrip_data_write_block:
	; Quick exit for zero-byte request.
	ld a,b
	or c
	ret z

	; Save source pointer and remaining count for the chunk loop.
	ld (block_ptr_store),hl
	ld (block_count_store),bc

vdrip_data_block_chunk:
	; If remaining count == 0, all bytes sent.
	ld hl,(block_count_store)
	ld a,h
	or l
	ret z

	; B = min(remaining, VDRIP_DATA_BLOCK_MAX)
	; 16-bit compare: if H != 0 then remaining >= 256 > max.
	ld a,h
	or a
	jr nz,vdrip_data_block_use_max
	ld a,l
	cp #VDRIP_DATA_BLOCK_MAX
	jr nc,vdrip_data_block_use_max
	; remaining < max — use exact remaining count (fits in 8 bits).
	ld b,a
	jr vdrip_data_block_send

vdrip_data_block_use_max:
	ld b,#VDRIP_DATA_BLOCK_MAX

vdrip_data_block_send:
	; B = chunk size (payload length for vdrip_send_packet).
	; Send PACKET_VDP_DATA_BLOCK with HL pointing at current source data.
	push bc				; save chunk size
	ld a,#PACKET_VDP_DATA_BLOCK
	ld hl,(block_ptr_store)
	call vdrip_send_packet		; preserves BC, DE, HL
	pop bc				; B = chunk size just sent

	; Advance source pointer by chunk size.
	ld e,b
	ld d,#0x00
	ld hl,(block_ptr_store)
	add hl,de
	ld (block_ptr_store),hl

	; Decrement remaining count by chunk size.
	ld hl,(block_count_store)
	or a				; clear carry
	sbc hl,de
	ld (block_count_store),hl

	jr vdrip_data_block_chunk


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


; Send PACKET_VDP_SCROLL with one payload byte (row count).
; Input:  A = number of rows to scroll up (1-23).
; Clobbers: AF, BC, DE, HL (via vdrip_send_packet1).
vdrip_send_scroll:
	ld e,a
	ld a,#PACKET_VDP_SCROLL
	jp vdrip_send_packet1


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


vdrip_cursor_hide:
	ld hl,#packet_payload0
	ld (hl),#CURSOR_HIDE

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
	ld c,a
	; Ensure SIO register pointer is at RR0 before the shared sender reads
	; status. RTS toggles also write the SIO control port.
	xor a
	out (VDRIP_CTRL),a
	ld a,#SIO_CH_CONSOLE
	call sio_send_byte
	or a
	ret z

	; Last-resort escape from a stuck CTS line. Normal traffic still uses
	; sio_send_byte above and therefore preserves hardware flow control.
	xor a
	out (VDRIP_CTRL),a
vdrip_transport_wait_tx_empty:
	in a,(VDRIP_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,vdrip_transport_wait_tx_empty
	ld a,c
	out (VDRIP_DATA),a
	xor a
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
;
; Variables are grouped by subsystem without reordering code or changing storage.
; These live in the driver slot area with the code and are part of the current
; memory layout.

; Packet output temporary storage.
; Used by vdrip_send_packet* while constructing outbound Virtual Drip frames:
;   A5 5A LEN TYPE PAYLOAD... CRC
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

; RTS / input-gate state.
; Nonzero means the driver believes host input is currently paused by released
; RTS and app_maybe_resume_rts may need to assert RTS after queues drain.
vdrip_rx_rts_released:
	.db 0x00

; Raw terminal readiness state.
; vdrip_terminal_ready_flag is set after ESC [ ? 1 ; 0 c or ESC [ ? 1 ; 2 c.
; vdrip_terminal_ready_state tracks the byte-by-byte recognizer while the flag
; is still zero. These replace the old framed PACKET_PROXY_READY dependency.
vdrip_terminal_ready_flag:
	.db 0x00

vdrip_terminal_ready_state:
	.db VDRIP_READY_WAIT_ESC

; Set after first successful terminal readiness handshake; survives warm boot.
vdrip_handshake_done:
	.db 0x00

; Incremented on every ESC [ ? 1 ; 0 c completion by the readiness parser.
; 0 = never seen.  1 = cold-boot readiness done.  >1 = proxy reconnected.
vdrip_ready_seq_count:
	.db 0x00

; VDrip RX parser state.
; vdrip_packet_body contains LEN at +0, TYPE at +1, then payload bytes and the
; received CRC byte as they arrive. This parser state is obsolete for keyboard
; input and is not touched by vdrip_rx_sink in raw-input mode.
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

; Text cursor state.
; text_col/text_row are internal 0-based logical coordinates. text_view_col is
; the horizontal viewport offset into the 80-column logical buffer. In this
; Text80 build the physical and logical widths are both 80, so the offset should
; normally remain zero.
text_col:
	.db 0x00

text_row:
	.db 0x00

; Horizontal viewport offset into the 80-column logical buffer.
text_view_col:
	.db 0x00

; CONIN FIFO / textq.
; Producer writes at textq_head, consumer reads at textq_tail, and textq_count is
; the single-byte availability count used by CONST.
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

; ANSI output parser state.
; Applies only to CONOUT bytes. Keyboard input must not use this state machine.
term_state:
	.db TERM_STATE_NORMAL

; ANSI/CSI parser state.
csi_param0:
	.db 0x00
csi_param1:
	.db 0x00
csi_param_count:
	.db 0x00
csi_accum:
	.db 0x00
csi_have_digit:
	.db 0x00

; CSI parser: nonzero after '?' prefix (DEC private sequences).
csi_private_flag:
	.db 0x00

; Saved cursor for ESC 7/8 and CSI s/u.
text_cursor_saved_col:
	.db 0x00
text_cursor_saved_row:
	.db 0x00
text_attr_saved:
	.db 0x00

; Current SGR attribute.  bit 0 = reverse video.
current_attr:
	.db 0x00

; Temporary cursor save used by ED 0/1 helpers.
ansi_tmp_col:
	.db 0x00
ansi_tmp_row:
	.db 0x00

; VDP address tracking — skip redundant address setup when writing
; sequential characters (auto-increment handles it).
vdp_addr_next:
	.dw 0x0000
vdp_addr_valid:
	.db 0x00

; Obsolete terminal-input packet payload iterator.
; Used only by the inactive PACKET_TERMINAL_INPUT helper.
terminal_payload_ptr:
	.dw 0x0000

terminal_payload_count:
	.db 0x00

; Existing trace counters.
; These counters already existed before this documentation pass. They are useful
; when inspecting whether bytes reached CRC validation, terminal-input dispatch,
; queue overflow, and RTS transitions. No new diagnostics are added here.
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

; Obsolete framed-input readiness storage was removed from the active path.

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

VDRIP_CONSOLE_CODE_END:
