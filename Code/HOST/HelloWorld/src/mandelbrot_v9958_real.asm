; Zephyr-80 CP/M Mandelbrot demo — V9958 GRAPHIC 6 interlaced mode.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; DIRECT-HARDWARE variant: this talks to the real V9958 card over the CPU I/O
; ports ($A0-$A3) exactly as a BIOS driver would, instead of tunnelling VDP
; traffic through the Virtual Drip serial proxy (VIDEO_SEND). The card is a real
; framebuffer, so there is no "present" step — writing VRAM is immediately
; visible on the card's own display. Console keyboard input still goes through
; the BIOS (BDOS), which is independent of the video path.
;
; Build:
;   make build/mandelbrot_v9958_real.com
;
; Run from CP/M:
;   MANDELBROT_V9958_REAL
;
; The program takes over the V9958, renders a coloured Mandelbrot set into the
; G6 bitmap, waits for a key, then returns to CP/M leaving the image on screen.
;
; Rendering model:
;   - G6 source bitmap: 512x212, two 4-bit pixels per VRAM byte.
;   - Interlace output: 512x424 via R#9 IL+LN.
;   - Mandelbrot grid: 256x106 signed Q2.6 samples.
;   - Each sample is duplicated horizontally into one packed byte.
;   - Each computed scanline is duplicated vertically into two source lines.
;
; This gives a full-screen image with square output pixels while keeping the
; computation practical on a Z80. ESC aborts between computed rows.

	.module mandelbrot_v9958_real
	.area CODE (ABS)
	.org 0x0100

; ---------------------------------------------------------------------------
; CP/M interface
; ---------------------------------------------------------------------------

BDOS			= 0x0005
BDOS_DIRECT_IO		= 0x06
BDOS_EXIT		= 0x00
KEY_ESC			= 0x1b

; ---------------------------------------------------------------------------
; V9958 I/O ports (IO_DECODER.pld: VDP block $A0-$BF, A1:A0 select the port).
;   VDP_DATA   ($A0)  write/read VRAM (auto-incrementing)
;   VDP_CMD    ($A1)  write command port (address setup + register writes)
;                     read status registers
;   VDP_PAL    ($A2)  write palette data
;   VDP_REG    ($A3)  write indirect register data
; ---------------------------------------------------------------------------

VDP_DATA		= 0xa0
VDP_CMD			= 0xa1
VDP_PAL			= 0xa2
VDP_REG			= 0xa3

; ---------------------------------------------------------------------------
; G6 and Mandelbrot constants
; ---------------------------------------------------------------------------

G6_BYTES_PER_ROW	= 256
G6_SOURCE_ROWS		= 212
SAMPLE_ROWS		= 106

MAX_ITER		= 32

; Signed Q2.6 coordinates. One unit is 1/64.
; X spans exactly -2.0 .. +1.984375 in 256 steps.
; Y spans -1.65625 .. +1.625 in 106 steps.
CX_START		= -128
CY_START		= -106
CY_STEP			= 2

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------

start:
	; Take over the real V9958 directly.
	call init_g6
	call init_palette

	xor a
	ld (sample_row),a
	ld hl,#CY_START
	ld (cy),hl

render_row_loop:
	call check_abort
	jr z,exit_program

	call render_sample_row
	call send_doubled_row

	ld a,(sample_row)
	inc a
	ld (sample_row),a
	cp #SAMPLE_ROWS
	jr nc,render_complete

	ld hl,(cy)
	ld de,#CY_STEP
	add hl,de
	ld (cy),hl

	jr render_row_loop

render_complete:
	call wait_for_key

exit_program:
	; Leave the rendered image on the card and return to CCP. The BIOS console
	; is a separate (Virtual Drip) display, so nothing needs restoring here.
	ld c,#BDOS_EXIT
	jp BDOS

; ---------------------------------------------------------------------------
; Keyboard handling
; ---------------------------------------------------------------------------

; Return Z if ESC is pending, NZ otherwise. Other keys are consumed.
check_abort:
	ld c,#BDOS_DIRECT_IO
	ld e,#0xff
	call BDOS
	or a
	jr z,check_abort_none
	cp #KEY_ESC
	ret
check_abort_none:
	inc a
	ret

wait_for_key:
	ld c,#BDOS_DIRECT_IO
	ld e,#0xff
	call BDOS
	or a
	jr z,wait_for_key
	ret

; ---------------------------------------------------------------------------
; V9958 helpers (direct port I/O)
; ---------------------------------------------------------------------------

; Write one byte to the command port. Input: A=value.
video_ctrl_write:
	out (VDP_CMD),a
	ret

; Write one palette byte. Input: A=value.
video_palette_write:
	out (VDP_PAL),a
	ret

; Write a VDP register. Input: A=value, B=register number.
vdp_write_register:
	out (VDP_CMD),a			; data byte
	ld a,b
	or #0x80			; command byte: 1 rrrrr = write register r
	out (VDP_CMD),a
	ret

