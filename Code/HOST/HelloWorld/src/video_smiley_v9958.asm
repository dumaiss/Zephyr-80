; Zephyr-80 CP/M smiley sprite demo — V9958 G6 bitmap mode.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Build as a CP/M .COM file (org 0x0100).  Transfer to the Z80 and run from
; the CP/M command line:  video_s9958
;
; The program takes over the VDP display, initialises V9958 G6 in
; interlaced mode (512×424 output, 212-line source bitmap, 4-bit packed
; pixels, 16-colour palette), draws a moving smiley face directly into
; the bitmap VRAM, and restores normal BIOS console mode when the user
; presses ESC.
;
; Derived from video_smiley.asm (TMS9918 Graphics I sprite demo).
; Adapted for the V9958 G6 bitmap mode: no hardware sprites — the smiley is
; drawn as pixel data into the G6 bitmap framebuffer.
;
; V9958-specific additions:
;   - PACKET_VDP_PALETTE_WRITE (0x13) for palette port writes
;   - R#14 extended VRAM addressing for addresses ≥ 0x4000
;   - 3-bit-per-component palette encoding (R,B in first byte, G in second)

	.module video_smiley_v9958
	.area CODE (ABS)
	.org 0x0100

; ---------------------------------------------------------------------------
; CP/M BDOS
; ---------------------------------------------------------------------------
BDOS			= 0x0005

BDOS_CONIN		= 0x01		; console input (waits, echoes)
BDOS_CONST		= 0x0B		; console status — A=FFh if char ready
BDOS_EXIT		= 0x00		; warm boot / return to CCP

KEY_ESC			= 0x1B

; ---------------------------------------------------------------------------
; Zephyr-80 extended BIOS jump table.
; Keep in sync with CPM2.2 build/firmware.map (ZBIOS_EXT_BASE = DA33h).
; ---------------------------------------------------------------------------
VIDEO_SEND		= 0xDA42	; ZBIOS_EXT_BASE + 0x0F

; VIDEO_SEND calling convention:
;   A  = VDrip packet type  (00h or FFh = display reset/reinit)
;   HL = payload pointer
;   BC = payload length
;   Returns: A = 00h success, nonzero error.
;   Clobbers: AF, BC, DE, HL.

; ---------------------------------------------------------------------------
; VDrip packet types used by this program.
; ---------------------------------------------------------------------------
PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_VDP_DATA_BLOCK	= 0x0B
PACKET_VDP_PALETTE_WRITE = 0x13
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08

; ---------------------------------------------------------------------------
; V9958 G6 mode constants.
; ---------------------------------------------------------------------------
G6_SCREEN_W		= 512		; pixels per scanline
G6_SOURCE_H		= 212		; source bitmap lines (interlace doubles output to 424)
G6_BYTES_PER_ROW	= 256		; bytes per scanline (512 px / 2)
G6_VRAM_SIZE		= 54272		; 256 × 212

; Smiley sprite dimensions (pixels).
SMILEY_W		= 16
SMILEY_H		= 16
SMILEY_BYTES_PER_ROW	= 8		; 16 px / 2

; Background and palette colour indices.
COLOR_BG		= 0x04		; dark blue
COLOR_FACE		= 0x0A		; yellow
COLOR_EYE		= 0x00		; black
BG_BYTE			= 0x44		; both nibbles = COLOR_BG

; ---------------------------------------------------------------------------
; Animation constants.
; ---------------------------------------------------------------------------
SPRITE_Y_START		= 0x62		; near vertical centre of 212 source lines (≈106 = 0x6A)
SPRITE_STEP		= 0x04		; pixels per frame (must be even for byte align)
SPRITE_WRAP_X		= 0x1F0		; wrap near right edge (512 - 16 = 496 = 0x1F0)

