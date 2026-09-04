; Zephyr-80 direct LunchCrema V9958 GRAPHIC 6 console BIOS driver.
;
; This is independent of the retained Virtual Drip console. It owns the
; ANSI/VT100-light output parser and talks directly to the physical V9958 at
; ports A0h-A4h. Console input comes only from the IO Controller HID queue.
;
; Output path:
;     CP/M calls CONOUT
;     -> v9958_console_conout
;     -> ANSI/VT100-light parser
;     -> direct V9958 command/VRAM operations
;     -> G6 bitmap in physical V9958 VRAM
;
; Input and output are deliberately separate. HID terminal bytes must not be
; interpreted by the output parser. CONOUT never polls or consumes input.
;
; Driver dispatch table consumed by cbios_console.asm:
;   const, conin, conout, list, punch, reader, listst
;
; Public entry points:
;   v9958_console_init    — initialize VDP, font atlas, screen, cursor, and HID
;   v9958_console_const   — report IO Controller HID input availability
;   v9958_console_conin   — return one HID terminal byte (blocks if empty)
;   v9958_console_conout  — parse and render one CP/M output byte
;
; Startup sequence:
;   1. Disable the LunchCrema porch and software-pace bootstrap writes.
;   2. Set R#25 WTE=0/VDS=0, R#8 VR=1, then all other required state.
;   3. Set R#25 WTE=1/VDS=0, enable the LunchCrema porch, load the palette.
;   4. Upload normal/reverse CP850 atlases, clear G6, initialize the cursor.
;   5. Enable the display and enter normal HID-driven interactive operation.
;
; Does not contain:
;   - monitor .org, start:, or echo loop
;   - hardcoded BIOS helper addresses
;   - demo banners or dashboard redraws

	.module v9958_console

	.globl v9958_console_driver
	.globl v9958_console_cold_init,v9958_console_init,v9958_console_const
	.globl v9958_console_conin,v9958_console_conout
	.globl v9958_reset_display,v9958_data_write_block
	.globl hid_input_init,hid_input_status,hid_input_get
	.globl restore_font_from_rom
	.globl V9958_CONSOLE_CODE_START,V9958_CONSOLE_CODE_END
	.globl console_backend_driver,console_backend_cold_init,console_backend_init
	.globl console_backend_restore_font_from_rom,console_backend_send_frame
	.globl console_backend_data_write_block,console_backend_reset_display

; ===========================================================================
; Constants
; ===========================================================================

; V9958 GRAPHIC 6 console layout. The 512x212 source bitmap is woven into
; 512x424 output by R#9 IL+LN. The text bitmap uses all 256 command-coordinate
; lines of page zero as a circular surface selected by R#23. Both precolored
; glyph atlases and the sprite cursor remain in page one.
TEXT_LOG_COLUMNS	= 85
TEXT_ROWS		= 26
TEXT_SCROLL_TOP		= 0
TEXT_SCROLL_BOTTOM	= TEXT_ROWS - 1
TEXT_SCROLL_ROWS	= TEXT_ROWS
TEXT_CELL_WIDTH		= 6
TEXT_CELL_HEIGHT	= 8
TEXT_DISPLAY_OFFSET	= 4		; 208-line text area (26 rows) at source lines 4..211

G6_BITMAP_BASE		= 0x00000
G6_BITMAP_BYTES		= 256 * 256
V9958_ATLAS_NORMAL_BASE = 0x10000
V9958_ATLAS_REVERSE_BASE = 0x14000
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

; V9958 command-engine register block, R#32 through R#46.
VDP_CMD_SX_LO		= 0
VDP_CMD_SX_HI		= 1
VDP_CMD_SY_LO		= 2
VDP_CMD_SY_HI		= 3
VDP_CMD_DX_LO		= 4
VDP_CMD_DX_HI		= 5
VDP_CMD_DY_LO		= 6
VDP_CMD_DY_HI		= 7
VDP_CMD_NX_LO		= 8
VDP_CMD_NX_HI		= 9
VDP_CMD_NY_LO		= 10
VDP_CMD_NY_HI		= 11
VDP_CMD_COLOR		= 12
VDP_CMD_ARGUMENT	= 13
VDP_CMD_CODE		= 14
VDP_CMD_BYTES		= 15

V9958_COMMAND_HMMV	= 0xc0
V9958_COMMAND_HMMM	= 0xd0
V9958_ARGUMENT_DIY	= 0x08
V9958_STATUS2_CE	= 0x01
V9958_STATUS2_VR	= 0x40
V9958_BOOT_DELAY_COUNT	= 16

V9958_R1_DISPLAY_OFF	= 0x00
V9958_R1_DISPLAY_ON	= 0x40
V9958_R8_64K_DRAM	= 0x08
V9958_R25_WAIT_OFF	= 0x00
V9958_R25_WAIT_ON	= 0x04
V9958_R23_TEXT_BASE	= 0xfc		; four-line margin before row zero

; Historical VIDEO_SEND packet types accepted by the direct compatibility
; adapter. They name operations, but no Virtual Drip framing is generated.
VIDEO_TYPE_VDP_CTRL_WRITE = 0x01
VIDEO_TYPE_VDP_DATA_WRITE = 0x02
VIDEO_TYPE_VDP_DATA_BLOCK = 0x0b
VIDEO_TYPE_VDP_PALETTE_WRITE = 0x13
VIDEO_TYPE_VDP_INDIRECT_WRITE = 0x14
VIDEO_TYPE_RESET	= 0x06
VIDEO_TYPE_FRAME_MARK	= 0x08

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
CSI_IL			= 'L	; insert line(s)
CSI_DL			= 'M	; delete line(s)

; ANSI maximum parameter count.
CSI_MAX_PARAMS		= 2

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

V9958_CONSOLE_CODE_START:

console_backend_driver:
v9958_console_driver:
	.dw v9958_console_const
	.dw v9958_console_conin
	.dw v9958_console_conout
	.dw v9958_console_list
	.dw v9958_console_punch
	.dw v9958_console_reader
	.dw v9958_console_listst


; ===========================================================================
; Public direct-V9958 console driver entry points
; ===========================================================================