; Set the VRAM auto-increment WRITE address. Input: HL=VRAM address 0..0D3FFh.
; The G6 bitmap uses A15..A0; R#14 receives A16..A14 (A16 is always 0 here).
vdp_set_vram_write_addr:
	ld a,h
	rlca
	rlca
	and #0x03			; A15..A14 -> R#14 bits 1..0
	push bc
	ld b,#14
	call vdp_write_register
	pop bc

	ld a,l				; A7..A0
	out (VDP_CMD),a
	ld a,h
	and #0x3f			; A13..A8
	or #0x40			; bit6 = 1: set VRAM write address
	out (VDP_CMD),a
	ret

; ---------------------------------------------------------------------------
; V9958 initialization
; ---------------------------------------------------------------------------

init_g6:
	; Program R#0..R#11 directly for GRAPHIC 6.
	ld hl,#g6_registers
	ld b,#0				; register number
	ld c,#12			; count
init_g6_loop:
	ld a,(hl)			; register value
	out (VDP_CMD),a
	ld a,b
	or #0x80			; 1 rrrrr = write register
	out (VDP_CMD),a
	inc hl
	inc b
	dec c
	jr nz,init_g6_loop
	ret

init_palette:
	ld hl,#palette_data
	ld c,#0
	ld d,#16
init_palette_loop:
	; Select palette entry with R#16.
	push de
	push hl
	ld a,c
	ld b,#16
	call vdp_write_register
	pop hl
	pop de

	ld a,(hl)			; RB byte
	out (VDP_PAL),a
	inc hl
	ld a,(hl)			; G byte
	out (VDP_PAL),a
	inc hl

	inc c
	dec d
	jr nz,init_palette_loop
	ret

; ---------------------------------------------------------------------------
; Mandelbrot renderer
; ---------------------------------------------------------------------------

render_sample_row:
	ld hl,#scanline
	ld (row_pointer),hl
	ld hl,#CX_START
	ld (cx),hl
	xor a
	ld (sample_col),a

render_col_loop:
	call mandelbrot_point		; A = colour index 0..15
	ld c,a
	add a,a
	add a,a
	add a,a
	add a,a
	or c				; duplicate colour into both nibbles

	ld hl,(row_pointer)
	ld (hl),a
	inc hl
	ld (row_pointer),hl

	ld hl,(cx)
	inc hl
	ld (cx),hl

	ld a,(sample_col)
	inc a
	ld (sample_col),a
	jr nz,render_col_loop		; wraps after 256 columns
	ret

; Calculate one point at (cx,cy).
; Output: A=0 for points inside MAX_ITER, otherwise a palette index.
mandelbrot_point:
	ld hl,#0
	ld (zx),hl
	ld (zy),hl
	xor a
	ld (iteration),a

mandelbrot_iter_loop:
	; Values outside signed 8-bit Q2.6 cannot return inside the radius.
	ld hl,(zx)
	call q2_6_value_valid
	jr c,mandelbrot_escaped
	ld hl,(zy)
	call q2_6_value_valid
	jr c,mandelbrot_escaped

	ld hl,(zx)
	ld de,(zx)
	call mul_q2_6
	ld (zx2),hl

	ld hl,(zy)
	ld de,(zy)
	call mul_q2_6
	ld (zy2),hl

	; zx^2 + zy^2 >= 4.0. In Q2.6, 4.0 is 0100h.
	ld hl,(zx2)
	ld de,(zy2)
	add hl,de
	ld a,h
	or a
	jr nz,mandelbrot_escaped

	ld a,(iteration)
	cp #MAX_ITER
	jr nc,mandelbrot_inside

	; next_x = zx^2 - zy^2 + cx
	ld hl,(zx2)
	ld de,(zy2)
	or a
	sbc hl,de
	ld de,(cx)
	add hl,de
	ld (next_zx),hl

	; next_y = 2*zx*zy + cy
	ld hl,(zx)
	ld de,(zy)
	call mul_q2_6
	add hl,hl
	ld de,(cy)
	add hl,de
	ld (zy),hl

	ld hl,(next_zx)
	ld (zx),hl

	ld a,(iteration)
	inc a
	ld (iteration),a
	jr mandelbrot_iter_loop

mandelbrot_escaped:
	ld a,(iteration)
	and #0x1f
	ld e,a
	ld d,#0
	ld hl,#iteration_colors
	add hl,de
	ld a,(hl)
	ret

mandelbrot_inside:
	xor a
	ret

; Carry set if HL cannot be represented as signed Q2.6 in one byte.
q2_6_value_valid:
	ld a,h
	or a
	jr z,q2_6_positive
	inc a				; FFh becomes zero
	jr nz,q2_6_invalid
	bit 7,l
	jr z,q2_6_invalid
	or a				; clear carry
	ret
q2_6_positive:
	bit 7,l
	jr nz,q2_6_invalid
	or a
	ret
