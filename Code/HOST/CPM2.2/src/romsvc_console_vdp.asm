; Zephyr-80 console VDP primitives, on ROM page 4.
;
; Phase 3 slice 4, and the last of the console.  The run accumulator, the glyph
; renderer, the cell fill, the row copy, the scroll, the line insert and delete,
; the screen clear, the VRAM writer and the cursor sprite -- everything that
; decides how pixels reach VRAM.
;
; What stayed behind, and why it had to:
;
;   VIDEO_SEND and v9958_data_write_block take HL as a pointer into the
;   CALLER's memory.  That is a read-direction service, and shadow mode
;   replaces reads below C000h -- a ROM copy would stream ROM bytes instead of
;   the application's buffer.  This is the rule the architecture note states as
;   direction rather than size, and it is the only reason these are not here.
;
;   RES_v9958_present is reachable from VIDEO_SEND, so it stays with it and is
;   called from this page at its resident address.
;
;   The CP/M driver entries, the per-character fast path, the state block and
;   the two buffers stay because they are the interface and the data.

v9958_append_printable:
	ld c,a
	ld a,(RES_print_run_count)
	cp #RES_PRINT_RUN_SIZE
	jr nz,v9958_append_have_space
	push bc
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	call RES_v9958_present
	pop bc
v9958_append_have_space:
	ld a,(RES_print_run_count)
	or a
	jr nz,v9958_append_have_start
	ld a,(RES_text_col)
	ld (RES_print_run_col),a
	ld a,(RES_text_row)
	ld (RES_print_run_row),a
v9958_append_have_start:
	ld hl,#RES_print_run_buffer
	ld a,(RES_print_run_count)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c
	ld a,(RES_print_run_count)
	inc a
	ld (RES_print_run_count),a
	ret

v9958_flush_print_run:
	ld a,(RES_print_run_count)
	or a
	ret z
	ld b,a
	ld hl,#RES_print_run_buffer
	ld a,(RES_print_run_col)
	ld d,a
	ld a,(RES_print_run_row)
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
	ld (RES_print_run_count),a
	ret

; Input: A=CP850 character, D=column, E=row. Starts one HMMM command and
; returns; the next VDP operation waits for it.
v9958_render_character:
	ld (RES_render_char),a
	ld a,d
	ld (RES_render_col),a
	ld a,e
	ld (RES_render_row),a
	call RES_v9958_clear_command_buffer

	ld a,(RES_render_char)
	and #0x1f
	call v9958_multiply_by_six
	ld a,l
	ld (RES_command_buffer + RES_VDP_CMD_SX_LO),a
	ld a,h
	ld (RES_command_buffer + RES_VDP_CMD_SX_HI),a

	ld a,(RES_render_char)
	srl a
	srl a
	srl a
	srl a
	srl a
	add a,a
	add a,a
	add a,a
	ld c,a
	ld a,(RES_current_attr)
	and #0x01
	jr z,v9958_render_normal_atlas
	ld a,c
	add a,#0x40
	ld c,a
v9958_render_normal_atlas:
	ld a,c
	ld (RES_command_buffer + RES_VDP_CMD_SY_LO),a
	ld a,#0x01
	ld (RES_command_buffer + RES_VDP_CMD_SY_HI),a

	ld a,(RES_render_col)
	call v9958_multiply_by_six
	ld a,l
	ld (RES_command_buffer + RES_VDP_CMD_DX_LO),a
	ld a,h
	ld (RES_command_buffer + RES_VDP_CMD_DX_HI),a

	ld a,(RES_render_row)
	call v9958_logical_row_to_vram_y
	ld (RES_command_buffer + RES_VDP_CMD_DY_LO),a

	ld a,#RES_TEXT_CELL_WIDTH
	ld (RES_command_buffer + RES_VDP_CMD_NX_LO),a
	ld a,#RES_TEXT_CELL_HEIGHT
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	ld a,#RES_V9958_COMMAND_HMMM
	ld (RES_command_buffer + RES_VDP_CMD_CODE),a
	jp RES_v9958_start_command

