; Shared command error exits.
;
; Command handlers jump here for common failures. Each routine prints one
; NUL-terminated message and then returns to the dispatcher by jumping to
; monitor_loop. They do not attempt to recover parser state.

; Unknown command letter.
cmd_error_command:
	ld hl,#msg_err_command
	call sio_puts
	jp monitor_loop

; Missing, malformed, oversized, or otherwise invalid command argument.
cmd_error_args:
	ld hl,#msg_err_args
	call sio_puts
	jp monitor_loop

; Requested write targets the ROM-read window below RAM_SAFE_BASE.
cmd_error_rom_region:
	ld hl,#msg_err_rom_region
	call sio_puts
	jp monitor_loop