; ---------------------------------------------------------------------------
; Entry point.
; ---------------------------------------------------------------------------
start:
	; Reset and initialize the VDP through the BIOS.
	xor a				; A = 00h = VIDEO_SEND reset
	call VIDEO_SEND

	call video_ping
	call init_vdp_g6
	call init_palette
	call fill_background_buffers
	call init_background

	; Set starting sprite state.
	ld a, #SPRITE_Y_START
	ld (sprite_y), a
	xor a
	ld (sprite_x), a

	call draw_smiley
	call video_frame_mark

; ---------------------------------------------------------------------------
; Main animation loop.
; ---------------------------------------------------------------------------
animation_loop:
	; Poll for ESC key each frame (non-blocking, BDOS CONST + CONIN).
	call check_esc
	jr z, exit_program

	; Erase smiley at old position, advance, draw at new position.
	call erase_smiley

	ld a, (sprite_x)
	add a, #SPRITE_STEP
	cp #SPRITE_WRAP_X
	jr c, anim_store_x
	xor a
anim_store_x:
	ld (sprite_x), a

	call draw_smiley
	call video_frame_mark
	call delay_frame
	jr animation_loop

; ---------------------------------------------------------------------------
; Exit: reset VDP to normal BIOS console mode, then return to CCP.
; ---------------------------------------------------------------------------
exit_program:
	xor a				; A = 00h = VIDEO_SEND reset/reinit
	call VIDEO_SEND			; BIOS restores text mode and font

	ld c, #BDOS_EXIT
	call BDOS			; warm boot — returns to CCP

; ---------------------------------------------------------------------------
; check_esc
; Poll BDOS for a pending keypress.  If ESC is found, return Z=1.
; Returns: Z=1 if ESC pressed, Z=0 if no char or any other char.
; Clobbers: AF, BC.
; ---------------------------------------------------------------------------
check_esc:
	ld c, #BDOS_CONST
	call BDOS			; A = FFh if char ready, 00h if not
	or a
	jr nz, check_esc_read
	inc a				; A was 0 (no char); inc clears Z
	ret				; Z=0: not ESC

check_esc_read:
	ld c, #BDOS_CONIN
	call BDOS			; char in A
	cp #KEY_ESC			; Z=1 if ESC
	ret

; ---------------------------------------------------------------------------
; VIDEO_SEND wrappers.
; video_ctrl_write, video_data_write, and video_palette_write preserve
; BC, DE, HL so they can be called inside loops that use those registers
; as counters/pointers.
; ---------------------------------------------------------------------------

; Send one VDP control byte (address/register select).
; Input:  A = control byte.
; Clobbers: AF only.
video_ctrl_write:
	push bc
	push de
	push hl
	ld (local_payload), a
	ld a, #PACKET_VDP_CTRL_WRITE
	ld bc, #1
	ld hl, #local_payload
	call VIDEO_SEND
	pop hl
	pop de
	pop bc
	ret

; Send one VDP data byte.
; Input:  A = data byte.
; Clobbers: AF only.
video_data_write:
	push bc
	push de
	push hl
	ld (local_payload), a
	ld a, #PACKET_VDP_DATA_WRITE
	ld bc, #1
	ld hl, #local_payload
	call VIDEO_SEND
	pop hl
	pop de
	pop bc
	ret

; Convenience alias so VDP helpers read naturally.
vdp_write_data_byte:
	jp video_data_write

; Send one VDP palette byte.
; Input:  A = palette byte.
; Clobbers: AF only.
video_palette_write:
	push bc
	push de
	push hl
	ld (local_payload), a
	ld a, #PACKET_VDP_PALETTE_WRITE
	ld bc, #1
	ld hl, #local_payload
	call VIDEO_SEND
	pop hl
	pop de
	pop bc
	ret

; Send zero-payload PING.
video_ping:
	ld a, #PACKET_PING
	ld bc, #0
	call VIDEO_SEND
	ret

; Send zero-payload FRAME_MARK.
video_frame_mark:
	ld a, #PACKET_FRAME_MARK
	ld bc, #0
	call VIDEO_SEND
	ret