; Input: D=column, E=row, B=width in cells, C=height in cells.
; Uses the current SGR background (blue normally, white in reverse).
v9958_fill_cells:
	ld a,d
	ld (RES_fill_col),a
	ld a,e
	ld (RES_fill_row),a
	ld a,b
	ld (RES_fill_width),a
	ld a,c
	ld (RES_fill_height),a
	call RES_v9958_clear_command_buffer

	ld a,(RES_fill_col)
	call v9958_multiply_by_six
	ld a,l
	ld (RES_command_buffer + RES_VDP_CMD_DX_LO),a
	ld a,h
	ld (RES_command_buffer + RES_VDP_CMD_DX_HI),a

	ld a,(RES_fill_row)
	call v9958_logical_row_to_vram_y
	ld (RES_command_buffer + RES_VDP_CMD_DY_LO),a

	ld a,(RES_fill_width)
	call v9958_multiply_by_six
	ld a,l
	ld (RES_command_buffer + RES_VDP_CMD_NX_LO),a
	ld a,h
	ld (RES_command_buffer + RES_VDP_CMD_NX_HI),a

	ld a,(RES_current_attr)
	and #0x01
	ld a,#0x44
	jr z,v9958_fill_have_color
	ld a,#0xff
v9958_fill_have_color:
	ld (RES_command_buffer + RES_VDP_CMD_COLOR),a
	ld a,#RES_V9958_COMMAND_HMMV
	ld (RES_command_buffer + RES_VDP_CMD_CODE),a

	; A multi-row erase may cross the circular page-zero boundary. Split it
	; there so the command engine does not continue into the font page.
	ld a,(RES_fill_height)
	add a,a
	add a,a
	add a,a
	ld b,a
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	ld a,(RES_command_buffer + RES_VDP_CMD_DY_LO)
	add a,b
	jr nc,v9958_fill_start
	ld (RES_fill_height),a		; wrapped height after physical line 255
	ld a,(RES_command_buffer + RES_VDP_CMD_DY_LO)
	neg
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	call RES_v9958_start_command
	ld a,(RES_fill_height)
	or a
	ret z
	xor a
	ld (RES_command_buffer + RES_VDP_CMD_DY_LO),a
	ld a,(RES_fill_height)
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
v9958_fill_start:
	jp RES_v9958_start_command

; Input: A=source logical row, D=destination row, B=row count, C=ARG.
; Each eight-line cell row is copied separately so page-zero wrap is safe.
; DIY selects bottom-to-top order for overlapping insert-line moves.
v9958_copy_rows:
	ld (RES_copy_src_row),a
	ld a,d
	ld (RES_copy_dst_row),a
	ld a,b
	or a
	ret z
	ld (RES_copy_row_count),a
	ld a,c
	ld (RES_copy_argument),a
	ld a,(RES_copy_argument)
	and #RES_V9958_ARGUMENT_DIY
	jr z,v9958_copy_rows_loop
	ld a,(RES_copy_row_count)
	dec a
	ld b,a
	ld a,(RES_copy_src_row)
	add a,b
	ld (RES_copy_src_row),a
	ld a,(RES_copy_dst_row)
	add a,b
	ld (RES_copy_dst_row),a

v9958_copy_rows_loop:
	call RES_v9958_clear_command_buffer
	ld a,(RES_copy_src_row)
	call v9958_logical_row_to_vram_y
	ld (RES_command_buffer + RES_VDP_CMD_SY_LO),a
	ld a,(RES_copy_dst_row)
	call v9958_logical_row_to_vram_y
	ld (RES_command_buffer + RES_VDP_CMD_DY_LO),a
	ld a,#0xfe			; 85 cells * 6 pixels = 510
	ld (RES_command_buffer + RES_VDP_CMD_NX_LO),a
	ld a,#0x01
	ld (RES_command_buffer + RES_VDP_CMD_NX_HI),a
	ld a,#RES_TEXT_CELL_HEIGHT
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	ld a,#RES_V9958_COMMAND_HMMM
	ld (RES_command_buffer + RES_VDP_CMD_CODE),a
	call RES_v9958_start_command

	ld a,(RES_copy_argument)
	and #RES_V9958_ARGUMENT_DIY
	ld a,(RES_copy_src_row)
	jr z,v9958_copy_rows_advance
	dec a
	ld (RES_copy_src_row),a
	ld a,(RES_copy_dst_row)
	dec a
	jr v9958_copy_rows_store_dst