q2_6_invalid:
	scf
	ret

; Signed Q2.6 multiply.
; Input:  HL and DE are sign-extended values in the range -128..127.
; Output: HL = (HL * DE) >> 6.
; Clobbers: AF, BC, DE.
mul_q2_6:
	ld a,e
	ld (multiply_b),a
	xor a
	ld (multiply_sign),a

	ld a,l
	bit 7,a
	jr z,mul_q2_6_a_positive
	cpl
	inc a
	ld c,a
	ld a,#1
	ld (multiply_sign),a
	ld a,c
mul_q2_6_a_positive:
	ld e,a
	ld d,#0

	ld a,(multiply_b)
	bit 7,a
	jr z,mul_q2_6_b_positive
	cpl
	inc a
	ld c,a
	ld a,(multiply_sign)
	xor #1
	ld (multiply_sign),a
	ld a,c
mul_q2_6_b_positive:
	ld c,a
	ld hl,#0
	ld b,#8
mul_q2_6_loop:
	srl c
	jr nc,mul_q2_6_no_add
	add hl,de
mul_q2_6_no_add:
	sla e
	rl d
	djnz mul_q2_6_loop

	ld b,#6
mul_q2_6_shift:
	srl h
	rr l
	djnz mul_q2_6_shift

	ld a,(multiply_sign)
	or a
	ret z
	jp negate_hl

negate_hl:
	ld a,h
	cpl
	ld h,a
	ld a,l
	cpl
	ld l,a
	inc hl
	ret

; ---------------------------------------------------------------------------
; Scanline upload
; ---------------------------------------------------------------------------

; Write the computed row to source rows sample_row*2 and sample_row*2+1.
send_doubled_row:
	ld a,(sample_row)
	add a,a
	call send_scanline
	ld a,(sample_row)
	add a,a
	inc a
	jp send_scanline

; Input: A=source row 0..211.
send_scanline:
	; Each 256-byte G6 scanline begins at row*0100h.
	ld h,a
	ld l,#0
	call vdp_set_vram_write_addr

	; Stream 256 bytes to the VRAM data port with hardware auto-increment.
	; (IO_DECODER ignores A8..A15, so OTIR's B-on-A15..A8 is harmless.)
	ld hl,#scanline
	ld c,#VDP_DATA
	ld b,#0				; 0 -> 256 bytes
	otir
	ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

sample_row:
	.db 0x00
sample_col:
	.db 0x00
iteration:
	.db 0x00
multiply_sign:
	.db 0x00
multiply_b:
	.db 0x00

row_pointer:
	.dw 0x0000
cx:
	.dw 0x0000
cy:
	.dw 0x0000
zx:
	.dw 0x0000
zy:
	.dw 0x0000
zx2:
	.dw 0x0000
zy2:
	.dw 0x0000
next_zx:
	.dw 0x0000

; V9958 GRAPHIC 6 register block, R#0..R#11.
g6_registers:
	.db 0x0a			; R0: M5+M3 = GRAPHIC 6
	.db 0x40			; R1: display on
    .db 0x1f			; R2: bitmap line mask = full 256 lines (VRAM base 0).
					    ;     R#2 must be 1Fh on the real V9958 so the bitmap
					    ;     addresses all lines; 00h collapses to 8 lines.
	.db 0x00			; R3
	.db 0x00			; R4
	.db 0x00			; R5: sprites unused
	.db 0x00			; R6
	.db 0x00			; R7: black border
	.db 0x00			; R8
	.db 0x88			; R9: 212 lines + interlace
	.db 0x00			; R10
	.db 0x00			; R11

; Escape-time colour sequence. Entry zero is non-black so points that escape
; immediately remain distinct from points inside the set.
iteration_colors:
	.db 0x01,0x01,0x02,0x03,0x04,0x05,0x06,0x07
	.db 0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f
	.db 0x0e,0x0d,0x0c,0x0b,0x0a,0x09,0x08,0x07
	.db 0x06,0x05,0x04,0x03,0x02,0x01,0x02,0x03

; V9958 palette, two bytes per entry: RB then G, components 0..7.
palette_data:
	.db 0x00,0x00		;  0 black
	.db 0x10,0x00		;  1 deep red
	.db 0x30,0x00		;  2 red
	.db 0x50,0x00		;  3 bright red
	.db 0x70,0x01		;  4 orange-red
	.db 0x70,0x03		;  5 orange
	.db 0x70,0x05		;  6 gold
	.db 0x70,0x07		;  7 yellow
	.db 0x30,0x07		;  8 yellow-green
	.db 0x00,0x07		;  9 green
	.db 0x03,0x07		; 10 cyan-green
	.db 0x07,0x07		; 11 cyan
	.db 0x07,0x04		; 12 blue-cyan
	.db 0x07,0x01		; 13 blue
	.db 0x47,0x01		; 14 violet
	.db 0x77,0x07		; 15 white

scanline:
	.ds G6_BYTES_PER_ROW