; Send BC bytes from HL as a VDP data block (BIOS auto-chunks).
; Input:  HL = source pointer, BC = byte count.
; Clobbers: AF, BC, DE, HL (passed to VIDEO_SEND as inputs).
vdp_write_data_block:
	ld a, #PACKET_VDP_DATA_BLOCK
	call VIDEO_SEND
	ret

; ---------------------------------------------------------------------------
; VDP helpers — V9958 extended.
; ---------------------------------------------------------------------------

; Write V9958 register B with value A.
; Input:  A = register value, B = register number (0..63).
; Clobbers: AF only.
vdp_write_register:
	call video_ctrl_write		; send register value
	ld a, b
	or #0x80
	call video_ctrl_write		; send register select (bit 7 set)
	ret

; Set V9958 VRAM write address.
; Input:  HL = 17-bit VRAM address (0x00000..0x1FFFF).
;         For G6 with bitmap base at 0x00000, addresses are 0x0000..0xD3FF.
; Clobbers: AF.
vdp_set_vram_write_addr:
	; Set R#14 = A16..A14 first (extended addressing).
	ld a, h
	rlca
	rlca
	and #0x03			; A14..A15 from H bits 6..7
	push bc
	ld b, #14
	call vdp_write_register
	pop bc

	; Low 14 bits: A7..A0 from L, A13..A8 from H, write-mode (bit 6 set).
	ld a, l
	call video_ctrl_write
	ld a, h
	and #0x3F
	or #0x40
	call video_ctrl_write
	ret

; ---------------------------------------------------------------------------
; G6 mode initialisation — interlaced.
; R#0 = 0x0A (M3=1, M5=1 → G6 mode), R#1 = 0x40 (BL=1, display enable),
; R#2 = 0x00 (bitmap base low), R#7 = COLOR_BG (backdrop = dark blue),
; R#9 = 0x88 (LN=1 → 212 source lines, IL=1 → weave to 424 output lines).
; ---------------------------------------------------------------------------
init_vdp_g6:
	ld b, #0x00
	ld a, #0x0A			; M5=1, M3=1 → G6
	call vdp_write_register
	ld b, #0x01
	ld a, #0x40			; BL=1 (display enable)
	call vdp_write_register
	ld b, #0x02
	ld a, #0x00			; bitmap base = 0x00000
	call vdp_write_register
	ld b, #0x07
	ld a, #COLOR_BG			; backdrop/border = dark blue
	call vdp_write_register
	ld b, #0x09
	ld a, #0x88			; LN=1 (212 src), IL=1 (interlace → 424 output)
	call vdp_write_register
	ret

; ---------------------------------------------------------------------------
; Palette initialisation.
; Writes 16 palette entries via R#16 + VDP_PALETTE_WRITE.
; Colour indices used by the smiley:
;   0x0 = black (eyes/mouth), 0x4 = dark blue (background),
;   0xA = yellow (face).
; The remaining entries are set to reasonable defaults for potential use.
; ---------------------------------------------------------------------------
init_palette:
	ld hl, #palette_data
	ld b, #16			; 16 palette entries
	ld c, #0			; starting index
init_pal_loop:
	push bc
	; Select palette index via R#16.
	ld a, c
	push bc
	ld b, #16
	call vdp_write_register
	pop bc
	; Write RB byte (R in high nibble, B in low nibble).
	ld a, (hl)
	call video_palette_write
	inc hl
	; Write G byte.
	ld a, (hl)
	call video_palette_write
	inc hl
	pop bc
	inc c
	djnz init_pal_loop
	ret

; ---------------------------------------------------------------------------
; fill_background_buffers
; Fills bg_scanline (256 bytes) and bg_erase_row (8 bytes) with BG_BYTE.
; Called once during initialisation, before init_background.
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
fill_background_buffers:
	ld hl, #bg_scanline
	ld bc, #256
	ld a, #BG_BYTE