v9958_copy_rows_advance:
	inc a
	ld (RES_copy_src_row),a
	ld a,(RES_copy_dst_row)
	inc a
v9958_copy_rows_store_dst:
	ld (RES_copy_dst_row),a
	ld a,(RES_copy_row_count)
	dec a
	ld (RES_copy_row_count),a
	jr nz,v9958_copy_rows_loop
	ret

v9958_scroll_up_one:
	; Advance logical row zero by one eight-line cell. R#23 then makes the VDP
	; fetch the existing rows from their new screen positions without a bitmap
	; copy. Only the discarded half-row margin and new last row need clearing.
	ld a,(RES_v9958_scroll_origin)
	add a,#RES_TEXT_CELL_HEIGHT
	ld (RES_v9958_scroll_origin),a

	; The fixed four-line margin immediately precedes logical row zero.
	call RES_v9958_clear_command_buffer
	ld a,(RES_v9958_scroll_origin)
	sub #RES_TEXT_DISPLAY_OFFSET
	ld (RES_command_buffer + RES_VDP_CMD_DY_LO),a
	xor a
	ld (RES_command_buffer + RES_VDP_CMD_NX_LO),a
	ld a,#0x02
	ld (RES_command_buffer + RES_VDP_CMD_NX_HI),a
	ld a,#RES_TEXT_DISPLAY_OFFSET
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	ld a,#0x44
	ld (RES_command_buffer + RES_VDP_CMD_COLOR),a
	ld a,#RES_V9958_COMMAND_HMMV
	ld (RES_command_buffer + RES_VDP_CMD_CODE),a
	call RES_v9958_start_command

	; Clear the newly exposed logical bottom row using the current background.
	ld d,#0x00
	ld e,#(RES_TEXT_ROWS - 1)
	ld b,#RES_TEXT_LOG_COLUMNS
	ld c,#0x01
	call v9958_fill_cells
	call RES_v9958_wait_command

	; Commit the new circular origin immediately. An earlier revision waited
	; for S#2.VR here so the origin changed only during vertical retrace. That
	; wait costs up to a full field (16.7 ms NTSC / 20 ms PAL, ~8 ms average)
	; on *every* scrolled line, which caps scrolling output at the field rate
	; and made this driver slower than the VDrip console. The two fills above
	; are ~0.3 ms of command-engine time, so the retrace wait was more than
	; twenty times the cost of the work it protected. Writing R#23 mid-field
	; can tear one field; during continuous output that is not visible, and it
	; is the only artifact this trades away.
	ld a,(RES_v9958_scroll_origin)
	sub #RES_TEXT_DISPLAY_OFFSET
	ld b,#23
	jp RES_v9958_write_register

