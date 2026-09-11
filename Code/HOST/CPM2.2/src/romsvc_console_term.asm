; Zephyr-80 terminal layer, on ROM page 4.
;
; Phase 3 slice 3.  The VT100/CSI parser, the ANSI handlers and the text-layer
; semantics -- 96 labels, moved verbatim from cbios_console_v9958.asm.
;
; The line this slice draws is terminal semantics in ROM, VDP primitives in RAM.
; Everything here decides WHAT to draw; the routines it calls through RES_ names
; decide how to get it into VRAM, and they stay resident because the per-
; character fast path and VIDEO_SEND still reach them directly.
;
; The hot path did not move.  A gate crossing costs about 381 T-states, which is
; 38us at 10 MHz -- roughly what term_process_byte itself cost, and 84ms across a
; full 85x26 repaint.  So the resident side keeps a fast path that appends a
; printable byte to the run buffer and advances the column, and enters the gate
; only for a control byte, an escape sequence, a full run buffer, or the last
; column.  Line-oriented output crosses two or three times per line instead of
; once per character.
;
; The fast path is allowed to inline the cursor advance precisely because it
; runs only while RES_text_col < RES_TEXT_LOG_COLUMNS - 1, where text_advance_cursor
; reduces to an increment.  Every case that can wrap, scroll or flush is punted
; across the gate to the code below, unchanged.

term_process_byte:
	ld c,a

	ld a,(RES_term_state)
	cp #RES_TERM_STATE_ESC
	jp z,term_process_esc

	cp #RES_TERM_STATE_CSI
	jp z,term_process_csi
	cp #RES_TERM_STATE_ESC_HASH
	jp z,term_consume_one
	cp #RES_TERM_STATE_CHARSET
	jp z,term_consume_one

	; ---- NORMAL state ----
	ld a,c
	cp #0x1b
	jr z,term_enter_esc

	; Non-Esc byte resets the triple-Esc counter.
	push af
	xor a
	ld (RES_esc_press_count),a
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
	ld a,(RES_esc_press_count)
	inc a
	ld (RES_esc_press_count),a
	cp #3
	jp z,v9958_reset_display

	ld a,#RES_TERM_STATE_ESC
	ld (RES_term_state),a
	ret

term_process_esc:
	xor a
	ld (RES_term_state),a

	; Another Esc while in ESC state — count it.
	ld a,c
	cp #0x1b
	jr z,term_enter_esc

	; Non-ESC byte — reset triple-Esc counter.
	push af
	xor a
	ld (RES_esc_press_count),a
	pop af

	cp #'[
	jr nz,term_esc_not_csi

	; Enter CSI — reset parser variables.
	ld a,#RES_TERM_STATE_CSI
	ld (RES_term_state),a

	xor a
	ld (RES_csi_param0),a
	ld (RES_csi_param1),a
	ld (RES_csi_param_count),a
	ld (RES_csi_accum),a
	ld (RES_csi_have_digit),a
	ld (RES_csi_private_flag),a
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
	ld a,#RES_TERM_STATE_ESC_HASH
	ld (RES_term_state),a
	ret

term_enter_charset:
	ld a,#RES_TERM_STATE_CHARSET
	ld (RES_term_state),a
	ret

term_consume_one:
	xor a
	ld (RES_term_state),a
	ld (RES_esc_press_count),a
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

	ld a,(RES_csi_accum)
	add a,a		; *2
	ld d,a
	add a,a		; *4
	add a,a		; *8
	add a,d		; *10
	add a,e
	ld (RES_csi_accum),a

	ld a,#1
	ld (RES_csi_have_digit),a
	ret

term_csi_not_digit:
	; Question mark — DEC private sequence prefix.
	cp #'?
	jr nz,term_csi_not_qmark
	ld a,(RES_csi_param_count)
	or a
	jr nz,term_csi_not_qmark	; ? only valid as first char
	ld a,#0x01
	ld (RES_csi_private_flag),a
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
	ld (RES_term_state),a
	ld (RES_esc_press_count),a

	pop af

	jp ansi_dispatch_csi