; ---------------------------------------------------------------------------
; v9958_console_init
;
; Purpose:
;   Initialize the physical LunchCrema V9958 backend selected by
;   cbios_console.asm. Clears driver-owned parser/display state, initializes
;   the IOC HID queue, establishes the V9958 G6 state, and enters interactive
;   mode without registering a Virtual Drip receive path.
;
; Inputs:
;   None. Cold init establishes the default configuration-latch shadow; warm
;   init preserves its owned D0 interrupt-route value.
; Outputs:
;   Physical V9958 display and IOC HID input queue initialized.
; Preserved registers:
;   None promised. Called during BOOT/WBOOT setup.
; Clobbers:
;   AF, BC, DE, HL.
; Blocking behavior:
;   Blocks during paced bootstrap writes, VRAM upload, and command completion.
; Virtual Drip traffic:
;   None.
;
; Startup sequence:
;   1. Initialize HID and terminal state.
;   2. Disable the porch; pace R#25, R#8, and the remaining registers.
;   3. Enable native WAIT, then the porch, then program the palette.
;   4. Upload both CP850 atlases, clear G6, initialize the sprite cursor.
;   5. Enable the display.
;
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------

console_backend_cold_init:
v9958_console_cold_init:
	; D0 uses the reset/default interrupt route. All subsequent latch writes
	; preserve this software-owned value while changing only /WS_EN on D1.
	xor a
	ld (v9958_config_shadow),a
	jr v9958_console_init_common

console_backend_init:
v9958_console_init:
v9958_console_init_common:
	call hid_input_init
	xor a
	ld (esc_press_count),a
	ld (term_state),a
	ld (print_run_count),a
	ld (current_attr),a
	ld (text_attr_saved),a
	ld (text_col),a
	ld (text_row),a
	ld a,#0x01
	ld (term_auto_wrap),a
	ld (cursor_visible),a

	; Keep the display off through initialization. These calls implement the
	; exact porch/WTE/VR ordering from the hardware bring-up notes.
	call v9958_init_g6
	call v9958_enable_hardware_wait
	call v9958_init_palette_paced
	call v9958_upload_font_atlas
	call v9958_clear_screen
	call v9958_cursor_init
	call v9958_present
	jp v9958_enable_display

; ---------------------------------------------------------------------------
; v9958_console_const
;
; Purpose:
;   CP/M CONST backend. Report whether the IOC HID queue has a byte available.
;
; Inputs:
;   None.
; Outputs:
;   A = CONST_HAS_CHAR (0xff) if the HID queue is nonempty, else 0x00.
; Preserved registers:
;   HL is preserved by this routine, and the console facade preserves DE/HL
;   around backend dispatch. BC is NOT preserved: display and HID helpers use
;   it, and the facade does not save it. This matches the CP/M convention that
;   CONST may clobber registers other than its A result, so callers must not
;   keep a live value in BC across a CONST call.
; Clobbers:
;   AF, BC.
; Blocking behavior:
;   HID polling is rate-limited; flushing pending VDP output may wait for CE.
; Virtual Drip traffic:
;   None.
; ---------------------------------------------------------------------------

v9958_console_const:
	push hl

	; Publish pending output before input polling. Programs such as TP3 poll
	; CONST between echoed characters without necessarily entering CONIN, so a
	; flush without OP_PRESENT would leave each character invisible until the
	; next keypress. Idle CONST polling emits no traffic.
	ld a,(print_run_count)
	or a
	jr z,v9958_console_const_output_done
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call v9958_present
v9958_console_const_output_done:

	; hid_input_status rate-limits itself, so this is safe on
	; the BDOS output path -- OUTCHAR calls CONST once per character printed,
	; and an unconditional IOCALL here would add ~0.6 ms to every one of them.
	call hid_input_status
	pop hl
	ret

; ---------------------------------------------------------------------------
; v9958_console_conin
;
; Purpose:
;   CP/M CONIN backend. Return one byte from the IOC HID terminal queue.
;
; Inputs:
;   None.
; Outputs:
;   A = oldest byte from the IOC HID terminal queue.
; Preserved registers:
;   BC, DE, HL.
; Clobbers:
;   AF.
; Blocking behavior:
;   Blocks until the IOC HID queue is nonempty. It does not interpret bytes.
; Virtual Drip traffic:
;   None.
;
; Queue semantics:
;   hid_input_get consumes exactly one terminal byte. Examples include Ctrl-X
;   = 18h, Enter = 0Dh, and arrow-up = 1Bh 5Bh 41h.
; ---------------------------------------------------------------------------

v9958_console_conin:
	push bc
	push de
	push hl

	; Commit the completed output burst before blocking for input. Printable
	; runs deliberately defer cursor traffic, so publish the final SAT
	; coordinates and present the completed frame here.
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call v9958_present

v9958_console_conin_wait:
	; The blocking spin is where the adaptive backoff earns its keep: it runs
	; thousands of times a second, so a keystroke lands in well under a
	; millisecond even at the maximum interval.
	call hid_input_status
	or a
	jr z,v9958_console_conin_wait
	call hid_input_get
	pop hl
	pop de
	pop bc
	ret

; ---------------------------------------------------------------------------
; v9958_console_conout
;
; Purpose:
;   CP/M CONOUT backend. Render one output byte through the output-only terminal
;   parser and direct V9958 hardware path.
;
; Output one byte to the physical V9958 text console.
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
;   May block while the V9958 command engine completes an earlier operation.
;
; Renders the byte on the VDP text display with ANSI/VT-100 light
; terminal emulation for cursor movement, backspace, tab, etc.
; CP/M handles line editing; the driver interprets control sequences
; for display.
;
; Does not read keyboard packets or call CONIN from CONOUT.
; ---------------------------------------------------------------------------

v9958_console_conout:
	push bc
	push de
	push hl

	ld a,c
	call term_process_byte
	pop hl
	pop de
	pop bc
	ret

