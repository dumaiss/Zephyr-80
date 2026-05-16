; Zephyr-80 first ROM monitor
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Overview:
; - The ROM image starts at 0000h and enters at start after reset.
; - The monitor is a polling command loop. It never enables interrupts.
; - Z80 SIO channel B is the console. All input and output routines below the
;   dispatcher wait on SIO RR0 status bits before touching the data port.
; - Commands are single-letter dispatches from LINE_BUF. Argument parsing and
;   command actions live in the included modules; every command returns by
;   jumping back to monitor_loop or one of the shared error exits.
;
; Hardware assumptions:
; - ROM entry point is 0000h.
; - Z80 SIO channel B is the monitor console.
; - A0 is wired to SIO C/D and A1 is wired to SIO B/A:
;     20h = SIO A data, 21h = SIO A control
;     22h = SIO B data, 23h = SIO B control
; - SIO clock is 1.8432 MHz, using x16 async clocking for 115200 8N1.
; - SIO WR3 auto-enables are disabled. FT230-style USB serial wiring may not
;   provide the modem-control input needed for auto-enable receive gating.
; - No interrupts are used. All console I/O is polling.
;
; Memory map with ROM_DIS=0, RAM_SHADOW=0, CART_DETECT=0, PROG=0:
; - 0000h-5FFFh: reads select ROM, writes select SRAM.
;   Do not use this range for stack, variables, buffers, or loader output.
; - 6000h-FFFFh: SRAM reads and writes.
; Monitor workspace is fixed in upper RAM around F000h-FEFFh.

	.module zephyr80_monitor
	.area CODE (ABS)
	.org 0

	.include "constants.inc"
	.include "workspace.inc"
	.include "ascii.inc"

start:
	; Reset-time setup is deliberately minimal: keep interrupts disabled, move
	; the stack into high RAM, initialize the polled console, and clear the
	; CR/LF tracking flag before accepting operator input.
	di
	ld sp,#STACK_TOP
	call sio_init
	xor a
	ld (EOL_CR_FLAG),a

	; Wait for the first Enter before printing the banner. This lets a terminal
	; connect or finish sending its opening line ending without losing the first
	; visible monitor prompt to a pending LF.
	call wait_for_first_enter
	ld hl,#msg_banner
	call sio_puts

monitor_loop:
	; Prompt, read one edited command line into LINE_BUF, then snapshot the
	; monitor's own register state for the R command. This is intentionally
	; after input because sio_getline and parsing helpers clobber registers.
	ld hl,#msg_prompt
	call sio_puts
	call sio_getline
	call save_monitor_context

	; Commands are selected by the first non-space character. Empty lines simply
	; redisplay the prompt. The command byte is folded to uppercase so lowercase
	; command letters take the same paths.
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
	jp z,cmd_dump
	cp #0x4d		; M
	jp z,cmd_memory_set
	cp #0x49		; I
	jp z,cmd_port_in
	cp #0x4f		; O
	jp z,cmd_port_out
	cp #0x4c		; L
	jp z,cmd_load_hex
	cp #0x47		; G
	jp z,cmd_go
	cp #0x58		; X
	jp z,cmd_hex_dump
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