; ---------------------------------------------------------------------------
; ANSI helpers
; ---------------------------------------------------------------------------

; Store RES_csi_accum into the current param slot (0-based index in
; RES_csi_param_count).  Advance RES_csi_param_count, capped at RES_CSI_MAX_PARAMS.
; Clears RES_csi_accum and RES_csi_have_digit.
ansi_store_param:
	ld a,(RES_csi_param_count)
	cp #RES_CSI_MAX_PARAMS
	jr nc,ansi_store_param_reset

	; Select slot: 0 -> RES_csi_param0, 1 -> RES_csi_param1.  If no digits were
	; seen, RES_csi_accum is zero; later default helpers treat zero as one for
	; VT100-style cursor counts and coordinates.
	ld a,(RES_csi_accum)
	push af
	ld a,(RES_csi_param_count)
	or a
	jr nz,ansi_store_slot1

	pop af
	ld (RES_csi_param0),a
	jr ansi_store_inc

ansi_store_slot1:
	pop af
	ld (RES_csi_param1),a

ansi_store_inc:
	ld a,(RES_csi_param_count)
	inc a
	ld (RES_csi_param_count),a

ansi_store_param_reset:
	xor a
	ld (RES_csi_accum),a
	ld (RES_csi_have_digit),a
	ret


; Return param0, default 1 if count == 0.
; Output: A = param value (at least 1).
ansi_param0_default_1:
	ld a,(RES_csi_param_count)
	or a
	jr z,ansi_pd1_ret1
	ld a,(RES_csi_param0)
	or a
	jr z,ansi_pd1_ret1
	ret
ansi_pd1_ret1:
	ld a,#1
	ret

; Return param1, default 1 if count < 2.
; Output: A = param value (at least 1).
ansi_param1_default_1:
	ld a,(RES_csi_param_count)
	cp #2
	jr c,ansi_pd1_ret1
	ld a,(RES_csi_param1)
	or a
	jr z,ansi_pd1_ret1
	ret


; ---------------------------------------------------------------------------
; CSI dispatch
; ---------------------------------------------------------------------------