; ---------------------------------------------------------------------------
; Auxiliary CP/M device stubs.
;
; v9958_console_list:
;   CP/M LIST backend. Input C is ignored. Returns immediately, emits no video
;   traffic, and does not poll HID.
;
; v9958_console_punch:
;   CP/M PUNCH backend. Input C is ignored. Returns immediately, emits no video
;   traffic, and does not poll HID.
;
; v9958_console_reader:
;   CP/M READER backend. Returns CONSOLE_EOF in A. Does not block, emits no
;   video traffic, and does not poll HID.
;
; v9958_console_listst:
;   CP/M LISTST backend. Returns CONSOLE_READY in A. Does not block, emits no
;   video traffic, and does not poll HID.
; ---------------------------------------------------------------------------

v9958_console_list:
	ret

v9958_console_punch:
	ret

v9958_console_reader:
	ld a,#CONSOLE_EOF
	ret

v9958_console_listst:
	ld a,#CONSOLE_READY
	ret


; ===========================================================================
; CONOUT terminal renderer — ANSI/VT-100 light
; ===========================================================================
;
; This parser applies to CP/M output only. It is reached from CONOUT and must
; not be used for keyboard input. HID bytes remain raw until CP/M reads them
; through CONIN.
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
	jp z,v9958_reset_display

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
	; ESC Z — DECID. Response is deferred; input mapping remains unchanged.
	cp #'Z
	ret z
	; ESC = / ESC > — keypad modes. Input mapping is unchanged; consume.
	cp #'=
	ret z
	cp #'>
	ret z
	; ESC c — RIS (reset terminal), already handled by triple-Esc.
	cp #'c
	jp z,v9958_reset_display
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
	call v9958_cursor_set_position_current
	ret

ansi_vpa:
	call ansi_param0_default_1	; A = row (1-based)
	dec a
	cp #TEXT_ROWS
	jr c,ansi_vpa_clamped
	ld a,#(TEXT_ROWS - 1)
ansi_vpa_clamped:
	ld (text_row),a
	call v9958_cursor_set_position_current
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
	call v9958_cursor_set_position_current
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
	ld b,e				; width in cells
	ld c,#0x01			; one row
	ld a,(text_col)
	ld d,a
	ld a,(text_row)
	ld e,a
	jp v9958_fill_cells


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
	call v9958_cursor_set_position_current
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
	jp v9958_cursor_show

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
	jp v9958_cursor_hide

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
; VDP traffic:
;   One overlap-safe HMMM command followed by an HMMV fill.
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
	ld a,e
	jp v9958_insert_lines

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
	ld a,e
	jp v9958_delete_lines



; ===========================================================================
; Terminal action helpers
; ===========================================================================

text_put_printable:
	; Input: A = printable CP850 byte. Accumulate same-row text into one
	; buffered run; the direct backend emits one HMMM per character on flush.
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
	call v9958_cursor_set_position_current
	ret

