; Zephyr-80 Virtual Drip V9958 GRAPHIC 6 console BIOS driver.
;
; This module replaces the legacy SIO console driver as the active CP/M
; console backend. It owns terminal parsing, buffered semantic display
; commands, the V9958 sprite cursor, and the terminal input queue. The shared
; vdrip_transport module owns framing.
;
; Major subsystems:
;   - CP/M console dispatch table consumed by cbios_console.asm.
;   - Packetized PROXY_READY synchronization before normal VDP output traffic.
;   - Raw-byte callback registration with the shared transport.
;   - Input path: proxy-to-Z80 bytes are raw terminal input bytes after
;     readiness and are enqueued into textq, the CP/M CONIN FIFO.
;   - Output path: CP/M CONOUT bytes are interpreted by an ANSI/VT100-light
;     parser and emitted as V9958 logical-cell accelerator commands.
;   - BIOS-owned steady block cursor implemented as a mode-2 V9958 sprite.
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
;     proxy sends framed PROXY_READY
;     -> common vdrip_rx_sink
;     -> common frame parser
;     -> vdrip_proxy_online = 1
;
; Proxy-to-Z80 input is raw bytes. Z80-to-proxy display/control output remains
; framed Virtual Drip packets. Storage or future structured commands should stay
; framed or use a separate channel later; this pass changes keyboard input only.
;
; Output path:
;     CP/M calls CONOUT
;     -> vdrip_console_conout
;     -> ANSI/VT100-light parser
;     -> buffered text/cell command stream
;     -> logical cells and G6 bitmap in V9958 VRAM
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
;   SIO RX ISR → common vdrip_rx_sink → textq_put_ascii
;   CONST: check textq_count — no RX polling, kicking, or parsing
;   CONIN: block until textq_count > 0, dequeue oldest byte
;
; Startup sequence:
;   1. sio_core_init has already run; SIO0/B is configured but RTS is released.
;   2. Register raw callback/common RX sink, enable interrupts, assert RTS.
;   3. Wait for packetized PROXY_READY.
;   4. Once ready, initialize G6/interlace, upload CP850 atlas, and cursor.
;   5. Assert RTS and enter normal interactive mode.
;
; Does not contain:
;   - monitor .org, start:, or echo loop
;   - hardcoded BIOS helper addresses
;   - demo banners or dashboard redraws

	.module vdrip_console

	.globl vdrip_console_driver
	.globl vdrip_console_cold_init,vdrip_console_init,vdrip_console_const
	.globl vdrip_console_conin,vdrip_console_conout
	.globl vdrip_send_packet,vdrip_send_packet0,vdrip_send_packet1
	.globl vdrip_rts_assert_raw
	.globl vdrip_reset_display,vdrip_data_write_block
	.globl vdrip_rx_rts_released
	.globl hid_input_init,hid_input_status,hid_input_get
	.globl restore_font_from_rom
	.globl VDRIP_CONSOLE_CODE_START,VDRIP_CONSOLE_CODE_END

	; SIO core services — real BIOS symbols, not stale map addresses.
	.globl sio_core_enable_interrupts,sio_register_rx_sink,sio_rx_kick
	.globl sio_send_byte
	.globl sio0b_rts_assert,sio0b_rts_release
	.globl SIO_CH_CONSOLE
	.globl vdrip_transport_register_sink
	.globl vdrip_transport_set_raw_callback,vdrip_transport_set_idle_mode
	.globl vdrip_transport_wait_ready
	.globl vdrip_proxy_online

; ===========================================================================
; Constants
; ===========================================================================

; SIO0/B port aliases matching platform_zephyr80.inc / sio_core.asm.
VDRIP_DATA		= SIOB_DATA
VDRIP_CTRL		= SIOB_CTRL
SIO_RR0_TX_EMPTY	= 0x04
SIO_RR0_CTS		= 0x20

; V9958 GRAPHIC 6 console layout. The 512x212 source bitmap is woven into
; 512x424 output by R#9 IL+LN. Logical cells and the glyph atlas are stored
; outside the visible bitmap in the V9958's 128 KiB VRAM.
TEXT_LOG_COLUMNS	= 85
TEXT_ROWS		= 26
TEXT_SCROLL_TOP		= 0
TEXT_SCROLL_BOTTOM	= TEXT_ROWS - 1
TEXT_SCROLL_ROWS	= TEXT_ROWS
TEXT_CELL_WIDTH		= 6
TEXT_CELL_HEIGHT	= 8
TEXT_DISPLAY_OFFSET	= 4		; 208-line text area (26 rows) at source lines 4..211

G6_BITMAP_BASE		= 0x00000
G6_BITMAP_BYTES		= 256 * 212
V9958_CELL_BASE		= 0x0d400
V9958_CELL_BYTES	= TEXT_LOG_COLUMNS * TEXT_ROWS * 3
V9958_ATLAS_BASE	= 0x10000
V9958_ATLAS_COLS	= 32
V9958_ATLAS_ROWS	= 8
V9958_ATLAS_PITCH	= 256
V9958_ATLAS_BYTES	= V9958_ATLAS_ROWS * 8 * V9958_ATLAS_PITCH