ansi_dispatch_csi:
	ld c,a		; C = final command byte

	; DEC private mode (ESC [ ? ... h/l).
	ld a,(RES_csi_private_flag)
	or a
	jr z,ansi_dispatch_public

	ld a,c
	cp #RES_CSI_DECSET
	jp z,ansi_decset
	cp #RES_CSI_DECRST
	jp z,ansi_decrst
	ret		; unsupported DEC private — consume

ansi_dispatch_public:
	ld a,c
	cp #RES_CSI_CHA
	jp z,ansi_cha
	cp #RES_CSI_CUU
	jp z,ansi_cuu
	cp #RES_CSI_CUD
	jp z,ansi_cud
	cp #RES_CSI_CUF
	jp z,ansi_cuf
	cp #RES_CSI_CUB
	jp z,ansi_cub
	cp #RES_CSI_CUP
	jp z,ansi_cup
	cp #RES_CSI_CUP_ALT
	jp z,ansi_cup
	cp #RES_CSI_VPA
	jp z,ansi_vpa
	cp #RES_CSI_ED
	jp z,ansi_ed
	cp #RES_CSI_EL
	jp z,ansi_el
	cp #'X
	jp z,ansi_ech
	cp #RES_CSI_SGR
	jp z,ansi_sgr
	cp #'c
	ret z
	cp #'n
	ret z
	cp #RES_CSI_SAVE
	jp z,ansi_save_cursor
	cp #RES_CSI_RESTORE
	jp z,ansi_restore_cursor
	cp #RES_CSI_IL
	jp z,ansi_insert_lines
	cp #RES_CSI_DL
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
	cp #RES_TEXT_LOG_COLUMNS
	jr c,ansi_cha_clamped
	ld a,#(RES_TEXT_LOG_COLUMNS - 1)
ansi_cha_clamped:
	ld (RES_text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

ansi_vpa:
	call ansi_param0_default_1	; A = row (1-based)
	dec a
	cp #RES_TEXT_ROWS
	jr c,ansi_vpa_clamped
	ld a,#(RES_TEXT_ROWS - 1)
ansi_vpa_clamped:
	ld (RES_text_row),a
	call v9958_cursor_set_position_current
	ret


; ---- CSI CUP: cursor position (row;col H  or  row;col f) ----

ansi_cup:
	call ansi_param0_default_1	; A = row (1-based)
	dec a
	cp #RES_TEXT_ROWS
	jr c,ansi_cup_row_clamped
	ld a,#(RES_TEXT_ROWS - 1)
ansi_cup_row_clamped:
	ld (RES_text_row),a

	call ansi_param1_default_1	; A = col (1-based)
	dec a
	cp #RES_TEXT_LOG_COLUMNS
	jr c,ansi_cup_col_clamped
	ld a,#(RES_TEXT_LOG_COLUMNS - 1)
ansi_cup_col_clamped:
	ld (RES_text_col),a

	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret


; ---- CSI ED: erase in display ----

ansi_ed:
	; param0 == 0 or missing: clear from cursor to end of screen.
	; param0 == 1: clear from start of screen through cursor.
	; param0 == 2: clear whole screen. This implementation homes the cursor
	; for CP/M full-screen program compatibility.
	ld a,(RES_csi_param_count)
	or a
	jr z,ansi_ed_to_eos

	ld a,(RES_csi_param0)
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
	ld a,(RES_csi_param_count)
	or a
	jr z,ansi_el_to_eol		; default: clear to EOL

	ld a,(RES_csi_param0)
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
	ld a,(RES_text_col)
	ld d,a
	ld a,#RES_TEXT_LOG_COLUMNS
	sub d
	ret z
	cp e
	jr nc,ansi_ech_count_ok
	ld e,a
ansi_ech_count_ok:
	call v9958_flush_print_run
	ld b,e				; width in cells
	ld c,#0x01			; one row
	ld a,(RES_text_col)
	ld d,a
	ld a,(RES_text_row)
	ld e,a
	jp v9958_fill_cells


; ---- CSI SGR: select graphic rendition ----

ansi_sgr:
	call v9958_flush_print_run
	; Consume SGR.  Track reverse video in RES_current_attr.
	; 0=reset, 7=reverse on, 27=reverse off. Other font/color
	; parameters are consumed unless they affect the currently supported state.
	ld a,(RES_csi_param_count)
	or a
	jr z,ansi_sgr_reset
	ld a,(RES_csi_param0)
	call ansi_sgr_apply_param
	ld a,(RES_csi_param_count)
	cp #2
	ret c
	ld a,(RES_csi_param1)
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
	ld (RES_current_attr),a
	ret
ansi_sgr_rev_on:
	ld a,#0x01
	ld (RES_current_attr),a
	ret
ansi_sgr_rev_off:
	xor a
	ld (RES_current_attr),a
	ret


; ---- ANSI save/restore cursor (ESC 7/8 and CSI s/u) ----

ansi_save_cursor:
	ld a,(RES_text_col)
	ld (RES_text_cursor_saved_col),a
	ld a,(RES_text_row)
	ld (RES_text_cursor_saved_row),a
	ld a,(RES_current_attr)
	ld (RES_text_attr_saved),a
	ret

ansi_restore_cursor:
	ld a,(RES_text_cursor_saved_col)
	ld (RES_text_col),a
	ld a,(RES_text_cursor_saved_row)
	ld (RES_text_row),a
	ld a,(RES_text_attr_saved)
	ld (RES_current_attr),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret


; ---- DEC private modes (ESC [ ? ... h/l) ----

ansi_decset:
	ld a,(RES_csi_param_count)
	or a
	ret z
	ld a,(RES_csi_param0)
	cp #7
	jr z,ansi_decawm_on
	cp #25
	jr z,ansi_show_cursor
	ret		; other DEC private — consume

ansi_show_cursor:
	jp v9958_cursor_show

ansi_decrst:
	ld a,(RES_csi_param_count)
	or a
	ret z
	ld a,(RES_csi_param0)
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
	ld (RES_term_auto_wrap),a
	ret


; ---- CSI IL: insert n blank lines (ESC [ n L) ----
;
; Inputs:
;   CSI param0 = n (default/0 -> 1)
;   RES_text_row = current cursor row
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
;   Full screen (rows 0..RES_TEXT_ROWS-1); no per-command scroll region yet.

ansi_insert_lines:
	call ansi_param0_default_1
	ld e,a
	ld a,#RES_TEXT_ROWS
	ld d,a
	ld a,(RES_text_row)
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
	ld a,#RES_TEXT_ROWS
	ld d,a
	ld a,(RES_text_row)
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
	ld a,(RES_text_col)
	cp #(RES_TEXT_LOG_COLUMNS - 1)
	jr nz,text_put_printable_advance
	call v9958_flush_print_run
	call text_advance_cursor
	call v9958_cursor_write_sat
	jp RES_v9958_present
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
	ld (RES_text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_lf:
	; Line feed — move down one row, preserving column.
	ld a,(RES_text_col)
	push af
	call text_newline
	pop af
	ld (RES_text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_nel:
	; Next line — CR + LF.
	xor a
	ld (RES_text_col),a
	call text_newline
	call v9958_cursor_set_position_current
	ret

term_reverse_index:
	; Reverse index — move up one row. Region scroll-down is deferred.
	ld a,(RES_text_row)
	or a
	ret z
	dec a
	ld (RES_text_row),a
	call v9958_cursor_set_position_current
	ret

term_backspace:
	ld a,(RES_text_col)
	or a
	ret z

	dec a
	ld (RES_text_col),a

	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_tab:
	; Advance to next 8-column tab stop (VT100 standard).
	call text_advance_cursor
	ld a,(RES_text_col)
	and #0x07
	jr nz,term_tab

	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_up:
	ld a,(RES_text_row)
	or a
	ret z

	dec a
	ld (RES_text_row),a
	call v9958_cursor_set_position_current
	ret

term_cursor_down:
	ld a,(RES_text_row)
	cp #(RES_TEXT_ROWS - 1)
	ret nc

	inc a
	ld (RES_text_row),a
	call v9958_cursor_set_position_current
	ret

term_cursor_left:
	ld a,(RES_text_col)
	or a
	ret z

	dec a
	ld (RES_text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_right:
	ld a,(RES_text_col)
	cp #(RES_TEXT_LOG_COLUMNS - 1)
	ret nc

	inc a
	ld (RES_text_col),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_home:
	xor a
	ld (RES_text_col),a
	ld (RES_text_row),a
	call text_ensure_cursor_visible
	call v9958_cursor_set_position_current
	ret

term_cursor_end:
	ld a,#(RES_TEXT_LOG_COLUMNS - 1)
	ld (RES_text_col),a
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
	ld (RES_text_col),a
	ld (RES_text_row),a
	jp v9958_cursor_set_position_current

; ---------------------------------------------------------------------------
; text_clear_from_cursor_to_eos — ED 0: cursor through end of screen.
; Cursor position is restored after the erase.
; ---------------------------------------------------------------------------
text_clear_from_cursor_to_eos:
	ld a,(RES_text_col)
	ld (RES_ansi_tmp_col),a
	ld a,(RES_text_row)
	ld (RES_ansi_tmp_row),a

	call text_clear_to_eol

	ld a,(RES_ansi_tmp_row)
	inc a
	cp #RES_TEXT_ROWS
	jr nc,text_clear_eos_restore

text_clear_eos_row_loop:
	ld (RES_text_row),a
	xor a
	ld (RES_text_col),a
	call text_clear_to_eol
	ld a,(RES_text_row)
	inc a
	cp #RES_TEXT_ROWS
	jr c,text_clear_eos_row_loop

text_clear_eos_restore:
	ld a,(RES_ansi_tmp_col)
	ld (RES_text_col),a
	ld a,(RES_ansi_tmp_row)
	ld (RES_text_row),a
	call v9958_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_from_start_to_cursor — ED 1: screen start through cursor.
; Cursor position is restored after the erase.
; ---------------------------------------------------------------------------
text_clear_from_start_to_cursor:
	ld a,(RES_text_col)
	ld (RES_ansi_tmp_col),a
	ld a,(RES_text_row)
	ld (RES_ansi_tmp_row),a
	or a
	jr z,text_clear_stc_current_row

	ld b,a
	xor a
	ld (RES_text_row),a

text_clear_stc_row_loop:
	xor a
	ld (RES_text_col),a
	push bc
	call text_clear_line
	pop bc
	ld a,(RES_text_row)
	inc a
	ld (RES_text_row),a
	djnz text_clear_stc_row_loop

text_clear_stc_current_row:
	ld a,(RES_ansi_tmp_row)
	ld (RES_text_row),a
	ld a,(RES_ansi_tmp_col)
	ld (RES_text_col),a
	call text_clear_from_sol_to_cursor
	call v9958_cursor_set_position_current
	ret


; ---------------------------------------------------------------------------
; text_clear_to_eol — clear from cursor to end of logical line (ESC [ K)
; ---------------------------------------------------------------------------

text_clear_to_eol:
	call v9958_flush_print_run
	ld a,(RES_text_col)
	ld d,a
	ld b,#RES_TEXT_LOG_COLUMNS
	sub b				; A = col - columns
	neg				; A = columns - col
	ld b,a
	ld a,(RES_text_row)
	ld e,a
	ld c,#0x01
	jp v9958_fill_cells



; ---------------------------------------------------------------------------
; text_clear_line — clear entire current logical line (ESC [ 2 K)
; ---------------------------------------------------------------------------

text_clear_line:
	; Save current cursor column.
	ld a,(RES_text_col)
	push af

	; Move to column 0 on same row and clear to EOL.
	xor a
	ld (RES_text_col),a
	call text_clear_to_eol

	; Restore cursor column.
	pop af
	ld (RES_text_col),a
	ret


; ---------------------------------------------------------------------------
; text_clear_from_sol_to_cursor — EL 1: start of line through cursor.
; Cursor position unchanged.  Uses block write.
; ---------------------------------------------------------------------------
text_clear_from_sol_to_cursor:
	call v9958_flush_print_run
	ld d,#0x00
	ld a,(RES_text_row)
	ld e,a
	ld a,(RES_text_col)
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
	ld a,(RES_text_col)
	inc a
	cp #RES_TEXT_LOG_COLUMNS
	jr c,text_advance_store_col

	ld a,(RES_term_auto_wrap)
	or a
	ld a,#RES_TEXT_LOG_COLUMNS
	jr nz,text_advance_do_wrap
	dec a
	jr text_advance_store_col

text_advance_do_wrap:
	xor a
	ld (RES_text_col),a
	jr text_newline_from_wrap


text_newline:
	call v9958_flush_print_run
	xor a
	ld (RES_text_col),a

text_newline_from_wrap:
	ld a,(RES_text_row)
	inc a
	cp #RES_TEXT_ROWS
	jr c,text_newline_store_row

	; Bottom of screen — scroll up.
	call text_scroll_up
	ret

text_newline_store_row:
	ld (RES_text_row),a
	ret

text_advance_store_col:
	ld (RES_text_col),a
	ret

text_ensure_cursor_visible:
	ret

text_scroll_up:
	call v9958_flush_print_run
	call v9958_scroll_up_one
	xor a
	ld (RES_text_col),a
	ld a,#RES_TEXT_SCROLL_BOTTOM
	ld (RES_text_row),a
	jp v9958_cursor_set_position_current

; Service entry: the gate passes BC through, so the byte arrives in C.
romsvc_console_byte:
	ld a,c
	jp term_process_byte
