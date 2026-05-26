; Local Zephyr-80 CP/M console BIOS facade.
;
; CP/M entry labels stay stable while the active console backend is selected
; through a small driver table. The default backend is SIO channel B.
;
; Driver table contract, seven 16-bit little-endian entries:
;   +00 const   -> A = FFh if input is available, A = 00h otherwise
;   +02 conin   -> blocking input, returns character in A
;   +04 conout  -> blocking output of character in C
;   +06 list    -> list/printer output of C, or no-op
;   +08 punch   -> punch output of C, or no-op
;   +0A reader  -> reader input, A = character or CP/M EOF
;   +0C listst  -> A = FFh if list device ready, A = 00h otherwise
;
; The facade preserves DE and HL around the indirect call. Backend routines
; follow the CP/M register conventions for their specific entry points.

	.globl const,conin,conout,list,punch,reader,listst
	.globl console_init,console_set_driver
	.globl sio_console_driver,sio_console_init
	.globl CONSOLE_CODE_START,CONSOLE_CODE_END
	.globl CONSOLE_STATE_START,CONSOLE_STATE_END
	.globl CONSOLE_DRIVER

	.area CODE (ABS)
	.org CBIOS_CONSOLE_CODE_BASE

CONSOLE_CODE_START:

; Initialize the default console backend.
; Purpose:
;   Install the legacy SIO console table and clear its backend state.
; Inputs: none.
; Outputs: CONSOLE_DRIVER points at sio_console_driver.
; Clobbers: AF, HL.
console_init:
	ld hl,#sio_console_driver
	ld (CONSOLE_DRIVER),hl
	jp sio_console_init

; Install a different console driver table.
; Purpose:
;   Swap the CP/M console facade to another backend without changing the CP/M
;   BIOS jump table.
; Input:
;   HL = table containing const, conin, conout, list, punch, reader, listst.
; Output:
;   CONSOLE_DRIVER updated.
; Clobbers: none.
console_set_driver:
	ld (CONSOLE_DRIVER),hl
	ret

const:
	ld a,#0x00
	jr CONSOLE_DISPATCH

conin:
	ld a,#0x02
	jr CONSOLE_DISPATCH

conout:
	ld a,#0x04
	jr CONSOLE_DISPATCH

list:
	ld a,#0x06
	jr CONSOLE_DISPATCH

punch:
	ld a,#0x08
	jr CONSOLE_DISPATCH

reader:
	ld a,#0x0a
	jr CONSOLE_DISPATCH

listst:
	ld a,#0x0c

CONSOLE_DISPATCH:
	; A contains a byte offset into the active driver table. Fetch the function
	; pointer, call it through a tiny return shim, then restore facade registers.
	push de
	push hl
	ld e,a
	ld d,#0x00
	ld hl,(CONSOLE_DRIVER)
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call CONSOLE_CALL_HL
	pop hl
	pop de
	ret

CONSOLE_CALL_HL:
	ld de,#CONSOLE_CALL_RETURN
	push de
	jp (hl)
CONSOLE_CALL_RETURN:
	ret

CONSOLE_CODE_END:

	.area WORK (ABS)
	.org CBIOS_CONSOLE_WORK_AREA
CONSOLE_STATE_START:
CONSOLE_DRIVER:
	.dw sio_console_driver

CONSOLE_STATE_END:

	.area CODE (ABS)
