; Zephyr-80 CP/M smiley sprite demo using the VIDEO_SEND extended BIOS call.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Build as a CP/M .COM file (org 0x0100).  Transfer to the Z80 and run from
; the CP/M command line:  video_smiley
;
; The program takes over the VDP display, animates a moving smiley sprite, and
; restores normal BIOS console mode when the user presses ESC.
;
; Derived from vdrip_smiley.asm (monitor-loaded standalone test).
; All SIO, RX, keyboard-parse, and packet-engine code has been removed.
; VDP traffic is routed entirely through the VIDEO_SEND extended BIOS call.

	.module video_smiley
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
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08

; ---------------------------------------------------------------------------
; TMS9928A Graphics I VRAM layout.
; ---------------------------------------------------------------------------
PATTERN_TABLE		= 0x0000
SPRITE_PATTERN_TABLE	= 0x1800
COLOR_TABLE		= 0x2000
NAME_TABLE		= 0x3800
SPRITE_ATTRIBUTE_TABLE	= 0x3B00

; ---------------------------------------------------------------------------
; Sprite animation constants.
; ---------------------------------------------------------------------------
SPRITE_Y_START		= 0x58
SPRITE_STEP		= 0x04
SPRITE_WRAP_X		= 0xF8
SPRITE_COLOR_NORMAL	= 0x0A		; light green

; ---------------------------------------------------------------------------
; Entry point.
; ---------------------------------------------------------------------------
start:
	; Reset and initialize the VDP through the BIOS.
	xor a				; A = 00h = VIDEO_SEND reset
	call VIDEO_SEND

	call video_ping
	call init_vdp_graphics1
	call init_background
	call init_sprite_tables

	; Set starting sprite state.
	ld a, #SPRITE_Y_START
	ld (sprite_y), a
	ld a, #SPRITE_COLOR_NORMAL
	ld (sprite_color), a
	xor a
	ld (sprite_x), a

	call update_sprite_position
	call video_frame_mark

; ---------------------------------------------------------------------------
; Main animation loop.
; ---------------------------------------------------------------------------
animation_loop:
	; Poll for ESC key each frame (non-blocking, BDOS CONST + CONIN).
	call check_esc
	jr z, exit_program

	call update_sprite_position
	call video_frame_mark
	call delay_frame

	; Advance sprite X; wrap at SPRITE_WRAP_X.
	ld a, (sprite_x)
	add a, #SPRITE_STEP
	cp #SPRITE_WRAP_X
	jr c, anim_store_x
	xor a
anim_store_x:
	ld (sprite_x), a
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
; video_ctrl_write and video_data_write preserve BC, DE, HL so they can be
; called inside loops that use those registers as counters/pointers.
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
; VDP helpers.
; ---------------------------------------------------------------------------

; Write TMS9928A register B with value A.
vdp_write_register:
	call video_ctrl_write		; send register value
	ld a, b
	or #0x80
	call video_ctrl_write		; send register select
	ret

; Set TMS9928A VRAM write address to HL.
vdp_set_vram_write_addr:
	ld a, l
	call video_ctrl_write
	ld a, h
	and #0x3F
	or #0x40
	call video_ctrl_write
	ret

; ---------------------------------------------------------------------------
; Update two overlaid 8x8 sprites: yellow face plus dark facial details.
; Rewrites only sprite attribute bytes each frame.
; ---------------------------------------------------------------------------
update_sprite_position:
	ld hl, #SPRITE_ATTRIBUTE_TABLE
	call vdp_set_vram_write_addr

	ld a, (sprite_y)
	call vdp_write_data_byte
	ld a, (sprite_x)
	call vdp_write_data_byte
	xor a				; pattern 0: yellow face
	call vdp_write_data_byte
	ld a, (sprite_color)
	call vdp_write_data_byte

	ld a, (sprite_y)		; overlay sprite: same position
	call vdp_write_data_byte
	ld a, (sprite_x)
	call vdp_write_data_byte
	ld a, #0x01			; pattern 1: eyes and smile
	call vdp_write_data_byte
	ld a, #0x04			; dark blue details
	call vdp_write_data_byte

	ld a, #0xD0			; sprite list terminator
	call vdp_write_data_byte
	ret