fill_bg_scanline_loop:
	ld (hl), a
	inc hl
	dec bc
	ld a, b
	or c
	ld a, #BG_BYTE
	jr nz, fill_bg_scanline_loop

	ld hl, #bg_erase_row
	ld bc, #SMILEY_BYTES_PER_ROW
	ld a, #BG_BYTE
fill_bg_erase_loop:
	ld (hl), a
	inc hl
	dec bc
	ld a, b
	or c
	ld a, #BG_BYTE
	jr nz, fill_bg_erase_loop
	ret

; ---------------------------------------------------------------------------
; Background initialisation.
; Fills the entire G6 bitmap (256 bytes × 212 rows = 54272 bytes) with the
; solid background colour.  Uses VDP_DATA_BLOCK with a pre-filled 256-byte
; scanline buffer.
; ---------------------------------------------------------------------------
init_background:
	ld de, #0			; D = current row (0..211)
	ld hl, #bg_scanline		; HL = pointer to 256-byte bg pattern

init_bg_row:
	; Set VRAM write address = D × 256.
	push de
	ld h, d
	ld l, #0
	call vdp_set_vram_write_addr
	pop de

	; Write one scanline (256 bytes of BG_BYTE).
	push de
	ld hl, #bg_scanline
	ld bc, #G6_BYTES_PER_ROW
	call vdp_write_data_block
	pop de

	inc d
	ld a, d
	cp #G6_SOURCE_H
	jr c, init_bg_row
	ret

; ---------------------------------------------------------------------------
; draw_smiley
; Draw the 16×16 smiley at the current (sprite_x, sprite_y) position.
; sprite_x is always even (aligned to byte boundary in the 4-bit packing).
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
draw_smiley:
	ld a, (sprite_y)
	ld d, a			; D = top row
	ld a, (sprite_x)
	srl a			; A = byte column (sprite_x / 2)
	ld e, a			; E = left byte column
	ld hl, #smiley_pattern	; HL = smiley pattern data
	ld b, #SMILEY_H		; B = row counter

draw_smiley_row:
	push bc
	push de
	push hl

	; Compute VRAM address = D * 256 + E.
	ld h, d
	ld l, e
	call vdp_set_vram_write_addr

	; Write one row of smiley pixels (8 bytes).
	pop hl			; HL = current pattern row pointer
	push hl
	ld bc, #SMILEY_BYTES_PER_ROW
	call vdp_write_data_block

	pop hl
	ld bc, #SMILEY_BYTES_PER_ROW
	add hl, bc		; advance to next pattern row
	pop de
	inc d			; next screen row
	pop bc
	djnz draw_smiley_row
	ret

; ---------------------------------------------------------------------------
; erase_smiley
; Erase the 16×16 region at the current (sprite_x, sprite_y) by filling it
; with the solid background colour.
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
erase_smiley:
	ld a, (sprite_y)
	ld d, a			; D = top row
	ld a, (sprite_x)
	srl a			; A = byte column
	ld e, a			; E = left byte column
	ld b, #SMILEY_H		; B = row counter

erase_smiley_row:
	push bc
	push de

	; Compute VRAM address = D * 256 + E.
	ld h, d
	ld l, e
	call vdp_set_vram_write_addr

	; Write one row of background (8 bytes of BG_BYTE).
	ld hl, #bg_erase_row
	ld bc, #SMILEY_BYTES_PER_ROW
	call vdp_write_data_block

	pop de
	inc d			; next screen row
	pop bc
	djnz erase_smiley_row
	ret

; ---------------------------------------------------------------------------
; Frame timing.
; ---------------------------------------------------------------------------
delay_frame:
	ld b, #0x03
delay_frame_loop:
	call delay_unit
	djnz delay_frame_loop
	ret

delay_unit:
	ld de, #0xFFFF
delay_unit_loop:
	dec de
	ld a, d
	or e
	jr nz, delay_unit_loop
	ret

; ---------------------------------------------------------------------------
; Data.
; ---------------------------------------------------------------------------

