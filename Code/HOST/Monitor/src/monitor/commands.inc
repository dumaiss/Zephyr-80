; Monitor command entry handlers and command-level dispatch targets.
;
; Each handler enters with HL pointing just after the command letter in LINE_BUF.
; Argument parsers skip leading spaces and report errors with carry set. On
; success, handlers perform the requested action and jump back to monitor_loop;
; malformed input jumps to a shared command error exit.

; R
; Print the monitor register snapshot saved after the current command line was
; read. This is monitor state, not user-program state, so PC is printed as NA.
cmd_registers:
	ld hl,#msg_regs_header
	call sio_puts
	ld hl,#msg_af
	call sio_puts
	ld hl,(REG_AF_SAVE)
	call print_hex_word
	call print_two_spaces
	ld hl,#msg_bc
	call sio_puts
	ld hl,(REG_BC_SAVE)
	call print_hex_word
	call print_crlf

	ld hl,#msg_de
	call sio_puts
	ld hl,(REG_DE_SAVE)
	call print_hex_word
	call print_two_spaces
	ld hl,#msg_hl
	call sio_puts
	ld hl,(REG_HL_SAVE)
	call print_hex_word
	call print_crlf

	ld hl,#msg_ix
	call sio_puts
	ld hl,(REG_IX_SAVE)
	call print_hex_word
	call print_two_spaces
	ld hl,#msg_iy
	call sio_puts
	ld hl,(REG_IY_SAVE)
	call print_hex_word
	call print_crlf

	ld hl,#msg_sp
	call sio_puts
	ld hl,(REG_SP_SAVE)
	call print_hex_word
	ld hl,#msg_pc_na
	call sio_puts
	jp monitor_loop

; D addr len
; Parse a start address and byte count, then call dump_memory to emit 16-byte
; rows. Bad arguments print ERR: ARG.
cmd_dump:
	call parse_hex_word
	jp c,cmd_error_args
	ld (DUMP_ADDR),de
	call parse_hex_word
	jp c,cmd_error_args
	ld (DUMP_LEN),de
	call dump_memory
	jp monitor_loop

; M addr value
; Parse an address and byte value, store the byte, and report OK. The monitor
; disables ROM during startup, so formerly ROM-visible addresses now read and
; write SRAM.
cmd_memory_set:
	call parse_hex_word
	jp c,cmd_error_args
	ld (TEMP_WORD),de
	call parse_hex_byte
	jp c,cmd_error_args
	ld (TEMP_BYTE),a
	ld hl,(TEMP_WORD)
	ld a,(TEMP_BYTE)
	ld (hl),a
	ld hl,#msg_ok
	call sio_puts
	jp monitor_loop

; I port
; Parse an 8-bit port number, read it through C, and print the byte as hex.
; Z80 IN A,(C) drives the full I/O address as B:C, so B must be zero for the
; monitor's 8-bit port syntax to access port 00pp rather than xxpp.
cmd_port_in:
	call parse_hex_byte
	jp c,cmd_error_args
	ld c,a
	ld b,#0x00
	in a,(c)
	ld (TEMP_BYTE),a
	ld hl,#msg_in_value
	call sio_puts
	ld a,(TEMP_BYTE)
	call print_hex_byte
	call print_crlf
	jp monitor_loop

; O port value
; Parse an 8-bit port number and byte value, then write the value to that port.
; Z80 OUT (C),A also drives the full I/O address as B:C. Keep the value out of
; B and clear B immediately before the output so all monitor ports are 00pp.
cmd_port_out:
	call parse_hex_byte
	jp c,cmd_error_args
	ld (TEMP_BYTE),a
	call parse_hex_byte
	jp c,cmd_error_args
	ld (TEMP_WORD),a
	ld a,(TEMP_BYTE)
	ld c,a
	ld b,#0x00
	ld a,(TEMP_WORD)
	out (c),a
	ld hl,#msg_ok
	call sio_puts
	jp monitor_loop

; G addr
; Parse a 16-bit address and transfer control to it. The monitor pushes
; go_return first, so user code can return with RET to resume monitor_loop.
; Register preservation is intentionally left to the called code.
cmd_go:
	call parse_hex_word
	jp c,cmd_error_args
	ld (TEMP_WORD),de
	ld hl,#msg_go
	call sio_puts
	ld hl,#go_return
	push hl
	ld hl,(TEMP_WORD)
	jp (hl)

go_return:
	jp monitor_loop

; X addr len
; Parse a start address and byte count, reject zero-length exports and address
; ranges that wrap past FFFFh, then emit Intel HEX records for the range.
cmd_hex_dump:
	call parse_hex_word
	jp c,cmd_error_args
	ld (X_ADDR),de
	call parse_hex_word
	jp c,cmd_error_args
	ld (X_LEN),de

	; Reject zero length.
	ld a,d
	or e
	jp z,cmd_error_args

	; Reject ranges where addr + len - 1 carries past FFFFh.
	ld hl,(X_ADDR)
	dec de
	add hl,de
	jp c,cmd_error_args

	call emit_ihex_range
	jp monitor_loop

; H or ?
; Print the static command help text.
cmd_help:
	ld hl,#msg_help
	call sio_puts
	jp monitor_loop
