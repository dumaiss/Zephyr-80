; NUL-terminated monitor output strings.
;
; Keep these bytes stable: command output is part of the monitor's external
; behavior. All strings are emitted by sio_puts and therefore end with 00h.

; Banner and prompt.
msg_banner:
	.db CR,LF
	.ascii /Zephyr-80 Monitor/
	.db CR,LF,0
msg_prompt:
	.ascii /Z80> /
	.db 0

; General status messages.
msg_ok:
	.ascii /OK/
	.db CR,LF,0

; Register command labels.
msg_regs_header:
	.ascii /Monitor register snapshot/
	.db CR,LF,0
msg_af:
	.ascii /AF:/
	.db 0
msg_bc:
	.ascii /BC:/
	.db 0
msg_de:
	.ascii /DE:/
	.db 0
msg_hl:
	.ascii /HL:/
	.db 0
msg_ix:
	.ascii /IX:/
	.db 0
msg_iy:
	.ascii /IY:/
	.db 0
msg_sp:
	.ascii /SP:/
	.db 0
msg_pc_na:
	.ascii /  PC:NA/
	.db CR,LF,0

; Command-specific output labels and fixed Intel HEX EOF text.
msg_in_value:
	.ascii /IN=/
	.db 0
msg_go:
	.ascii /GO/
	.db CR,LF,0
msg_ihex_eof:
	.ascii /:00000001FF/
	.db CR,LF,0
msg_load_start:
	.ascii /Intel HEX receive/
	.db CR,LF,0
msg_load_ok:
	.ascii /LOAD OK/
	.db CR,LF,0

; Errors.
msg_err_command:
	.ascii /ERR: COMMAND/
	.db CR,LF,0
msg_err_args:
	.ascii /ERR: ARG/
	.db CR,LF,0
msg_err_hex_parse:
	.ascii /ERR: HEX PARSE/
	.db CR,LF,0
msg_err_checksum:
	.ascii /ERR: CHECKSUM/
	.db CR,LF,0
msg_err_record_type:
	.ascii /ERR: RECORD TYPE/
	.db CR,LF,0

; Help text.
msg_help:
	.ascii /R             registers/
	.db CR,LF
	.ascii /D addr len    dump memory/
	.db CR,LF
	.ascii /M addr value  set memory byte/
	.db CR,LF
	.ascii /I port        input port/
	.db CR,LF
	.ascii /O port value  output port/
	.db CR,LF
	.ascii /L             load Intel HEX/
	.db CR,LF
	.ascii /G addr        call code/
	.db CR,LF
	.ascii /X addr len    export Intel HEX/
	.db CR,LF
	.ascii /H or ?        help/
	.db CR,LF,0