; Sprite-mode-2 cursor allocations. SAT includes sprite zero plus terminator.
V9958_CURSOR_COLOR_BASE	= 0x1f000
V9958_CURSOR_SAT_BASE	= 0x1f200
V9958_CURSOR_PATTERN_BASE = 0x1f800
V9958_CURSOR_PATTERN_INDEX = 0x3f
V9958_CURSOR_HIDE_Y	= 0xd8
V9958_CURSOR_COLOR	= 0x0b

FONT_BYTES		= 2048
PRINT_RUN_SIZE		= 64
ATLAS_ROW_BYTES		= V9958_ATLAS_COLS * 3

; Terminal parser states (for ANSI/VT-100 output processing).
TERM_STATE_NORMAL	= 0x00
TERM_STATE_ESC		= 0x01
TERM_STATE_CSI		= 0x02
TERM_STATE_ESC_HASH	= 0x03
TERM_STATE_CHARSET	= 0x04

; Legacy raw-readiness recognizer constants retained only for dead compatibility
; code below; startup now uses packetized PROXY_READY in vdrip_transport.
VDRIP_READY_WAIT_ESC	= 0x00
VDRIP_READY_WAIT_LBRACKET = 0x01
VDRIP_READY_WAIT_QMARK	= 0x02
VDRIP_READY_WAIT_1	= 0x03
VDRIP_READY_WAIT_SEMI	= 0x04
VDRIP_READY_WAIT_MODE	= 0x05
VDRIP_READY_WAIT_C	= 0x06

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
CSI_IL			= 'L	; insert line(s)
CSI_DL			= 'M	; delete line(s)

; ANSI maximum parameter count.
CSI_MAX_PARAMS		= 2

; Max payload for a single framed packet (used by VIDEO_SEND validation).
VDRIP_PACKET_PAYLOAD_MAX = 0x10

; Max payload per PACKET_VDP_DATA_BLOCK chunk for bulk VDP writes.
; 240 bytes ≈ 3 rows of 80-column text; proxy accepts up to 252.
VDRIP_DATA_BLOCK_MAX = 240

