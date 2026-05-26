; Fixed Zephyr-80 monitor workspace addresses in the CP/M application bank.
;
; These symbols name absolute RAM locations; they do not allocate storage in
; the assembled image. Keep this layout stable because command handlers,
; loader state, and dump/export state share this workspace while Monitor runs
; from the TPA at 0100h.

; Console line input buffer. sio_getline writes a NUL-terminated command here.
LINE_MAX		= 80
VARIABLES_BASE  = 0xB000
LINE_BUF		= VARIABLES_BASE

; Single-entry command history used by the console line editor.
HISTORY_BUF		= VARIABLES_BASE + 0x50

; Intel HEX loader data buffer. One parsed record is staged here until its
; checksum and destination range have been validated.
HEX_BUF			= VARIABLES_BASE + 0x0100

; Saved monitor register snapshot used by the R command. This is the monitor's
; working state after command input, not an interrupt or exception frame.
REG_AF_SAVE		= VARIABLES_BASE + 0x0200
REG_BC_SAVE		= VARIABLES_BASE + 0x0202
REG_DE_SAVE		= VARIABLES_BASE + 0x0204
REG_HL_SAVE		= VARIABLES_BASE + 0x0206
REG_IX_SAVE		= VARIABLES_BASE + 0x0208
REG_IY_SAVE		= VARIABLES_BASE + 0x020a
REG_SP_SAVE		= VARIABLES_BASE + 0x020c

; Memory dump state. DUMP_ADDR and DUMP_LEN are user arguments; the line fields
; hold the current 16-byte row address and byte count.
DUMP_ADDR		= VARIABLES_BASE + 0x0210
DUMP_LEN		= VARIABLES_BASE + 0x0212
DUMP_LINE_ADDR	= VARIABLES_BASE + 0x0214
DUMP_LINE_COUNT	= VARIABLES_BASE + 0x0216
DBANK_NUM		= VARIABLES_BASE + 0x0217

; Scratch values shared by command handlers. EOL_CR_FLAG remembers that a CR
; was consumed so a following LF from CRLF input can be ignored.
TEMP_WORD		= VARIABLES_BASE + 0x0220
TEMP_BYTE		= VARIABLES_BASE + 0x0222
EOL_CR_FLAG		= VARIABLES_BASE + 0x0223
HISTORY_LEN		= VARIABLES_BASE + 0x0224

; Intel HEX loader record state: byte count, record type, checksum accumulator,
; and 16-bit target address.
HEX_COUNT		= VARIABLES_BASE + 0x0230
HEX_TYPE		= VARIABLES_BASE + 0x0231
HEX_SUM			= VARIABLES_BASE + 0x0232
HEX_ADDR		= VARIABLES_BASE + 0x0234

; Intel HEX export state for the X command. X_REC_LEN is the current record
; chunk size, and X_SUM accumulates the checksum for that record.
X_ADDR			= VARIABLES_BASE + 0x0240
X_LEN			= VARIABLES_BASE + 0x0242
X_REC_LEN		= VARIABLES_BASE + 0x0244
X_SUM			= VARIABLES_BASE + 0x0245

; Bank dump staging buffer. DB copies one formatted row from a source bank into
; the monitor bank before reusing the normal dump line formatter.
DBUF			= VARIABLES_BASE + 0x0260

MONITOR_EXIT_SP = VARIABLES_BASE + 0x035F
MONITOR_STACK_TOP = 0xBFFF