; Input: A=line count, already clamped to the available region.
v9958_insert_lines:
	ld (RES_il_dl_n),a
	ld a,(RES_text_row)
	ld (RES_il_dl_row),a
	ld b,a
	ld a,#RES_TEXT_ROWS
	sub b
	ld b,a
	ld a,(RES_il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld (RES_il_dl_shift),a
	jr z,v9958_insert_fill
	ld b,a
	ld a,(RES_il_dl_row)
	ld d,a
	ld a,(RES_il_dl_n)
	add a,d
	ld d,a
	ld a,(RES_il_dl_row)
	ld c,#RES_V9958_ARGUMENT_DIY
	call v9958_copy_rows
v9958_insert_fill:
	ld d,#0x00
	ld a,(RES_il_dl_row)
	ld e,a
	ld b,#RES_TEXT_LOG_COLUMNS
	ld a,(RES_il_dl_n)
	ld c,a
	jp v9958_fill_cells

; Input: A=line count, already clamped to the available region.
v9958_delete_lines:
	ld (RES_il_dl_n),a
	ld a,(RES_text_row)
	ld (RES_il_dl_row),a
	ld b,a
	ld a,#RES_TEXT_ROWS
	sub b
	ld b,a
	ld a,(RES_il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld (RES_il_dl_shift),a
	jr z,v9958_delete_fill
	ld b,a
	ld a,(RES_il_dl_row)
	ld d,a
	add a,c
	ld c,#0x00
	call v9958_copy_rows
v9958_delete_fill:
	ld d,#0x00
	ld a,#RES_TEXT_ROWS
	ld b,a
	ld a,(RES_il_dl_n)
	ld c,a
	ld a,b
	sub c
	ld e,a
	ld b,#RES_TEXT_LOG_COLUMNS
	jp v9958_fill_cells

; Clear all 256 lines of the circular page-zero bitmap and restore its origin.
v9958_clear_screen:
	call v9958_flush_print_run
	xor a
	ld (RES_v9958_scroll_origin),a
	ld a,#RES_V9958_R23_TEXT_BASE
	ld b,#23
	call RES_v9958_write_register
	call RES_v9958_clear_command_buffer
	xor a
	ld (RES_command_buffer + RES_VDP_CMD_NX_LO),a
	ld a,#0x02
	ld (RES_command_buffer + RES_VDP_CMD_NX_HI),a
	xor a
	ld (RES_command_buffer + RES_VDP_CMD_NY_LO),a
	ld a,#0x01
	ld (RES_command_buffer + RES_VDP_CMD_NY_HI),a
	ld a,(RES_current_attr)
	and #0x01
	ld a,#0x44
	jr z,v9958_clear_have_color
	ld a,#0xff
v9958_clear_have_color:
	ld (RES_command_buffer + RES_VDP_CMD_COLOR),a
	ld a,#RES_V9958_COMMAND_HMMV
	ld (RES_command_buffer + RES_VDP_CMD_CODE),a
	call RES_v9958_start_command
	jp RES_v9958_present

; Input: A=logical text row. Output: A=page-zero physical scanline. The origin
; and row height are both multiples of eight, so an eight-line cell never
; crosses from command page zero into the atlas page.
v9958_logical_row_to_vram_y:
	add a,a
	add a,a
	add a,a
	ld c,a
	ld a,(RES_v9958_scroll_origin)
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
	call RES_v9958_wait_command
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
	call RES_v9958_write_register
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


v9958_cursor_write_sat:
	ld hl,#RES_cursor_sat
	ld a,(RES_cursor_visible)
	or a
	jr z,v9958_cursor_hidden
	ld a,(RES_text_row)
	call v9958_logical_row_to_vram_y
	dec a
	jr v9958_cursor_store_y
v9958_cursor_hidden:
	ld a,#RES_V9958_CURSOR_HIDE_Y
v9958_cursor_store_y:
	ld (hl),a
	inc hl
	ld a,(RES_text_col)
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
	ld (hl),#RES_V9958_CURSOR_HIDE_Y
	inc hl
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ld hl,#RES_cursor_sat
	ld de,#0xf200
	ld c,#0x01
	ld b,#0x08
	jp v9958_write_vram_small

v9958_cursor_enable:
	ret


v9958_cursor_show:
	call v9958_flush_print_run
	ld a,#0x01
	ld (RES_cursor_visible),a
	jp v9958_cursor_write_sat


v9958_cursor_hide:
	call v9958_flush_print_run
	xor a
	ld (RES_cursor_visible),a
	jp v9958_cursor_write_sat


v9958_cursor_set_position_current:
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	jp RES_v9958_present


v9958_cursor_set_style_underline:
	ret


v9958_cursor_set_blink_default:
	ret


v9958_cursor_set_color_yellow:
	ret

; Service entry: the flush/cursor/present triple that CONST and CONIN shared.
romsvc_flush_sync:
	call v9958_flush_print_run
	call v9958_cursor_write_sat
	jp RES_v9958_present
