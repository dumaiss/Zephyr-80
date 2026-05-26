; Local Zephyr-80 CP/M console BIOS facade.
;
; CP/M entry labels stay stable while the active console backend is selected
; through a small driver table. The default backend is SIO channel B.

	.globl const,conin,conout,list,punch,reader,listst
	.globl console_init,console_set_driver
	.globl sio_console_driver,sio_console_init
	.globl CONSOLE_CODE_START,CONSOLE_CODE_END
	.globl CONSOLE_STATE_START,CONSOLE_STATE_END
	.globl CONSOLE_DRIVER
	.globl CONIN_SOFT_COUNT,CONOUT_SOFT_COUNT
	.globl NMI_OLD_SP,NMI_SAVED_STACK,NMI_STACK_DUMP_PTR
	.globl NMI_STACK_DUMP_REMAIN,NMI_STACK_DUMP_COLUMN,NMI_DEBOUNCE_ACTIVE

	.area CODE (ABS)
	.org CBIOS_CONSOLE_CODE_BASE

CONSOLE_CODE_START:

; Initialize the default console backend. Clobbers AF, HL.
console_init:
	ld hl,#sio_console_driver
	ld (CONSOLE_DRIVER),hl
	jp sio_console_init

; Install a different console driver table.
; Input: HL = table containing const, conin, conout, list, punch, reader, listst.
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
CONIN_SOFT_COUNT:
	.dw sio_console_driver
CONOUT_SOFT_COUNT:
	.dw 0x0000
NMI_OLD_SP:
	.dw 0x0000
NMI_SAVED_STACK:
	.dw 0x0000
NMI_STACK_DUMP_PTR:
	.dw 0x0000
NMI_STACK_DUMP_REMAIN:
	.db 0x00
NMI_STACK_DUMP_COLUMN:
	.db 0x00
NMI_DEBOUNCE_ACTIVE:
	.db 0x00
CONSOLE_STATE_END:

	.area CODE (ABS)