; ---------------------------------------------------------------------------
; Graphics I mode: display on, 16 KiB VRAM, 8x8 sprites, white on dark.
; ---------------------------------------------------------------------------
init_vdp_graphics1:
	ld b, #0x00
	ld a, #0x00
	call vdp_write_register
	ld b, #0x01
	ld a, #0xC0
	call vdp_write_register
	ld b, #0x02
	ld a, #(NAME_TABLE >> 10)
	call vdp_write_register
	ld b, #0x03
	ld a, #(COLOR_TABLE >> 6)
	call vdp_write_register
	ld b, #0x04
	ld a, #(PATTERN_TABLE >> 11)
	call vdp_write_register
	ld b, #0x05
	ld a, #(SPRITE_ATTRIBUTE_TABLE >> 7)
	call vdp_write_register
	ld b, #0x06
	ld a, #(SPRITE_PATTERN_TABLE >> 11)
	call vdp_write_register
	ld b, #0x07
	ld a, #0xF4			; white on dark red background
	call vdp_write_register
	ret

; ---------------------------------------------------------------------------
; init_background
; Writes two tile patterns, the color table, and the name table.
; ---------------------------------------------------------------------------
init_background:
	; Pattern 0: blank (all zeros).
	ld hl, #PATTERN_TABLE
	call vdp_set_vram_write_addr
	ld b, #0x08
init_pat0_loop:
	xor a
	call vdp_write_data_byte
	djnz init_pat0_loop

	; Pattern 1: checkerboard (AA / 55 alternating rows).
	ld b, #0x08
	ld e, #0xAA
init_pat1_loop:
	ld a, e
	call vdp_write_data_byte
	ld a, e
	xor #0xFF
	ld e, a
	djnz init_pat1_loop

	; Color table: all tile groups white-on-dark-red.
	ld hl, #COLOR_TABLE
	call vdp_set_vram_write_addr
	ld b, #0x20
init_color_loop:
	ld a, #0xF4
	call vdp_write_data_byte
	djnz init_color_loop

	; Name table: 24 rows × 32 columns, alternating tile 0 and tile 1.
	ld hl, #NAME_TABLE
	call vdp_set_vram_write_addr
	ld b, #0x18			; 24 rows
	ld d, #0x00			; row phase
init_name_row:
	ld c, #0x20			; 32 columns
	ld e, d
init_name_col:
	ld a, e
	call vdp_write_data_byte
	ld a, e
	xor #0x01
	ld e, a
	dec c
	jr nz, init_name_col
	ld a, d
	xor #0x01
	ld d, a
	djnz init_name_row
	ret

; ---------------------------------------------------------------------------
; init_sprite_tables
; Writes sprite pattern data; attribute table set by update_sprite_position.
; ---------------------------------------------------------------------------
init_sprite_tables:
	call write_smiley_sprite_pattern
	call update_sprite_position
	ret

write_smiley_sprite_pattern:
	ld hl, #SPRITE_PATTERN_TABLE
	call vdp_set_vram_write_addr
	ld hl, #smiley_sprite_patterns
	ld bc, #0x0010			; 2 patterns × 8 bytes
	call vdp_write_data_block
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

; Sprite 0: yellow face silhouette.
; Sprite 1: overlaid eyes and smile.
smiley_sprite_patterns:
	.db 0x3C, 0x7E, 0xFF, 0xFF, 0xFF, 0xFF, 0x7E, 0x3C
	.db 0x00, 0x00, 0x24, 0x24, 0x00, 0x42, 0x3C, 0x00

; Single-byte staging buffer for video_ctrl_write / video_data_write.
local_payload:
	.db 0x00

; Per-frame sprite state.
sprite_x:
	.db 0x00
sprite_y:
	.db SPRITE_Y_START
sprite_color:
	.db SPRITE_COLOR_NORMAL