; Single-byte staging buffer for video_ctrl_write / video_data_write /
; video_palette_write.
local_payload:
	.db 0x00

; Per-frame sprite state.
sprite_x:
	.db 0x00
sprite_y:
	.db SPRITE_Y_START

; ---------------------------------------------------------------------------
; Palette data: 16 entries × 2 bytes each.
;   Byte 0 = RB: (R << 4) | (B & 0x07)     — R in high nibble, B in low
;   Byte 1 = G:  (G & 0x07)                 — G in low 3 bits
; All components are 3-bit (0..7).
; ---------------------------------------------------------------------------
palette_data:
	.db 0x00, 0x00		;  0: black          (0,0,0)
	.db 0x11, 0x01		;  1: dark grey      (1,1,1)
	.db 0x00, 0x06		;  2: green          (0,6,0)
	.db 0x00, 0x07		;  3: bright green   (0,7,0)
	.db 0x05, 0x00		;  4: dark blue      (0,0,5) — background
	.db 0x07, 0x03		;  5: light blue     (0,3,7)
	.db 0x50, 0x00		;  6: dark red       (5,0,0)
	.db 0x06, 0x06		;  7: cyan           (0,6,6)
	.db 0x70, 0x00		;  8: red            (7,0,0)
	.db 0x73, 0x03		;  9: pink           (7,3,3)
	.db 0x70, 0x07		; 10: yellow         (7,7,0) — face
	.db 0x74, 0x07		; 11: light yellow   (7,7,4)
	.db 0x00, 0x05		; 12: medium green   (0,5,0)
	.db 0x67, 0x00		; 13: purple         (6,0,7)
	.db 0x55, 0x05		; 14: grey           (5,5,5)
	.db 0x77, 0x07		; 15: white          (7,7,7)

; ---------------------------------------------------------------------------
; 16×16 smiley pattern — 4-bit packed pixels (2 pixels per byte).
; High nibble = left pixel, low nibble = right pixel.
; Colour indices: 0x0 = black (eyes/mouth), 0x4 = dark blue (background),
;                 0xA = yellow (face).
; ---------------------------------------------------------------------------
smiley_pattern:
	.db 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44	; row  0
	.db 0x44, 0x44, 0x4A, 0xAA, 0xAA, 0xA4, 0x44, 0x44	; row  1
	.db 0x44, 0x4A, 0xAA, 0xAA, 0xAA, 0xAA, 0xA4, 0x44	; row  2
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row  3
	.db 0x44, 0xAA, 0x00, 0xAA, 0xAA, 0x00, 0xAA, 0x44	; row  4 — eyes
	.db 0x44, 0xAA, 0x00, 0xAA, 0xAA, 0x00, 0xAA, 0x44	; row  5 — eyes
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row  6
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row  7
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row  8
	.db 0x44, 0xAA, 0xAA, 0xA4, 0x4A, 0xAA, 0xAA, 0x44	; row  9 — mouth corners
	.db 0x44, 0xAA, 0xAA, 0x44, 0x44, 0xAA, 0xAA, 0x44	; row 10 — smile
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row 11
	.db 0x44, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0x44	; row 12
	.db 0x44, 0x4A, 0xAA, 0xAA, 0xAA, 0xAA, 0xA4, 0x44	; row 13
	.db 0x44, 0x44, 0x4A, 0xAA, 0xAA, 0xA4, 0x44, 0x44	; row 14
	.db 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44	; row 15

; ---------------------------------------------------------------------------
; Background fill patterns.
; ---------------------------------------------------------------------------

; One full scanline of solid background colour (256 bytes of BG_BYTE).
; Used by init_background to fill the screen.
; Filled at runtime by fill_background_buffers.
bg_scanline:
	.ds 256

; One smiley-width row of solid background (8 bytes of BG_BYTE).
; Used by erase_smiley to restore background behind the moving smiley.
; Filled at runtime by fill_background_buffers.
bg_erase_row:
	.ds SMILEY_BYTES_PER_ROW
