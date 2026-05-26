; Zephyr-80 monitor application for the CP/M/BIOS ROM image.
;
; This assembles the existing monitor command shell as a TPA-style program at
; 0100h. The resident BIOS enters it after platform setup.

	.module zephyr80_monitor_app
	.area MONAPP (ABS)

	.include "ascii.inc"
	.include "workspace.inc"
	.include "constants.inc"

	.org 0x0100
monitor_tpa_start:
	ld (MONITOR_EXIT_SP),sp
	ld sp,(MONITOR_STACK_TOP)
	xor a
	ld (EOL_CR_FLAG),a
	ld (HISTORY_LEN),a
	call wait_for_first_enter
	ld hl,#msg_banner
	call sio_puts

monitor_loop:
	ld hl,#msg_prompt
	call sio_puts
	call sio_getline
	call sio_save_line_history
	call save_monitor_context

	ld hl,#LINE_BUF
	call skip_spaces
	ld a,(hl)
	or a
	jr z,monitor_loop
	call to_upper_a
	inc hl
	cp #0x52		; R
	jp z,cmd_registers
	cp #0x44		; D
	jp z,cmd_droute
	cp #0x4d		; M
	jp z,cmd_memory_set
	cp #0x49		; I
	jp z,cmd_port_in
	cp #0x4f		; O
	jp z,cmd_port_out
	cp #0x41		; A
	jp z,cmd_app
	cp #0x4c		; L
	jp z,cmd_load_hex
	cp #0x47		; G
	jp z,cmd_go
	cp #0x58		; X
	jp z,cmd_hex_dump
	cp #0x51		; Q
	jp z,cmd_quit
	cp #0x48		; H
	jp z,cmd_help
	cp #0x3f		; ?
	jp z,cmd_help
	jp cmd_error_command

	.include "sio_console.inc"
	.include "context.inc"
	.include "commands.inc"
	.include "ihex_emit.inc"
	.include "ihex_load.inc"
	.include "memory_dump.inc"
	.include "parse.inc"
	.include "print.inc"
	.include "errors.inc"
	.include "messages.inc"