; Console input queue (CONIN FIFO, interrupt-fed).
TEXTQ_SIZE		= 0x80
TEXTQ_MASK		= TEXTQ_SIZE - 1
; Leave substantial in-flight headroom after releasing RTS so multi-byte keys
; such as ESC [ A/B are less likely to be split by byte-level FIFO overflow.
TEXTQ_RTS_HIGH_WATER	= 0x20
TEXTQ_RTS_LOW_WATER	= 0x10

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
;   SIO_CH_CONSOLE, enables SIO RX interrupts, waits for packetized PROXY_READY,
;   initializes the remote V9958 G6 state, and enters interactive mode.
;
; Inputs:
;   None. vdrip_console_cold_init selects RESET/READY cold initialization;
;   vdrip_console_init selects the existing warm initialization path.
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
;   Cold init emits RESET before waiting. Both paths emit VDP register/font/
;   clear packets, cursor commands, and a FRAME_MARK after the proxy is ready.
; sio_rx_kick:
;   Not used directly here. The common transport sink receives packetized
;   readiness through the normal SIO RX path.
;
; Startup sequence:
;   1. Release RTS, init RX, register sink, enable interrupts.
;   2. Cold boot sends RESET; warm boot leaves the proxy untouched.
;   3. Assert RTS and wait for packetized PROXY_READY when not already online.
;   4. Once ready, release RTS and send VDP init/font/cursor traffic.
;   5. Assert RTS and enter normal interactive mode.
;
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------

vdrip_console_cold_init:
	ld a,#0x01
	jr vdrip_console_init_mode

vdrip_console_init:
	xor a
vdrip_console_init_mode:
	push af
	; Release RTS — we are not ready yet.
	call vdrip_rts_release_raw

	; Initialize queue state and the shared transport.
	call vdrip_rx_init
	; USB keyboard queue.  Cold boot leaves its RAM undefined and CONST may be
	; called before anything else, so this must happen here.
	call hid_input_init
	ld hl,#textq_put_ascii
	call vdrip_transport_set_raw_callback
	xor a				; proxy keyboard path sends raw terminal bytes
	call vdrip_transport_set_idle_mode
	call vdrip_transport_register_sink
	call sio_core_enable_interrupts

	; Assert RTS so the proxy can send.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	; A cold boot resets an already-running proxy before waiting. If no proxy is
	; connected, the RESET is lost and the newly launched proxy's startup READY
	; satisfies the same wait. Warm boot leaves the running proxy untouched.
	pop af
	or a
	jr z,vdrip_console_wait_ready
	xor a
	ld (vdrip_proxy_online),a
	ld a,#PACKET_RESET
	call vdrip_send_packet0
vdrip_console_wait_ready:
	call vdrip_transport_wait_ready
	ld a,#0x01
	ld (term_auto_wrap),a		; auto-wrap enabled at init

	; Release RTS and begin VDP initialization.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	call v9958_init_g6
	call v9958_init_palette
	call v9958_upload_font_atlas
	call v9958_configure_accelerator
	call v9958_clear_screen

	; Cursor starts at row 0, col 0. It is a steady mode-2 sprite.
	xor a
	ld (current_attr),a
	ld (text_attr_saved),a
	ld (text_col),a
	ld (text_row),a
	ld (print_run_count),a
	ld a,#0x01
	ld (cursor_visible),a
	call v9958_cursor_init
	call v9958_present

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
;   HL is preserved by this routine, and the console facade preserves DE/HL
;   around backend dispatch. BC is NOT preserved: the status flush / reconnect /
;   rx-kick helpers use it, and the facade (which has no free ROM bytes to save
;   it) does not. This matches the CP/M convention that CONST may clobber
;   registers other than its A result, so callers must not keep a live value in
;   BC across a CONST call.
; Clobbers:
;   AF, BC.
; Blocking behavior:
;   Does not block.
; VDrip traffic:
;   Emits no traffic.
; sio_rx_kick:
;   Does not call sio_rx_kick. Safe for hot BDOS/CCP/BBC BASIC CONST loops.
; ---------------------------------------------------------------------------

vdrip_console_const:
	push hl

	; Publish pending output before input polling. Programs such as TP3 poll
	; CONST between echoed characters without necessarily entering CONIN, so a
	; flush without OP_PRESENT would leave each character invisible until the
	; next keypress. Idle CONST polling emits no traffic.
	ld a,(print_run_count)
	or a
	jr z,vdrip_console_const_output_done
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call v9958_present
vdrip_console_const_output_done:

	; Check for proxy reconnection: sequence count > 1.
	ld a,(vdrip_ready_seq_count)
	cp #0x02
	call nc,vdrip_handle_reconnect

	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr nz,vdrip_console_const_ready

	; USB keyboard.  hid_input_status rate-limits itself, so this is safe on
	; the BDOS output path -- OUTCHAR calls CONST once per character printed,
	; and an unconditional IOCALL here would add ~0.6 ms to every one of them.
	call hid_input_status
	or a
	jr z,vdrip_console_const_empty

vdrip_console_const_ready:
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

	; Commit the completed output burst before blocking for input. Printable
	; runs deliberately defer cursor traffic, so publish the final SAT
	; coordinates and present the completed frame here.
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call v9958_present

	; Consume buffered input before permitting the proxy to transmit more. If the
	; queue is empty, ensure a prior storage transaction or flow-control release
	; cannot leave RTS deasserted and deadlock the keyboard.
	ld a,(textq_count)
	or a
	jr nz,vdrip_console_conin_have_char

	; RTS is asserted before consulting the USB queue, not after: returning a
	; USB byte while RTS is still deasserted from a prior storage transaction
	; would leave the proxy keyboard blocked indefinitely.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	call hid_input_status
	or a
	jr nz,vdrip_console_conin_usb

vdrip_console_conin_wait:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr nz,vdrip_console_conin_have_char
	; The blocking spin is where the adaptive backoff earns its keep: it runs
	; thousands of times a second, so a keystroke lands in well under a
	; millisecond even at the maximum interval.
	call hid_input_status
	or a
	jr z,vdrip_console_conin_wait

vdrip_console_conin_usb:
	call hid_input_get
	pop hl
	pop de
	pop bc
	ret

vdrip_console_conin_have_char:
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
; Terminal readiness handshake
; ===========================================================================
;
; ===========================================================================
; SIO RX integration
; ===========================================================================

vdrip_rx_init:
		xor a
	ld (vdrip_rx_rts_released),a
	ld (textq_head),a
	ld (textq_tail),a
	ld (textq_count),a
	ld (vdrip_ready_seq_count),a
	ld (esc_press_count),a
	ld (term_state),a
	ld (print_run_count),a

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


; Legacy local RX sink retained only as dead reference documentation. The
; shared transport sink is the registered owner.
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
;   Inactive legacy raw-readiness path retained for a later console-cleanup
;   phase. The shared vdrip_rx_sink is the registered owner.
vdrip_console_legacy_rx_sink:
	push af
	push bc
	push de
	push hl

	cp #SIO_CH_CONSOLE
	jr nz,vdrip_console_legacy_rx_done

	; Legacy raw-readiness behavior retained inactive.
	ld a,(vdrip_terminal_ready_flag)
	or a
	jr z,vdrip_rx_sink_wait_ready

	ld a,c
	call textq_put_ascii
	jr vdrip_console_legacy_rx_done

vdrip_rx_sink_wait_ready:
	ld a,c
	call vdrip_terminal_ready_parse_byte

vdrip_console_legacy_rx_done:
	pop hl
	pop de
	pop bc
	pop af
	ret


; ---------------------------------------------------------------------------
; vdrip_terminal_ready_parse_byte
;
; Inactive legacy recognizer for raw VT100-style readiness:
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
vdrip_rts_assert_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_ON
	out (VDRIP_CTRL),a
	xor a
	ret


vdrip_rts_release_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (VDRIP_CTRL),a
	xor a
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
;   VT  = treated as LF
;   FF  = clear screen and home cursor (used by CCP control-L)
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
;   ESC [ n L          insert n blank lines (IL); default n=1; full-screen region
;   ESC [ n M          delete n lines (DL); default n=1; full-screen region
;   ESC [ m / 0 m      reset SGR attributes (no visual effect)
;   ESC [ 1/4/5 m      bold/underline/blink consumed, no visual effect
;   ESC [ 7/27 m       reverse on/off tracked, not rendered
;   ESC [ 22/24/25 m   style-off params consumed, no visual effect
;   ESC [ 30-37/40-47 m  colors consumed, no visual effect
;   ESC [ c / 0 c      device attributes consumed; response deferred
;   ESC [ 5 n / 6 n    device status consumed; response deferred
;   ESC [ ? 7 h        DECAWM auto-wrap on  (default: enabled; immediate wrap)
;   ESC [ ? 7 l        DECAWM auto-wrap off (clamps/overwrites last column)
;   ESC [ ? 25 h       show cursor (DEC private)
;   ESC [ ? 25 l       hide cursor
;   ESC [ ? 1/3/6 h/l  DEC private modes consumed safely
;
; Unsupported CSI / DEC private sequences are consumed safely.
; CSI parser supports '?' prefix for DEC private sequences.
; IL/DL (insert/delete line) use the full screen as the scroll region; per-command
; scroll regions are not yet implemented.
; Scroll regions, insert/delete character, tab clearing, origin mode, 132-column
; mode, and DEC special graphics rendering are deferred and are consumed where
; their ESC/CSI forms are recognized.
; ANSI coordinates are 1-based; internal coordinates are 0-based.
; Tab stops are 8 columns (VT100 standard).
; Reverse video is rendered. Bold, underline, blink, and color-selection
; extensions remain consumed without adding a larger ANSI implementation.
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
	jp z,text_clear_screen_runtime

	cp #0x20
	jp nc,text_put_printable
	call v9958_flush_print_run
	ret


; ---------------------------------------------------------------------------
; ESC state
; ---------------------------------------------------------------------------

term_enter_esc:
	call v9958_flush_print_run
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
	; ESC O x — SS3, the application keypad / function-key introducer.  It is
	; an input sequence, so nothing here acts on it, but it must still be
	; consumed as two bytes: without this the 'O' falls through unmatched and
	; the final byte reaches the parser in NORMAL state and prints as text.
	; F1 typed a literal 'P'.
	cp #'O
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

	jp ansi_store_param

term_csi_final:
	; Final command byte — store any pending param, then dispatch.
	push af		; save command byte across ansi_store_param
	call ansi_store_param

	; Reset state and triple-Esc counter.
	xor a
	ld (term_state),a
	ld (esc_press_count),a

	pop af

	jp ansi_dispatch_csi


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
	cp #CSI_IL
	jp z,ansi_insert_lines
	cp #CSI_DL
	jp z,ansi_delete_lines
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
	jp text_clear_from_cursor_to_eos

ansi_ed_from_start:
	jp text_clear_from_start_to_cursor


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
	jp text_clear_line

ansi_el_to_eol:
	jp text_clear_to_eol

ansi_el_from_start:
	jp text_clear_from_sol_to_cursor


; ---- CSI ECH: erase n characters from cursor to the right ----

ansi_ech:
	call ansi_param0_default_1
	ld e,a
	ld a,(text_col)
	ld d,a
	ld a,#TEXT_LOG_COLUMNS
	sub d
	ret z
	cp e
	jr nc,ansi_ech_count_ok
	ld e,a
ansi_ech_count_ok:
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_CELL_FILL
	inc hl
	ld a,(text_col)
	ld (hl),a
	inc hl
	ld a,(text_row)
	ld (hl),a
	inc hl
	ld (hl),e
	inc hl
	ld (hl),#0x01
	inc hl
	ld (hl),#0x20
	ld b,#0x06
	jp v9958_send_command


; ---- CSI SGR: select graphic rendition ----

ansi_sgr:
	call v9958_flush_print_run
	; Consume SGR.  Track reverse video in current_attr.
	; 0=reset, 7=reverse on, 27=reverse off. Other font/color
	; parameters are consumed unless they affect the currently supported state.
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
	cp #7
	jr z,ansi_decawm_on
	cp #25
	jr z,ansi_show_cursor
	ret		; other DEC private — consume

ansi_show_cursor:
	jp vdrip_cursor_show

ansi_decrst:
	ld a,(csi_param_count)
	or a
	ret z
	ld a,(csi_param0)
	cp #7
	jr z,ansi_decawm_off
	cp #25
	jr z,ansi_hide_cursor
	ret		; other DEC private — consume

ansi_hide_cursor:
	jp vdrip_cursor_hide

; ---- DECAWM auto-wrap mode (ESC [ ? 7 h/l) ----

ansi_decawm_on:
	ld a,#0x01
	jr ansi_decawm_set
ansi_decawm_off:
	xor a
ansi_decawm_set:
	ld (term_auto_wrap),a
	ret


; ---- CSI IL: insert n blank lines (ESC [ n L) ----
;
; Inputs:
;   CSI param0 = n (default/0 -> 1)
;   text_row = current cursor row
; Outputs:
;   Shadow buffer and VDP updated; n blank lines inserted at cursor row.
; Clobbers:
;   AF, BC, DE, HL.
; Preserved registers:
;   none (caller saves BC/DE/HL around CONOUT dispatch)
; VDrip traffic:
;   Releases RTS, emits PACKET_VDP_DATA_BLOCK packets, emits FRAME_MARK.
; Cursor position:
;   Unchanged.
; Scroll region:
;   Full screen (rows 0..TEXT_ROWS-1); no per-command scroll region yet.

ansi_insert_lines:
	call ansi_param0_default_1
	ld e,a
	ld a,#TEXT_ROWS
	ld d,a
	ld a,(text_row)
	ld c,a
	ld a,d
	sub c
	cp e
	jr nc,ansi_il_v9958_count_ok
	ld e,a
ansi_il_v9958_count_ok:
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_INSERT_LINES
	inc hl
	ld a,(text_row)
	ld (hl),a
	inc hl
	ld (hl),e
	inc hl
	ld (hl),#TEXT_SCROLL_TOP
	inc hl
	ld (hl),#TEXT_SCROLL_BOTTOM
	ld b,#0x05
	jp v9958_send_command

ansi_delete_lines:
	call ansi_param0_default_1
	ld e,a
	ld a,#TEXT_ROWS
	ld d,a
	ld a,(text_row)
	ld c,a
	ld a,d
	sub c
	cp e
	jr nc,ansi_dl_v9958_count_ok
	ld e,a
ansi_dl_v9958_count_ok:
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_DELETE_LINES
	inc hl
	ld a,(text_row)
	ld (hl),a
	inc hl
	ld (hl),e
	inc hl
	ld (hl),#TEXT_SCROLL_TOP
	inc hl
	ld (hl),#TEXT_SCROLL_BOTTOM
	ld b,#0x05
	jp v9958_send_command



; ===========================================================================
; Terminal action helpers
; ===========================================================================

text_put_printable:
	; Input: A = printable CP850 byte. Accumulate same-row text into one
	; OP_TEXT_RUN instead of framing one packet per character.
	call v9958_append_printable
	ld a,(text_col)
	cp #(TEXT_LOG_COLUMNS - 1)
	jr nz,text_put_printable_advance
	call v9958_flush_print_run
	call text_advance_cursor
	call v9958_cursor_write_sat
	jp v9958_present
text_put_printable_advance:
	call text_advance_cursor
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
	call v9958_clear_screen
	xor a
	ld (text_col),a
	ld (text_row),a
	jp vdrip_cursor_set_position_current

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
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_ERASE_EOL
	inc hl
	ld a,(text_col)
	ld (hl),a
	inc hl
	ld a,(text_row)
	ld (hl),a
	ld b,#0x03
	jp v9958_send_command



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
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_CELL_FILL
	inc hl
	xor a
	ld (hl),a
	inc hl
	ld a,(text_row)
	ld (hl),a
	inc hl
	ld a,(text_col)
	inc a
	ld (hl),a
	inc hl
	ld (hl),#0x01
	inc hl
	ld (hl),#0x20
	ld b,#0x06
	jp v9958_send_command

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

	; If the input queue is getting full, stop host input.
	cp #TEXTQ_RTS_HIGH_WATER
	ret c

	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret

textq_full:
	; Foreground input consumption cannot keep up. Stop host input.
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

	ld a,(term_auto_wrap)
	or a
	ld a,#TEXT_LOG_COLUMNS
	jr nz,text_advance_do_wrap
	dec a
	jr text_advance_store_col

text_advance_do_wrap:
	xor a
	ld (text_col),a
	jr text_newline_from_wrap


text_newline:
	call v9958_flush_print_run
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


text_ensure_cursor_visible:
	ret

text_scroll_up:
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_SCROLL_UP
	inc hl
	ld (hl),#0x01
	ld b,#0x02
	call v9958_send_command
	xor a
	ld (text_col),a
	ld a,#TEXT_SCROLL_BOTTOM
	ld (text_row),a
	jp vdrip_cursor_set_position_current



; ===========================================================================
; Proxy reconnection handler
; ===========================================================================
;
; Inactive Phase 0 legacy reconnect helper. Packetized cold-start readiness is
; owned by vdrip_transport; idle proxy restart recovery requires reboot.
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

	call v9958_init_g6
	call v9958_init_palette
	call v9958_upload_font_atlas
	call v9958_configure_accelerator
	call v9958_clear_screen
	call v9958_cursor_init
	call v9958_present

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
	ld (term_auto_wrap),a		; auto-wrap re-enabled on RIS

	call v9958_init_g6
	call v9958_init_palette
	call v9958_upload_font_atlas
	call v9958_configure_accelerator
	call v9958_clear_screen

	xor a
	ld (text_col),a
	ld (text_row),a
	ld (print_run_count),a
	ld a,#0x01
	ld (cursor_visible),a
	call v9958_cursor_init
	call v9958_present

	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


; ===========================================================================
; V9958 G6 command backend
; ===========================================================================

v9958_send_command:
	ld a,#PACKET_COMMAND_STREAM
	ld hl,#command_buffer
	jp vdrip_send_packet

v9958_init_g6:
	ld hl,#command_buffer
	ld (hl),#OP_REG_BLOCK
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x0c
	inc hl
	ld (hl),#0x0a		; R0: M5+M3 = GRAPHIC 6
	inc hl
	ld (hl),#0x40		; R1: display on, 8x8 sprites
	inc hl
	ld (hl),#0x00		; R2: bitmap page 0
	inc hl
	ld (hl),#0x00		; R3
	inc hl
	ld (hl),#0x00		; R4
	inc hl
	ld (hl),#0xe4		; R5/R11 -> SAT 1F200h
	inc hl
	ld (hl),#0x3f		; R6 -> sprite patterns 1F800h
	inc hl
	ld (hl),#0x04		; R7: blue border
	inc hl
	ld (hl),#0x00		; R8
	inc hl
	ld (hl),#0x88		; R9: 212 lines + interlace = 424
	inc hl
	ld (hl),#0x00		; R10
	inc hl
	ld (hl),#0x03		; R11
	ld b,#0x0f
	jp v9958_send_command

; Restore the console palette after an application has taken over the V9958.
; R#16 selects palette entry zero; palette writes then auto-increment.
v9958_init_palette:
	xor a
	call vdrip_ctrl_write
	ld a,#0x90			; select R#16
	call vdrip_ctrl_write
	ld hl,#v9958_console_palette
	ld b,#0x20
v9958_init_palette_loop:
	ld a,(hl)
	inc hl
	call vdrip_palette_write
	djnz v9958_init_palette_loop
	ret

v9958_configure_accelerator:
	ld hl,#command_buffer
	ld (hl),#OP_SET_SCREEN_BASE
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0xd4
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#OP_SET_GLYPH_BASE
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x01
	inc hl
	ld (hl),#OP_SET_ATLAS_CONFIG
	inc hl
	ld (hl),#V9958_ATLAS_COLS
	inc hl
	ld (hl),#OP_SET_DISP_OFFSET
	inc hl
	ld (hl),#TEXT_DISPLAY_OFFSET
	inc hl
	ld (hl),#OP_SET_ATTR
	inc hl
	ld (hl),#0x0f
	inc hl
	ld (hl),#0x04
	inc hl
	ld (hl),#0x00
	ld b,#0x10
	jp v9958_send_command

v9958_present:
	ld hl,#command_buffer
	ld (hl),#OP_PRESENT
	ld b,#0x01
	jp v9958_send_command

v9958_clear_screen:
	call v9958_flush_print_run
	ld hl,#command_buffer
	ld (hl),#OP_CLEAR_SCREEN
	ld b,#0x01
	call v9958_send_command
	jp v9958_present

; Convert font_cp850_6x8.inc into a 32-column packed G6 mask atlas.
v9958_upload_font_atlas:
	xor a
	ld (atlas_scanline),a
v9958_atlas_scanline_loop:
	ld hl,#command_buffer
	ld (hl),#OP_VRAM_ADDR_WRITE
	inc hl
	ld (hl),#0x00
	inc hl
	ld a,(atlas_scanline)
	ld (hl),a
	inc hl
	ld (hl),#0x01
	inc hl
	ld (hl),#ATLAS_ROW_BYTES
	inc hl
	ld (atlas_dest),hl
	ld a,(atlas_scanline)
	ld c,a
	and #0x07
	ld l,a
	ld a,c
	srl a
	srl a
	srl a
	add a,#0x80
	ld h,a
	ld b,#V9958_ATLAS_COLS
v9958_atlas_glyph_loop:
	ld a,(hl)
	push hl
	call v9958_expand_font_row
	pop hl
	ld de,#0x0008
	add hl,de
	djnz v9958_atlas_glyph_loop
	ld b,#(5 + ATLAS_ROW_BYTES)
	call v9958_send_command
	ld a,(atlas_scanline)
	inc a
	ld (atlas_scanline),a
	cp #(V9958_ATLAS_ROWS * 8)
	jr nz,v9958_atlas_scanline_loop
	ret

v9958_expand_font_row:
	ld c,a
	ld hl,(atlas_dest)
	ld a,c
	rrca
	rrca
	rrca
	rrca
	rrca
	rrca
	and #0x03
	call v9958_pair_to_mask
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	rrca
	rrca
	and #0x03
	call v9958_pair_to_mask
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	and #0x03
	call v9958_pair_to_mask
	ld (hl),a
	inc hl
	ld (atlas_dest),hl
	ret

v9958_pair_to_mask:
	push de
	push hl
	ld e,a
	ld d,#0x00
	ld hl,#v9958_pair_mask_table
	add hl,de
	ld a,(hl)

	pop hl
	pop de
	ret

v9958_pair_mask_table:
	.db 0x00,0x0f,0xf0,0xff

v9958_append_printable:
	ld c,a
	ld a,(print_run_count)
	cp #PRINT_RUN_SIZE
	jr nz,v9958_append_have_space
	push bc				; preserve the pending character in C
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call v9958_present
	pop bc
v9958_append_have_space:
	ld a,(print_run_count)
	or a
	jr nz,v9958_append_have_start
	ld a,(text_col)
	ld (print_run_col),a
	ld a,(text_row)
	ld (print_run_row),a
v9958_append_have_start:
	ld hl,#print_run_buffer
	ld a,(print_run_count)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c
	ld a,(print_run_count)
	inc a
	ld (print_run_count),a
	ret

v9958_flush_print_run:
	ld a,(print_run_count)
	or a
	ret z
	ld c,a
	ld hl,#command_buffer
	ld (hl),#OP_TEXT_RUN
	inc hl
	ld (hl),#0x01
	inc hl
	ld a,(print_run_col)
	ld (hl),a
	inc hl
	ld a,(print_run_row)
	ld (hl),a
	inc hl
	ld (hl),#0x0f
	inc hl
	ld (hl),#0x04
	inc hl
	ld a,(current_attr)
	and #0x01
	ld (hl),a
	inc hl
	ld (hl),c
	inc hl
	ex de,hl
	ld hl,#print_run_buffer
	ld b,#0x00
	ldir
	ld a,(print_run_count)
	add a,#0x08
	ld b,a
	call v9958_send_command
	xor a
	ld (print_run_count),a
	ret

; Input DE=low 16 address, C=A16, B=count, HL=source.
; IX is saved and restored here: this is the only IX user in the BIOS, and the
; CONOUT render path that reaches this routine must not clobber a caller's IX.
v9958_write_vram_small:
	push bc
	push de
	push hl
	push ix
	ld ix,#command_buffer
	ld 0(ix),#OP_VRAM_ADDR_WRITE
	ld 1(ix),e
	ld 2(ix),d
	ld 3(ix),c
	ld 4(ix),b
	ld de,#(command_buffer + 5)
	ld c,b
	ld b,#0x00
	ldir
	pop ix
	pop hl
	pop de
	pop bc
	ld a,b
	add a,#0x05
	ld b,a
	jp v9958_send_command

v9958_cursor_init:
	ld hl,#cursor_pattern
	ld de,#0xf800
	ld c,#0x01
	ld b,#0x08
	call v9958_write_vram_small
	ld hl,#cursor_colors
	ld de,#0xf000
	ld c,#0x01
	ld b,#0x10
	call v9958_write_vram_small
	jp v9958_cursor_write_sat

v9958_cursor_write_sat:
	ld hl,#cursor_sat
	ld a,(cursor_visible)
	or a
	jr z,v9958_cursor_hidden
	ld a,(text_row)
	add a,a
	add a,a
	add a,a
	add a,#(TEXT_DISPLAY_OFFSET - 1)
	jr v9958_cursor_store_y
v9958_cursor_hidden:
	ld a,#V9958_CURSOR_HIDE_Y
v9958_cursor_store_y:
	ld (hl),a
	inc hl
	ld a,(text_col)
	ld e,a
	add a,a
	add a,e
	ld (hl),a
	inc hl
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),#V9958_CURSOR_HIDE_Y
	inc hl
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ld hl,#cursor_sat
	ld de,#0xf200
	ld c,#0x01
	ld b,#0x08
	jp v9958_write_vram_small



; ---------------------------------------------------------------------------
; restore_font_from_rom
;
; Called from wboot_resident (cbios_boot.asm) before console_init to refresh
; the font data at VDRIP_FONT_ROM_BASE (0x8000) in SRAM bank 0 from ROM.
; Transient programs may have overwritten the TPA area containing the font.
;
; Uses COPY_LATCH0 (= SHADOW_BIT): reads come from ROM bank 0 low area,
; writes go to SRAM bank 0. This is the same technique used by the shadow
; copy and restore_ccp_from_rom for their respective ROM regions.
;
; Inputs:  None.
; Outputs: SRAM bank 0 [VDRIP_FONT_ROM_BASE .. +FONT_BYTES-1] refreshed.
; Clobbers: AF, BC, DE, HL.
; Interrupts: Safe to call with interrupts disabled (wboot context); matches
;   the convention of restore_ccp_from_rom which is called without di/ei.
; VDrip traffic: None.
; ---------------------------------------------------------------------------

restore_font_from_rom:
	ld a,#COPY_LATCH0		; ROM bank 0 low area visible, writes to SRAM
	out (BANK_PORT),a
	ld hl,#VDRIP_FONT_ROM_BASE	; ROM bank 0 source (0x8000)
	ld de,#VDRIP_FONT_ROM_BASE	; SRAM bank 0 destination (0x8000)
	ld bc,#FONT_BYTES
	ldir
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a
	ret


; ---------------------------------------------------------------------------
; Clear 80x24 text screen to ASCII space — clears both VDP and shadow buffer.
; ---------------------------------------------------------------------------


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


vdrip_palette_write:
	push bc
	push de
	push hl

	ld e,a
	ld a,#PACKET_VDP_PALETTE_WRITE
	call vdrip_send_packet1

	pop hl
	pop de
	pop bc
	ret


vdrip_send_frame_mark:
	ld a,#PACKET_FRAME_MARK
	jp vdrip_send_packet0


; ===========================================================================
; BIOS-owned V9958 sprite cursor helpers
; ===========================================================================

vdrip_cursor_init:
	jp v9958_cursor_init


vdrip_cursor_enable:
	ret


vdrip_cursor_show:
	call v9958_flush_print_run
	ld a,#0x01
	ld (cursor_visible),a
	jp v9958_cursor_write_sat


vdrip_cursor_hide:
	call v9958_flush_print_run
	xor a
	ld (cursor_visible),a
	jp v9958_cursor_write_sat


vdrip_cursor_set_position_current:
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	jp v9958_present


vdrip_cursor_set_style_underline:
	ret


vdrip_cursor_set_blink_default:
	ret


vdrip_cursor_set_color_yellow:
	ret


; ===========================================================================
; Data / buffers / font include
; ===========================================================================
;
; Variables are grouped by subsystem without reordering code or changing storage.
; These live in the driver slot area with the code and are part of the current
; memory layout.

packet_payload0:
	.ds 0x05

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

; Text cursor state.
; text_col/text_row are internal 0-based logical coordinates.
text_col:
	.db 0x00

text_row:
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

command_buffer:
	.ds 0x80

print_run_count:
	.db 0x00
print_run_col:
	.db 0x00
print_run_row:
	.db 0x00
print_run_buffer:
	.ds PRINT_RUN_SIZE

cursor_visible:
	.db 0x01
cursor_sat:
	.ds 0x08
cursor_pattern:
	.db 0xe0,0xe0,0xe0,0xe0,0xe0,0xe0,0xe0,0xe0
cursor_colors:
	.db V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR
	.db V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR
	.db V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR
	.db V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR,V9958_CURSOR_COLOR

; V9958 palette entries 0..15, encoded as RB then G.
; Console text uses index 0 for black, 4 for blue, and 15 for white.
v9958_console_palette:
	.db 0x00,0x00, 0x11,0x01, 0x00,0x06, 0x00,0x07
	.db 0x05,0x00, 0x07,0x03, 0x50,0x00, 0x06,0x06
	.db 0x70,0x00, 0x73,0x03, 0x70,0x07, 0x74,0x07
	.db 0x00,0x05, 0x67,0x00, 0x55,0x05, 0x77,0x07

atlas_scanline:
	.db 0x00
atlas_dest:
	.dw 0x0000

; ANSI output parser state.
; Applies only to CONOUT bytes. Keyboard input must not use this state machine.
term_state:
	.db TERM_STATE_NORMAL

; DECAWM auto-wrap mode.  1 = auto-wrap enabled (default), 0 = disabled.
; Printable character output at the right margin wraps when enabled,
; clamps/overwrites when disabled.  ESC [ ? 7 h/l set/clear this flag.
; Reset to enabled by vdrip_console_init and ESC c (vdrip_reset_display).
term_auto_wrap:
	.db 0x01

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

; IL/DL (insert/delete line) temporaries.
; Shared between ansi_insert_lines and ansi_delete_lines; not reentrant.
il_dl_n:
	.db 0x00
il_dl_row:
	.db 0x00
il_dl_shift:
	.db 0x00

; VDP address tracking — skip redundant address setup when writing
; sequential characters (auto-increment handles it).
vdp_addr_next:
	.dw 0x0000
vdp_addr_valid:
	.db 0x00

; Triple-Esc VDP reset counter.
esc_press_count:
	.db 0x00

; ---------------------------------------------------------------------------
; ccp_read_up_sequence — recognize the remainder of the CCP cursor-up key.
;
; The first ESC byte has already been consumed by BDOS RDBUFF. The keyboard
; transports deliver cursor-up as ESC [ A, so consume the remaining two bytes
; and return Z only for that exact sequence. This is called only for the CCP;
; normal BIOS CONIN continues to return raw terminal bytes.
; Recall is accepted only on an empty line (B=0): there is no prefix match or
; history cycling.
;
; Inputs: none.
; Outputs: A/B = saved history length and NZ for recall; A=0/Z otherwise.
;          BC is preserved when recall is rejected; C remains the line limit
;          when recall succeeds.
; Clobbers: AF, DE, HL. The caller preserves HL around this routine.
; May block for the two bytes completing an ESC sequence.
; VDrip traffic: none. Not ISR-safe.
; ---------------------------------------------------------------------------
ccp_read_up_sequence:
	ld d,c
	ld e,b
	call GETCHAR
	and #0x7f
	cp #'['
	jr nz,ccp_up_not_recalled
	call GETCHAR
	and #0x7f
	cp #'A'
	jr nz,ccp_up_not_recalled
	ld a,e
	or a
	jr nz,ccp_up_not_recalled
	ld a,(NBYTES)
	ld b,a
	ld c,d
	or a
	ret

ccp_up_not_recalled:
	ld b,e
	ld c,d
	xor a
	ret


VDRIP_CONSOLE_CODE_END:

; ---------------------------------------------------------------------------
; Font data — bank 0 TPA, VDRIP_FONT_ROM_BASE (0x8000).
;
; Placed in a separate absolute area so the driver CODE area ends cleanly at
; VDRIP_CONSOLE_CODE_END. The 256-glyph CP850 font lands in the bank 0
; firmware image at 0x8000. The boot shadow copy transfers it to SRAM bank 0.
; restore_font_from_rom refreshes it from ROM using COPY_LATCH0 at warm boot.
; Programs may overwrite this TPA address after init; the warm-boot restore
; always refreshes it before the G6 atlas upload is performed.
; ---------------------------------------------------------------------------

	.area FONT_DATA (ABS)
	.org VDRIP_FONT_ROM_BASE

	.include "font_cp850_6x8.inc"
