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
	.include "romsvc_abi.inc"
	.globl ROM_GATE
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

; Idle-spin throttle for the blocking CONIN wait.
;
; This loop is the only thing running while CP/M sits at the prompt, and reading
; the /CTSB doorbell every pass drove an OUT/IN to SIO1/B every ~12.7 us.  That
; is audible: measured at -50 dB in the ~200 Hz range, present at the prompt,
; gone during a file read, and gone during playback INCLUDING the song's silent
; bars.  Holding the Z80 in reset silences it completely.
;
; The mechanism is not bus activity -- a VGM player writes sound registers far
; more heavily than this loop ever did and is silent.  There are no regulators
; on any board; the PSU supplies 3v3 and 5v directly, so the CPU's current draw
; modulates the shared rail with nothing to reject it, and a perfectly periodic
; loop concentrates that modulation into a few discrete frequencies instead of
; spreading it.  Player code is aperiodic and disappears into the noise floor;
; this loop was not, and did not.
;
; So the cure is to make the periodic event rare rather than cheap.  The counter
; below is register-only -- no bus cycles at all -- and sizes the doorbell read
; at roughly 100 Hz.  Each unit is 26 T-states at 10 MHz, so 3800 is about
; 9.9 ms.  Keystroke latency is bounded by that and no typist can perceive it;
; the IOC's own auto-repeat runs at a 60 ms period, so repeat is unaffected too.
;
; If any tone remains, this constant is the knob: halving it doubles the rate.
; A residual that does NOT move with it is not coming from this loop.
V9958_CONIN_SPIN_DELAY	= 3800

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

	; The display bring-up moved to ROM page 4 as one service.  It is one
	; sequence with an exact porch/WTE/VR ordering from the hardware notes,
	; so it crosses the gate once rather than eight times -- and the pieces
	; call each other directly on the far side, which they must: the gate is
	; not reentrant.
	ld a,#ROMSVC_DISPLAY_INIT
	jp ROM_GATE

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
	; The guard stays resident on purpose.  BDOS calls CONST once per printed
	; character, so a program polling with nothing pending must not pay a
	; gate crossing; with something pending, the flush, the cursor publish and
	; the present are one service rather than three crossings.
	ld a,(print_run_count)
	or a
	jr z,v9958_console_const_output_done
	ld a,#ROMSVC_FLUSH_SYNC
	call ROM_GATE
v9958_console_const_output_done:

	; hid_input_status reads the /CTSB doorbell and issues an IOCALL only when
	; the controller says it has something, so this is safe on
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
	ld a,#ROMSVC_FLUSH_SYNC
	call ROM_GATE

v9958_console_conin_wait:
	; Spin without touching the bus, then look at the doorbell once.
	;
	; The doorbell already removed the old rate-limited IOCALL, whose burst of
	; MCU-clocked frames tens of times a second was the loud buzz.  What was
	; left was this loop reading SIO1/B flat out; the delay is what makes an
	; idle prompt quiet.  See V9958_CONIN_SPIN_DELAY above.
	;
	; Nothing else needs servicing here: console receive is interrupt-driven on
	; SIO0/B, and the doorbell is a level, so a keystroke that arrives during
	; the delay is still waiting when the loop looks.
	ld hl,#V9958_CONIN_SPIN_DELAY
v9958_console_conin_idle:
	dec hl
	ld a,h
	or l
	jr nz,v9958_console_conin_idle

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
; ---------------------------------------------------------------------------
; term_process_byte -- resident fast path for console output.
;
; The terminal layer moved to ROM page 4 in Phase 3 slice 3.  This did not: a
; gate crossing is about 381 T-states, 38us at 10 MHz, which is roughly what the
; full parser cost per byte and would add 84ms to a full 85x26 repaint.  So the
; common case stays here and the gate is entered only when something has to
; happen that is not "put this character in the run buffer".
;
; Four conditions, all of which must hold:
;
;   normal state          mid-escape, every byte belongs to the parser
;   printable byte        20h..FFh except 7Fh; CP850 high bytes are printable
;   room in the run       a full buffer has to flush, and flush is in ROM
;   not the last column   the last column wraps, which can scroll
;
; The cursor advance is inlined rather than called because of the last
; condition: while text_col < TEXT_LOG_COLUMNS - 1, text_advance_cursor is an
; increment and a store.  Every case that can wrap, scroll or flush is punted
; across the gate to the unchanged code on the far side.
;
; In:  A = byte.
; Out: nothing.  BC, DE and HL are the console facade's to preserve.
; ---------------------------------------------------------------------------
term_process_byte:
	ld c,a

	ld a,(term_state)
	cp #TERM_STATE_NORMAL
	jr nz,term_byte_slow

	ld a,c
	cp #0x20
	jr c,term_byte_slow
	cp #0x7f
	jr z,term_byte_slow

	ld a,(print_run_count)
	cp #PRINT_RUN_SIZE
	jr nc,term_byte_slow

	ld a,(text_col)
	cp #(TEXT_LOG_COLUMNS - 1)
	jr nc,term_byte_slow

	; A non-Esc byte clears the triple-Esc counter, exactly as the full
	; parser does; the serial console's takeover gesture depends on it.
	xor a
	ld (esc_press_count),a

	; The first byte of a run records where the run starts on screen.
	ld a,(print_run_count)
	or a
	jr nz,term_byte_append
	ld a,(text_col)
	ld (print_run_col),a
	ld a,(text_row)
	ld (print_run_row),a

