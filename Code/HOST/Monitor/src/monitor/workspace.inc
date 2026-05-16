; Fixed Zephyr-80 monitor workspace addresses in upper RAM.
;
; These symbols name absolute RAM locations; they do not allocate storage in
; the assembled ROM image. Keep this layout stable because command handlers,
; loader state, and dump/export state share the F000h-FEFFh monitor workspace.

; Console line input buffer. sio_getline writes a NUL-terminated command here.
LINE_BUF		= 0xf000
LINE_MAX		= 80

; Intel HEX loader data buffer. One parsed record is staged here until its
; checksum and destination range have been validated.
HEX_BUF			= 0xf100

; Saved monitor register snapshot used by the R command. This is the monitor's
; working state after command input, not an interrupt or exception frame.
REG_AF_SAVE		= 0xf200
REG_BC_SAVE		= 0xf202
REG_DE_SAVE		= 0xf204
REG_HL_SAVE		= 0xf206
REG_IX_SAVE		= 0xf208
REG_IY_SAVE		= 0xf20a
REG_SP_SAVE		= 0xf20c

; Memory dump state. DUMP_ADDR and DUMP_LEN are user arguments; the line fields
; hold the current 16-byte row address and byte count.
DUMP_ADDR		= 0xf210
DUMP_LEN		= 0xf212
DUMP_LINE_ADDR		= 0xf214
DUMP_LINE_COUNT		= 0xf216

; Scratch values shared by command handlers. EOL_CR_FLAG remembers that a CR
; was consumed so a following LF from CRLF input can be ignored.
TEMP_WORD		= 0xf220
TEMP_BYTE		= 0xf222
EOL_CR_FLAG		= 0xf223

; Intel HEX loader record state: byte count, record type, checksum accumulator,
; and 16-bit target address.
HEX_COUNT		= 0xf230
HEX_TYPE		= 0xf231
HEX_SUM			= 0xf232
HEX_ADDR		= 0xf234

; Intel HEX export state for the X command. X_REC_LEN is the current record
; chunk size, and X_SUM accumulates the checksum for that record.
X_ADDR			= 0xf240
X_LEN			= 0xf242
X_REC_LEN		= 0xf244
X_SUM			= 0xf245