term_cr:
	; Carriage return — column 0, row unchanged.
	xor a
	ld (text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_lf:
	; Line feed — move down one row, preserving column.
	ld a,(text_col)
	push af
	call text_newline
	pop af
	ld (text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_nel:
	; Next line — CR + LF.
	xor a
	ld (text_col),a
	call text_newline
	call v9958_cursor_set_position_current
	ret

term_reverse_index:
	; Reverse index — move up one row. Region scroll-down is deferred.
	ld a,(text_row)
	or a
	ret z
	dec a
	ld (text_row),a
	call v9958_cursor_set_position_current
	ret

term_backspace:
	ld a,(text_col)
	or a
	ret z

	dec a
	ld (text_col),a

	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_tab:
	; Advance to next 8-column tab stop (VT100 standard).
	call text_advance_cursor
	ld a,(text_col)
	and #0x07
	jr nz,term_tab

	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_up:
	ld a,(text_row)
	or a
	ret z

	dec a
	ld (text_row),a
	call v9958_cursor_set_position_current
	ret

term_cursor_down:
	ld a,(text_row)
	cp #(TEXT_ROWS - 1)
	ret nc

	inc a
	ld (text_row),a
	call v9958_cursor_set_position_current
	ret

term_cursor_left:
	ld a,(text_col)
	or a
	ret z

	dec a
	ld (text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_right:
	ld a,(text_col)
	cp #(TEXT_LOG_COLUMNS - 1)
	ret nc

	inc a
	ld (text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_home:
	xor a
	ld (text_col),a
	ld (text_row),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_end:
	ld a,#(TEXT_LOG_COLUMNS - 1)
	ld (text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_screen_runtime — clear screen at runtime (for ESC [ 2 J)
;
; Clears the G6 bitmap and resets the cursor to 0,0.
; ---------------------------------------------------------------------------

text_clear_screen_runtime:
	call v9958_clear_screen
	xor a
	ld (text_col),a
	ld (text_row),a
	jp v9958_cursor_set_position_current

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
	call v9958_cursor_set_position_current
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
	call v9958_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_to_eol — clear from cursor to end of logical line (ESC [ K)
; ---------------------------------------------------------------------------

text_clear_to_eol:
	call v9958_flush_print_run
	ld a,(text_col)
	ld d,a
	ld b,#TEXT_LOG_COLUMNS
	sub b				; A = col - columns
	neg				; A = columns - col
	ld b,a
	ld a,(text_row)
	ld e,a
	ld c,#0x01
	jp v9958_fill_cells



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
	ld d,#0x00
	ld a,(text_row)
	ld e,a
	ld a,(text_col)
	inc a
	ld b,a
	ld c,#0x01
	jp v9958_fill_cells

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

text_ensure_cursor_visible:
	ret

text_scroll_up:
	call v9958_flush_print_run
	call v9958_scroll_up_one
	xor a
	ld (text_col),a
	ld a,#TEXT_SCROLL_BOTTOM
	ld (text_row),a
	jp v9958_cursor_set_position_current



; ===========================================================================
; VDP reset (triple-Esc)
; ===========================================================================
;
; Called when Esc is pressed three times rapidly.
; Re-initialises the VDP text mode, font, and virtual cursor.

console_backend_reset_display:
v9958_reset_display:
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

	ld a,#0x01
	ld (term_auto_wrap),a		; auto-wrap re-enabled on RIS

	call v9958_init_g6
	call v9958_enable_hardware_wait
	call v9958_init_palette_paced
	call v9958_upload_font_atlas
	call v9958_clear_screen

	xor a
	ld (text_col),a
	ld (text_row),a
	ld (print_run_count),a
	ld a,#0x01
	ld (cursor_visible),a
	call v9958_cursor_init
	call v9958_present
	jp v9958_enable_display


; ===========================================================================
; V9958 G6 command backend
; ===========================================================================

; ---------------------------------------------------------------------------
; LunchCrema bootstrap and direct V9958 access
; ---------------------------------------------------------------------------

; Delay after a bootstrap access while R#25.WTE is disabled. Preserves all
; caller-visible registers and does not rely on incidental instruction timing.
v9958_bootstrap_delay:
	push bc
	ld b,#V9958_BOOT_DELAY_COUNT
v9958_bootstrap_delay_loop:
	djnz v9958_bootstrap_delay_loop
	pop bc
	ret

; Input: A=value, B=register. Software paced; use only with the porch disabled.
; Clobbers: AF. May block for the fixed bootstrap delay.
v9958_write_register_paced:
	out (V9958_COMMAND_PORT),a
	call v9958_bootstrap_delay
	ld a,b
	or #0x80
	out (V9958_COMMAND_PORT),a
	call v9958_bootstrap_delay
	ret

; Input: A=value, B=register. Native WAIT and the LunchCrema porch must be on.
; Clobbers: AF. May block in the active VDP I/O cycle.
v9958_write_register:
	out (V9958_COMMAND_PORT),a
	ld a,b
	or #0x80
	out (V9958_COMMAND_PORT),a
	ret

; Input: HL=values, B=first register, C=count. Software paced.
v9958_write_register_block_paced:
	ld a,(hl)
	call v9958_write_register_paced
	inc hl
	inc b
	dec c
	jr nz,v9958_write_register_block_paced
	ret

; Change only /WS_EN (D1). D0 remains the selected interrupt route held in the
; software shadow because the LunchCrema latch captures both bits together.
v9958_porch_off:
	ld a,(v9958_config_shadow)
	and #V9958_CONFIG_INT_ROUTE
	or #V9958_CONFIG_PORCH_OFF
	ld (v9958_config_shadow),a
	out (V9958_CONFIG_PORT),a
	jp v9958_bootstrap_delay

v9958_porch_on:
	ld a,(v9958_config_shadow)
	and #V9958_CONFIG_INT_ROUTE
	ld (v9958_config_shadow),a
	out (V9958_CONFIG_PORT),a
	ret

; Establish the non-negotiable hardware state before any accelerated access.
; The display stays off until the bitmap, atlases, and cursor are initialized.
v9958_init_g6:
	call v9958_porch_off
	xor a
	ld (v9958_scroll_origin),a	; physical start of logical row zero

	ld a,#V9958_R25_WAIT_OFF	; WTE=0, VDS=0
	ld b,#25
	call v9958_write_register_paced

	ld a,#V9958_R8_64K_DRAM	; VR=1 for installed 64Kx4 DRAMs
	ld b,#8
	call v9958_write_register_paced

	; A warm boot may follow a transient program that left a VDP command active.
	; STOP it before reprogramming display state or uploading console VRAM.
	xor a
	ld b,#46
	call v9958_write_register_paced

	ld hl,#v9958_g6_registers
	ld b,#0
	ld c,#12
	call v9958_write_register_block_paced

	; Explicitly establish every selector/latch used by later helpers.
	xor a
	ld b,#14
	call v9958_write_register_paced
	ld a,#2				; command-engine status register
	ld b,#15
	call v9958_write_register_paced
	xor a
	ld b,#16
	call v9958_write_register_paced
	xor a
	ld b,#17
	call v9958_write_register_paced
	xor a
	ld b,#18
	call v9958_write_register_paced
	ld a,#V9958_R23_TEXT_BASE
	ld b,#23
	call v9958_write_register_paced
	; R#26/R#27 are V9958 horizontal-scroll state and survive warm boot.
	xor a
	ld b,#26
	call v9958_write_register_paced
	xor a
	ld b,#27
	jp v9958_write_register_paced

; Restore palette entries 0..15. Select every entry explicitly, matching the
; real-card MANDELV5 bring-up path instead of depending on palette
; auto-increment state.
;
; This runs *after* R#25.WTE=1 and the U11 porch are enabled, exactly as
; MANDELV5 does. MANDELV5 never bypasses the porch, so every palette byte it
; writes is held by a real hardware WAIT. Programming the palette in the
; bootstrap regime instead (WTE=0, porch bypassed, software pacing only)
; produced white text that displayed as yellow on the physical card: the
; software delay spaces successive accesses but does not widen the /CSW pulse
; or extend data-valid time, so palette bytes could be latched with the low
; (blue) bits corrupted. Software pacing is retained here because it is
; harmless during one-time initialization.
v9958_init_palette_paced:
	ld hl,#v9958_console_palette
	ld c,#0x00
	ld d,#0x10
v9958_init_palette_paced_loop:
	push de
	push hl
	ld a,c
	ld b,#16
	call v9958_write_register_paced
	pop hl
	pop de
	ld a,(hl)
	inc hl
	out (V9958_PALETTE_PORT),a
	call v9958_bootstrap_delay
	ld a,(hl)
	inc hl
	out (V9958_PALETTE_PORT),a
	call v9958_bootstrap_delay
	inc c
	dec d
	jr nz,v9958_init_palette_paced_loop
	ret

; Enable native WAIT first, then enable the U11 front porch. R#25.VDS remains
; clear so pin 8 continues to provide CPUCLK to the porch state machine.
v9958_enable_hardware_wait:
	ld a,#V9958_R25_WAIT_ON
	ld b,#25
	call v9958_write_register_paced
	jp v9958_porch_on

v9958_enable_display:
	ld a,#V9958_R1_DISPLAY_ON
	ld b,#1
	jp v9958_write_register

; Status register 2 remains selected while the console owns the VDP. CE=1 means
; a command is active. This routine may block; it is never called from an ISR.
v9958_wait_command:
	in a,(V9958_COMMAND_PORT)
	and #V9958_STATUS2_CE
	jr nz,v9958_wait_command
	ret

v9958_clear_command_buffer:
	ld hl,#command_buffer
	ld b,#VDP_CMD_BYTES
	xor a
v9958_clear_command_buffer_loop:
	ld (hl),a
	inc hl
	djnz v9958_clear_command_buffer_loop
	ret

; R#32..R#46 are written in order through the indirect port. R#46 is last and
; starts the command. A prior command is always allowed to finish first.
v9958_start_command:
	call v9958_wait_command
	ld a,#32
	ld b,#17
	call v9958_write_register
	ld hl,#command_buffer
	ld b,#VDP_CMD_BYTES
v9958_start_command_loop:
	ld a,(hl)
	inc hl
	out (V9958_INDIRECT_PORT),a
	djnz v9958_start_command_loop
	ret

; Direct drawing is ordered by command completion. Full-screen scrolling uses
; R#23 and therefore changes no bitmap data beyond the two newly exposed edges.
v9958_present:
	jp v9958_wait_command

; ---------------------------------------------------------------------------
; Direct font atlas and text rendering
; ---------------------------------------------------------------------------

; Convert the resident CP850 font into one 96-byte atlas scanline, then stream
; it directly to VRAM. The second pass swaps foreground/background so SGR
; reverse video remains a single HMMM glyph copy.
v9958_upload_font_atlas:
	xor a
	ld (atlas_reverse_flag),a
	call v9958_upload_font_atlas_pass
	ld a,#0x01
	ld (atlas_reverse_flag),a
	jp v9958_upload_font_atlas_pass

v9958_upload_font_atlas_pass:
	xor a
	ld (atlas_scanline),a
v9958_atlas_scanline_loop:
	ld hl,#command_buffer
	ld (atlas_dest),hl

	; font address = 8000h + (glyph_group * 100h) + glyph_scanline
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

	; normal atlas = 10000h; reverse atlas = 14000h. Each scanline is one
	; 256-byte G6 pitch apart and only the first 96 bytes contain glyph data.
	ld a,(atlas_scanline)
	ld d,a
	ld a,(atlas_reverse_flag)
	or a
	jr z,v9958_atlas_have_address
	ld a,d
	add a,#0x40
	ld d,a
v9958_atlas_have_address:
	ld e,#0x00
	ld c,#0x01
	ld b,#ATLAS_ROW_BYTES
	ld hl,#command_buffer
	call v9958_write_vram_small

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
	call v9958_pair_to_color
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	rrca
	rrca
	and #0x03
	call v9958_pair_to_color
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	and #0x03
	call v9958_pair_to_color
	ld (hl),a
	inc hl
	ld (atlas_dest),hl
	ret

v9958_pair_to_color:
	push de
	push hl
	ld e,a
	ld d,#0x00
	ld a,(atlas_reverse_flag)
	or a
	jr z,v9958_pair_table_selected
	ld a,e
	add a,#0x04
	ld e,a
v9958_pair_table_selected:
	ld hl,#v9958_pair_color_table
	add hl,de
	ld a,(hl)
	pop hl
	pop de
	ret

; Pair values 00, 01, 10, 11 for normal and reverse white/blue cells.
v9958_pair_color_table:
	.db 0x44,0x4f,0xf4,0xff
	.db 0xff,0xf4,0x4f,0x44

v9958_append_printable:
	ld c,a
	ld a,(print_run_count)
	cp #PRINT_RUN_SIZE
	jr nz,v9958_append_have_space
	push bc
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
	ld b,a
	ld hl,#print_run_buffer
	ld a,(print_run_col)
	ld d,a
	ld a,(print_run_row)
	ld e,a
v9958_flush_print_run_loop:
	ld a,(hl)
	push bc
	push de
	push hl
	call v9958_render_character
	pop hl
	pop de
	pop bc
	inc hl
	inc d
	djnz v9958_flush_print_run_loop
	xor a
	ld (print_run_count),a
	ret

; Input: A=CP850 character, D=column, E=row. Starts one HMMM command and
; returns; the next VDP operation waits for it.
v9958_render_character:
	ld (render_char),a
	ld a,d
	ld (render_col),a
	ld a,e
	ld (render_row),a
	call v9958_clear_command_buffer

	ld a,(render_char)
	and #0x1f
	call v9958_multiply_by_six
	ld a,l
	ld (command_buffer + VDP_CMD_SX_LO),a
	ld a,h
	ld (command_buffer + VDP_CMD_SX_HI),a

	ld a,(render_char)
	srl a
	srl a
	srl a
	srl a
	srl a
	add a,a
	add a,a
	add a,a
	ld c,a
	ld a,(current_attr)
	and #0x01
	jr z,v9958_render_normal_atlas
	ld a,c
	add a,#0x40
	ld c,a
v9958_render_normal_atlas:
	ld a,c
	ld (command_buffer + VDP_CMD_SY_LO),a
	ld a,#0x01
	ld (command_buffer + VDP_CMD_SY_HI),a

	ld a,(render_col)
	call v9958_multiply_by_six
	ld a,l
	ld (command_buffer + VDP_CMD_DX_LO),a
	ld a,h
	ld (command_buffer + VDP_CMD_DX_HI),a

	ld a,(render_row)
	call v9958_logical_row_to_vram_y
	ld (command_buffer + VDP_CMD_DY_LO),a

	ld a,#TEXT_CELL_WIDTH
	ld (command_buffer + VDP_CMD_NX_LO),a
	ld a,#TEXT_CELL_HEIGHT
	ld (command_buffer + VDP_CMD_NY_LO),a
	ld a,#V9958_COMMAND_HMMM
	ld (command_buffer + VDP_CMD_CODE),a
	jp v9958_start_command

; Input: D=column, E=row, B=width in cells, C=height in cells.
; Uses the current SGR background (blue normally, white in reverse).
v9958_fill_cells:
	ld a,d
	ld (fill_col),a
	ld a,e
	ld (fill_row),a
	ld a,b
	ld (fill_width),a
	ld a,c
	ld (fill_height),a
	call v9958_clear_command_buffer

	ld a,(fill_col)
	call v9958_multiply_by_six
	ld a,l
	ld (command_buffer + VDP_CMD_DX_LO),a
	ld a,h
	ld (command_buffer + VDP_CMD_DX_HI),a

	ld a,(fill_row)
	call v9958_logical_row_to_vram_y
	ld (command_buffer + VDP_CMD_DY_LO),a

	ld a,(fill_width)
	call v9958_multiply_by_six
	ld a,l
	ld (command_buffer + VDP_CMD_NX_LO),a
	ld a,h
	ld (command_buffer + VDP_CMD_NX_HI),a

	ld a,(current_attr)
	and #0x01
	ld a,#0x44
	jr z,v9958_fill_have_color
	ld a,#0xff
v9958_fill_have_color:
	ld (command_buffer + VDP_CMD_COLOR),a
	ld a,#V9958_COMMAND_HMMV
	ld (command_buffer + VDP_CMD_CODE),a

	; A multi-row erase may cross the circular page-zero boundary. Split it
	; there so the command engine does not continue into the font page.
	ld a,(fill_height)
	add a,a
	add a,a
	add a,a
	ld b,a
	ld (command_buffer + VDP_CMD_NY_LO),a
	ld a,(command_buffer + VDP_CMD_DY_LO)
	add a,b
	jr nc,v9958_fill_start
	ld (fill_height),a		; wrapped height after physical line 255
	ld a,(command_buffer + VDP_CMD_DY_LO)
	neg
	ld (command_buffer + VDP_CMD_NY_LO),a
	call v9958_start_command
	ld a,(fill_height)
	or a
	ret z
	xor a
	ld (command_buffer + VDP_CMD_DY_LO),a
	ld a,(fill_height)
	ld (command_buffer + VDP_CMD_NY_LO),a
v9958_fill_start:
	jp v9958_start_command

; Input: A=source logical row, D=destination row, B=row count, C=ARG.
; Each eight-line cell row is copied separately so page-zero wrap is safe.
; DIY selects bottom-to-top order for overlapping insert-line moves.
v9958_copy_rows:
	ld (copy_src_row),a
	ld a,d
	ld (copy_dst_row),a
	ld a,b
	or a
	ret z
	ld (copy_row_count),a
	ld a,c
	ld (copy_argument),a
	ld a,(copy_argument)
	and #V9958_ARGUMENT_DIY
	jr z,v9958_copy_rows_loop
	ld a,(copy_row_count)
	dec a
	ld b,a
	ld a,(copy_src_row)
	add a,b
	ld (copy_src_row),a
	ld a,(copy_dst_row)
	add a,b
	ld (copy_dst_row),a

v9958_copy_rows_loop:
	call v9958_clear_command_buffer
	ld a,(copy_src_row)
	call v9958_logical_row_to_vram_y
	ld (command_buffer + VDP_CMD_SY_LO),a
	ld a,(copy_dst_row)
	call v9958_logical_row_to_vram_y
	ld (command_buffer + VDP_CMD_DY_LO),a
	ld a,#0xfe			; 85 cells * 6 pixels = 510
	ld (command_buffer + VDP_CMD_NX_LO),a
	ld a,#0x01
	ld (command_buffer + VDP_CMD_NX_HI),a
	ld a,#TEXT_CELL_HEIGHT
	ld (command_buffer + VDP_CMD_NY_LO),a
	ld a,#V9958_COMMAND_HMMM
	ld (command_buffer + VDP_CMD_CODE),a
	call v9958_start_command

	ld a,(copy_argument)
	and #V9958_ARGUMENT_DIY
	ld a,(copy_src_row)
	jr z,v9958_copy_rows_advance
	dec a
	ld (copy_src_row),a
	ld a,(copy_dst_row)
	dec a
	jr v9958_copy_rows_store_dst
v9958_copy_rows_advance:
	inc a
	ld (copy_src_row),a
	ld a,(copy_dst_row)
	inc a
v9958_copy_rows_store_dst:
	ld (copy_dst_row),a
	ld a,(copy_row_count)
	dec a
	ld (copy_row_count),a
	jr nz,v9958_copy_rows_loop
	ret

v9958_scroll_up_one:
	; Advance logical row zero by one eight-line cell. R#23 then makes the VDP
	; fetch the existing rows from their new screen positions without a bitmap
	; copy. Only the discarded half-row margin and new last row need clearing.
	ld a,(v9958_scroll_origin)
	add a,#TEXT_CELL_HEIGHT
	ld (v9958_scroll_origin),a

	; The fixed four-line margin immediately precedes logical row zero.
	call v9958_clear_command_buffer
	ld a,(v9958_scroll_origin)
	sub #TEXT_DISPLAY_OFFSET
	ld (command_buffer + VDP_CMD_DY_LO),a
	xor a
	ld (command_buffer + VDP_CMD_NX_LO),a
	ld a,#0x02
	ld (command_buffer + VDP_CMD_NX_HI),a
	ld a,#TEXT_DISPLAY_OFFSET
	ld (command_buffer + VDP_CMD_NY_LO),a
	ld a,#0x44
	ld (command_buffer + VDP_CMD_COLOR),a
	ld a,#V9958_COMMAND_HMMV
	ld (command_buffer + VDP_CMD_CODE),a
	call v9958_start_command

	; Clear the newly exposed logical bottom row using the current background.
	ld d,#0x00
	ld e,#(TEXT_ROWS - 1)
	ld b,#TEXT_LOG_COLUMNS
	ld c,#0x01
	call v9958_fill_cells
	call v9958_wait_command

	; Commit the new circular origin immediately. An earlier revision waited
	; for S#2.VR here so the origin changed only during vertical retrace. That
	; wait costs up to a full field (16.7 ms NTSC / 20 ms PAL, ~8 ms average)
	; on *every* scrolled line, which caps scrolling output at the field rate
	; and made this driver slower than the VDrip console. The two fills above
	; are ~0.3 ms of command-engine time, so the retrace wait was more than
	; twenty times the cost of the work it protected. Writing R#23 mid-field
	; can tear one field; during continuous output that is not visible, and it
	; is the only artifact this trades away.
	ld a,(v9958_scroll_origin)
	sub #TEXT_DISPLAY_OFFSET
	ld b,#23
	jp v9958_write_register

; Input: A=line count, already clamped to the available region.
v9958_insert_lines:
	ld (il_dl_n),a
	ld a,(text_row)
	ld (il_dl_row),a
	ld b,a
	ld a,#TEXT_ROWS
	sub b
	ld b,a
	ld a,(il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld (il_dl_shift),a
	jr z,v9958_insert_fill
	ld b,a
	ld a,(il_dl_row)
	ld d,a
	ld a,(il_dl_n)
	add a,d
	ld d,a
	ld a,(il_dl_row)
	ld c,#V9958_ARGUMENT_DIY
	call v9958_copy_rows
v9958_insert_fill:
	ld d,#0x00
	ld a,(il_dl_row)
	ld e,a
	ld b,#TEXT_LOG_COLUMNS
	ld a,(il_dl_n)
	ld c,a
	jp v9958_fill_cells

; Input: A=line count, already clamped to the available region.
v9958_delete_lines:
	ld (il_dl_n),a
	ld a,(text_row)
	ld (il_dl_row),a
	ld b,a
	ld a,#TEXT_ROWS
	sub b
	ld b,a
	ld a,(il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld (il_dl_shift),a
	jr z,v9958_delete_fill
	ld b,a
	ld a,(il_dl_row)
	ld d,a
	add a,c
	ld c,#0x00
	call v9958_copy_rows
v9958_delete_fill:
	ld d,#0x00
	ld a,#TEXT_ROWS
	ld b,a
	ld a,(il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld e,a
	ld b,#TEXT_LOG_COLUMNS
	jp v9958_fill_cells

; Clear all 256 lines of the circular page-zero bitmap and restore its origin.
v9958_clear_screen:
	call v9958_flush_print_run
	xor a
	ld (v9958_scroll_origin),a
	ld a,#V9958_R23_TEXT_BASE
	ld b,#23
	call v9958_write_register
	call v9958_clear_command_buffer
	xor a
	ld (command_buffer + VDP_CMD_NX_LO),a
	ld a,#0x02
	ld (command_buffer + VDP_CMD_NX_HI),a
	xor a
	ld (command_buffer + VDP_CMD_NY_LO),a
	ld a,#0x01
	ld (command_buffer + VDP_CMD_NY_HI),a
	ld a,(current_attr)
	and #0x01
	ld a,#0x44
	jr z,v9958_clear_have_color
	ld a,#0xff
v9958_clear_have_color:
	ld (command_buffer + VDP_CMD_COLOR),a
	ld a,#V9958_COMMAND_HMMV
	ld (command_buffer + VDP_CMD_CODE),a
	call v9958_start_command
	jp v9958_present

; Input: A=logical text row. Output: A=page-zero physical scanline. The origin
; and row height are both multiples of eight, so an eight-line cell never
; crosses from command page zero into the atlas page.
v9958_logical_row_to_vram_y:
	add a,a
	add a,a
	add a,a
	ld c,a
	ld a,(v9958_scroll_origin)
	add a,c
	ret

; A * 6 -> HL. Clobbers DE.
v9958_multiply_by_six:
	ld l,a
	ld h,#0x00
	add hl,hl
	ld e,l
	ld d,h
	add hl,hl
	add hl,de
	ret

; ---------------------------------------------------------------------------
; Direct VRAM and cursor helpers
; ---------------------------------------------------------------------------

; Input: DE=low 16 address, C=A16, B=count, HL=source.
; May block waiting for a command, then relies on native WAIT for each data byte.
v9958_write_vram_small:
	call v9958_wait_command
	push bc
	ld a,c
	and #0x01
	rlca
	rlca
	ld c,a
	ld a,d
	rlca
	rlca
	and #0x03
	or c
	ld b,#14
	call v9958_write_register
	pop bc
	ld a,e
	out (V9958_COMMAND_PORT),a
	ld a,d
	and #0x3f
	or #0x40
	out (V9958_COMMAND_PORT),a
	ld c,#V9958_DATA_PORT
	otir
	ret

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
	call v9958_logical_row_to_vram_y
	dec a
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
; the font data at CONSOLE_FONT_ROM_BASE (0x8000) in SRAM bank 0 from ROM.
; Transient programs may have overwritten the TPA area containing the font.
;
; Uses COPY_LATCH0 (= SHADOW_BIT): reads come from ROM bank 0 low area,
; writes go to SRAM bank 0. This is the same technique used by the shadow
; copy and restore_ccp_from_rom for their respective ROM regions.
;
; Inputs:  None.
; Outputs: SRAM bank 0 [CONSOLE_FONT_ROM_BASE .. +FONT_BYTES-1] refreshed.
; Clobbers: AF, BC, DE, HL.
; Interrupts: Safe to call with interrupts disabled (wboot context); matches
;   the convention of restore_ccp_from_rom which is called without di/ei.
; Virtual Drip traffic: None.
; ---------------------------------------------------------------------------

console_backend_restore_font_from_rom:
restore_font_from_rom:
	ld a,#COPY_LATCH0		; ROM bank 0 low area visible, writes to SRAM
	out (BANK_PORT),a
	ld hl,#CONSOLE_FONT_ROM_BASE	; ROM bank 0 source (0x8000)
	ld de,#CONSOLE_FONT_ROM_BASE	; SRAM bank 0 destination (0x8000)
	ld bc,#FONT_BYTES
	ldir
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a
	ret


; Write a caller-sized block at the raw VIDEO_SEND-selected VDP address.
; Inputs: HL=source, BC=length. The caller owns VDP sequencing; native WAIT
; paces each byte. No status read occurs here because that would reset a
; partially assembled two-byte command-port write. Not ISR-safe.
console_backend_data_write_block:
v9958_data_write_block:
v9958_data_write_block_loop:
	ld a,b
	or c
	ret z
	ld a,(hl)
	inc hl
	out (V9958_DATA_PORT),a
	dec bc
	jr v9958_data_write_block_loop

; Selected-console single-request implementation. The historical packet-type
; API remains usable, but supported operations go straight to physical ports.
console_backend_send_frame:
	cp #VIDEO_TYPE_RESET
	jr z,v9958_video_send_reset
	cp #VIDEO_TYPE_FRAME_MARK
	jr z,v9958_video_send_present
	ld d,a
	ld a,b
	or a
	jr nz,v9958_video_send_error
	ld a,c
	cp #0x01
	jr nz,v9958_video_send_error
	ld a,(hl)
	ld c,d
	ld d,a
	ld a,c
	cp #VIDEO_TYPE_VDP_CTRL_WRITE
	jr z,v9958_video_send_ctrl
	cp #VIDEO_TYPE_VDP_DATA_WRITE
	jr z,v9958_video_send_data
	cp #VIDEO_TYPE_VDP_PALETTE_WRITE
	jr z,v9958_video_send_palette
	cp #VIDEO_TYPE_VDP_INDIRECT_WRITE
	jr nz,v9958_video_send_error
	ld a,d
	out (V9958_INDIRECT_PORT),a
	jr v9958_video_send_ok
v9958_video_send_ctrl:
	ld a,d
	out (V9958_COMMAND_PORT),a
	jr v9958_video_send_ok
v9958_video_send_data:
	ld a,d
	out (V9958_DATA_PORT),a
	jr v9958_video_send_ok
v9958_video_send_palette:
	ld a,d
	out (V9958_PALETTE_PORT),a
v9958_video_send_ok:
	xor a
	ret
v9958_video_send_present:
	call v9958_present
	xor a
	ret
v9958_video_send_reset:
	call v9958_reset_display
	xor a
	ret
v9958_video_send_error:
	ld a,#BIOS_ERR
	ret

; BIOS-owned V9958 sprite cursor facade helpers.

v9958_cursor_enable:
	ret


v9958_cursor_show:
	call v9958_flush_print_run
	ld a,#0x01
	ld (cursor_visible),a
	jp v9958_cursor_write_sat


v9958_cursor_hide:
	call v9958_flush_print_run
	xor a
	ld (cursor_visible),a
	jp v9958_cursor_write_sat


v9958_cursor_set_position_current:
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	jp v9958_present


v9958_cursor_set_style_underline:
	ret


v9958_cursor_set_blink_default:
	ret


v9958_cursor_set_color_yellow:
	ret


; ===========================================================================
; Data / buffers / font include
; ===========================================================================
;
; Variables are grouped by subsystem without reordering code or changing storage.
; These live in the driver slot area with the code and are part of the current
; memory layout.

; LunchCrema U12 configuration-latch shadow. D0 is the interrupt route and D1
; controls /WS_EN; all writes preserve D0 while changing only D1.
v9958_config_shadow:
	.db 0x00

; Physical page-zero scanline containing logical text row zero. R#23 is this
; value minus TEXT_DISPLAY_OFFSET, preserving the four-line top margin.
v9958_scroll_origin:
	.db 0x00

; Text cursor state.
; text_col/text_row are internal 0-based logical coordinates.
text_col:
	.db 0x00

text_row:
	.db 0x00

command_buffer:
	.ds ATLAS_ROW_BYTES

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

; Real-card G6 baseline from the verified LunchCrema bring-up sequence.
; R#1 deliberately keeps the display disabled until VRAM initialization ends.
v9958_g6_registers:
	.db 0x0a			; R#0: G6 mode select
	.db V9958_R1_DISPLAY_OFF	; R#1: display disabled during initialization
	.db 0x1f			; R#2: physical G6 page-zero baseline
	.db 0x00			; R#3
	.db 0x00			; R#4
	.db 0xe4			; R#5/R#11 -> color 1F000h, SAT 1F200h
	.db 0x3f			; R#6: sprite pattern table
	.db 0x04			; R#7: text/background color baseline
	.db V9958_R8_64K_DRAM	; R#8: VR=1, 64Kx4 DRAMs
	.db 0x88			; R#9: PAL + 212-line mode
	.db 0x00			; R#10
	.db 0x03			; R#11

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
atlas_reverse_flag:
	.db 0x00

; Command-engine argument staging. The routines are foreground-only and not
; reentrant; keeping these bytes here avoids borrowing BIOS or HID scratch.
render_char:
	.db 0x00
render_col:
	.db 0x00
render_row:
	.db 0x00
fill_col:
	.db 0x00
fill_row:
	.db 0x00
fill_width:
	.db 0x00
fill_height:
	.db 0x00
copy_src_row:
	.db 0x00
copy_dst_row:
	.db 0x00
copy_row_count:
	.db 0x00
copy_argument:
	.db 0x00

; ANSI output parser state.
; Applies only to CONOUT bytes. Keyboard input must not use this state machine.
term_state:
	.db TERM_STATE_NORMAL

; DECAWM auto-wrap mode.  1 = auto-wrap enabled (default), 0 = disabled.
; Printable character output at the right margin wraps when enabled,
; clamps/overwrites when disabled.  ESC [ ? 7 h/l set/clear this flag.
; Reset to enabled by v9958_console_init and ESC c (v9958_reset_display).
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
; Video traffic: none. Not ISR-safe.
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


V9958_CONSOLE_CODE_END:

; ---------------------------------------------------------------------------
; Font data — bank 0 TPA, CONSOLE_FONT_ROM_BASE (0x8000).
;
; Placed in a separate absolute area so the driver CODE area ends cleanly at
; V9958_CONSOLE_CODE_END. The 256-glyph CP850 font lands in the bank 0
; firmware image at 0x8000. The boot shadow copy transfers it to SRAM bank 0.
; restore_font_from_rom refreshes it from ROM using COPY_LATCH0 at warm boot.
; Programs may overwrite this TPA address after init; the warm-boot restore
; always refreshes it before the G6 atlas upload is performed.
; ---------------------------------------------------------------------------

	.area FONT_DATA (ABS)
	.org CONSOLE_FONT_ROM_BASE

	.include "font_cp850_6x8.inc"