term_byte_append:
	ld a,(print_run_count)
	ld e,a
	ld d,#0x00
	ld hl,#print_run_buffer
	add hl,de
	ld (hl),c
	inc a
	ld (print_run_count),a

	ld a,(text_col)
	inc a
	ld (text_col),a
	ret

term_byte_slow:
	; C already holds the byte; the gate passes BC through untouched.
	ld a,#ROMSVC_CONSOLE_BYTE
	jp ROM_GATE



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




; ===========================================================================
; VDP reset (triple-Esc)
; ===========================================================================
;
; Called when Esc is pressed three times rapidly.
; Re-initialises the VDP text mode, font, and virtual cursor.

console_backend_reset_display:
v9958_reset_display:
	; Moved to ROM page 4 (ROMSVC_RESET_DISPLAY), together with the whole
	; init/reset cluster it drives.  Reached from the ESC handler and from
	; VIDEO_SEND's reset, so the resident entry point stays.
	ld a,#ROMSVC_RESET_DISPLAY
	jp ROM_GATE


; Input: A=value, B=register. Native WAIT and the LunchCrema porch must be on.
; Clobbers: AF. May block in the active VDP I/O cycle.
v9958_write_register:
	out (V9958_COMMAND_PORT),a
	ld a,b
	or #0x80
	out (V9958_COMMAND_PORT),a
	ret

; Input: HL=values, B=first register, C=count. Software paced.

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
	; Moved to ROM page 4 (ROMSVC_UPLOAD_ATLAS).  What used to be ~170 bytes
	; of resident builder is six bytes here.
	;
	; The font moved with it, because the glyph fetch reads 8000h and while
	; the service runs 8000h is ROM page 4 rather than bank 0.
	;
	; That removes a staging step rather than fixing a fault.  The font was
	; in the TPA by design: ROM to 8000h at boot, 8000h to VRAM, and from
	; then on the glyphs live in VRAM and the RAM copy is disposable -- a
	; transient overwriting it costs nothing, because the next boot re-copies
	; before the next upload.  The builder can now read the font straight out
	; of ROM, so the intermediate copy and the boot-time refresh that fed it
	; are both unnecessary.
	ld a,#ROMSVC_UPLOAD_ATLAS
	jp ROM_GATE



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
	; Nothing to restore.  This backend's atlas builder reads the font from
	; ROM page 4 directly, so there is no RAM staging copy to refresh.
	;
	; The entry point stays because cold and warm boot call it
	; unconditionally, and the VDrip console still uses the original design --
	; font copied from ROM to 8000h, then uploaded to VRAM -- which needs the
	; refresh to remain in the boot path.
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

; Real-card G6 baseline from the verified LunchCrema bring-up sequence.
; R#1 deliberately keeps the display disabled until VRAM initialization ends.
; The G6 register table, the console palette and the cursor sprite pattern and
; colours moved to ROM page 4 with the code that reads them; nothing resident
; touches them.

; V9958 palette entries 0..15, encoded as RB then G.
; Console text uses index 0 for black, 4 for blue, and 15 for white.

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
; The font used to be assembled here, at CONSOLE_FONT_ROM_BASE (8000h), so that
; boot could copy it into the TPA and upload it to VRAM from there.  This
; backend reads it from ROM page 4 instead -- see romsvc_page4.asm -- so the
; staging copy is gone and page 0 no longer carries 2 KiB at 8000h.
