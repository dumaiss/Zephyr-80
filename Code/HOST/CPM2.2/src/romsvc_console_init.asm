; Zephyr-80 console init and reset, on ROM page 4.
;
; Phase 3 slice 2.  Moved verbatim from cbios_console_v9958.asm: the display
; reset, the G6 mode bring-up, the paced palette upload, the hardware-wait and
; porch sequencing, the cursor sprite setup, and the four constant tables they
; read.
;
; Why these and not others: every one of them is reachable only from
; v9958_console_init_common or v9958_reset_display.  The call graph was checked
; rather than assumed, and it found exactly one routine in the middle of the
; block that had to stay behind -- RES_v9958_write_register, which the per-character
; path reaches through v9958_start_command and v9958_write_vram_small.  It is
; called from here at its resident address.
;
; Everything named RES_* is still in RAM, at an address generated from the
; firmware listing by tools/gen_romsvc_bios.py.  The console occupies the common
; window, so those calls and reads work unchanged while ROM is mapped low.
;

; NOTE on the one rewritten call.  v9958_reset_display calls the atlas builder,
; and in RAM that name is now a stub that enters the gate.  Calling it from here
; would be a SECOND gate entry inside the first: the gate keeps the caller's SP,
; the saved latch and the saved interrupt state in single slots, so the inner
; call would overwrite the outer one's return path and the machine would come
; back with the wrong memory map.  The call goes straight to romsvc_upload_atlas
; on this page instead, which is also one fewer map switch.
;
; The gate is not reentrant.  Any service that wants another service calls it
; directly, here, rather than through its resident entry point.

; Interrupts: the gate's vector-page rule applies.  These are slow services --
; the palette upload is deliberately paced -- and they run at boot and on ESC-c,
; not per character.

v9958_reset_display:
	xor a
	ld (RES_esc_press_count),a
	ld (RES_term_state),a
	ld (RES_csi_param0),a
	ld (RES_csi_param1),a
	ld (RES_csi_param_count),a
	ld (RES_csi_accum),a
	ld (RES_csi_have_digit),a
	ld (RES_csi_private_flag),a
	ld (RES_current_attr),a
	ld (RES_text_attr_saved),a

	ld a,#0x01
	ld (RES_term_auto_wrap),a		; auto-wrap re-enabled on RIS

	call v9958_init_g6
	call v9958_enable_hardware_wait
	call v9958_init_palette_paced
	call romsvc_upload_atlas
	call v9958_clear_screen

	xor a
	ld (RES_text_col),a
	ld (RES_text_row),a
	ld (RES_print_run_count),a
	ld a,#0x01
	ld (RES_cursor_visible),a
	call v9958_cursor_init
	call RES_v9958_present
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
	ld b,#RES_V9958_BOOT_DELAY_COUNT
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
	ld a,(RES_v9958_config_shadow)
	and #V9958_CONFIG_INT_ROUTE
	or #V9958_CONFIG_PORCH_OFF
	ld (RES_v9958_config_shadow),a
	out (V9958_CONFIG_PORT),a
	jp v9958_bootstrap_delay

v9958_porch_on:
	ld a,(RES_v9958_config_shadow)
	and #V9958_CONFIG_INT_ROUTE
	ld (RES_v9958_config_shadow),a
	out (V9958_CONFIG_PORT),a
	ret

; Establish the non-negotiable hardware state before any accelerated access.
; The display stays off until the bitmap, atlases, and cursor are initialized.
v9958_init_g6:
	call v9958_porch_off
	xor a
	ld (RES_v9958_scroll_origin),a	; physical start of logical row zero

	ld a,#RES_V9958_R25_WAIT_OFF	; WTE=0, VDS=0
	ld b,#25
	call v9958_write_register_paced

	ld a,#RES_V9958_R8_64K_DRAM	; VR=1 for installed 64Kx4 DRAMs
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
	ld a,#RES_V9958_R23_TEXT_BASE
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
	ld a,#RES_V9958_R25_WAIT_ON
	ld b,#25
	call v9958_write_register_paced
	jp v9958_porch_on

v9958_enable_display:
	ld a,#RES_V9958_R1_DISPLAY_ON
	ld b,#1
	jp RES_v9958_write_register

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

cursor_pattern:
	.db 0xe0,0xe0,0xe0,0xe0,0xe0,0xe0,0xe0,0xe0
cursor_colors:
	.db RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR
	.db RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR
	.db RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR
	.db RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR,RES_V9958_CURSOR_COLOR

v9958_g6_registers:
	.db 0x0a			; R#0: G6 mode select
	.db RES_V9958_R1_DISPLAY_OFF	; R#1: display disabled during initialization
	.db 0x1f			; R#2: physical G6 page-zero baseline
	.db 0x00			; R#3
	.db 0x00			; R#4
	.db 0xe4			; R#5/R#11 -> color 1F000h, SAT 1F200h
	.db 0x3f			; R#6: sprite pattern table
	.db 0x04			; R#7: text/background color baseline
	.db RES_V9958_R8_64K_DRAM	; R#8: VR=1, 64Kx4 DRAMs
	.db 0x88			; R#9: PAL + 212-line mode
	.db 0x00			; R#10
	.db 0x03			; R#11

v9958_console_palette:
	.db 0x00,0x00, 0x11,0x01, 0x00,0x06, 0x00,0x07
	.db 0x05,0x00, 0x07,0x03, 0x50,0x00, 0x06,0x06
	.db 0x70,0x00, 0x73,0x03, 0x70,0x07, 0x74,0x07
	.db 0x00,0x05, 0x67,0x00, 0x55,0x05, 0x77,0x07

; ---------------------------------------------------------------------------
; ROMSVC_DISPLAY_INIT -- the display half of console init.
;
; Lifted whole out of v9958_console_init_common, which keeps the state clearing
; and now crosses the gate once for this.  The ordering is the porch/WTE/VR
; sequence from the hardware bring-up notes and is not to be rearranged.
;
; Every call here is direct: to a routine on this page, or to a resident one at
; its generated address.  None of them go through a resident gate stub, because
; the gate is not reentrant.
; ---------------------------------------------------------------------------
romsvc_display_init:
	call v9958_init_g6
	call v9958_enable_hardware_wait
	call v9958_init_palette_paced
	call romsvc_upload_atlas
	call v9958_clear_screen
	call v9958_cursor_init
	call RES_v9958_present
	jp v9958_enable_display
