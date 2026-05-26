; Local Zephyr-80 CP/M console BIOS services.
;
; SIO initialization is owned by boot/runtime setup. These entries only poll
; and transfer bytes through the configured console channel.

	.globl const,conin,conout,list,punch,reader,listst
	.globl CONSOLE_CODE_START,CONSOLE_CODE_END
	.globl CONSOLE_STATE_START,CONSOLE_STATE_END

CONSOLE_DATA_PORT	= SIOB_DATA
CONSOLE_CTRL_PORT	= SIOB_CTRL
CONSOLE_RX_READY	= RR0_RX_AVAILABLE
CONSOLE_TX_READY	= RR0_TX_EMPTY
CONSOLE_EOF		= 0x1a
CONSOLE_READY		= 0xff

	.area CODE (ABS)
	.org CBIOS_CONSOLE_CODE_BASE

CONSOLE_CODE_START:

; CONST
; Returns A = 0xff when a console character is available, A = 0x00 otherwise.
; Does not consume pending input. Clobbers AF.
const:
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_RX_READY
	jr z,CONST_NONE
	ld a,#CONST_HAS_CHAR
	ret
CONST_NONE:
	ld a,#CONST_NO_CHAR
	ret

; CONIN
; Blocks until a console character is available, then returns it in A.
; Clobbers AF
conin:
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_RX_READY
	jr nz,CONIN_READY
	nop
	nop	
	nop
	nop
	jr conin
CONIN_READY:
	in a,(CONSOLE_DATA_PORT)
	ret

; CONOUT
; Blocks until transmit is ready, then writes C exactly as supplied.
; Clobbers AF
conout:
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_TX_READY
	jr nz,CONOUT_READY
	nop
	nop
	nop
	nop
	jr conout
CONOUT_READY:
	ld a,c
	out (CONSOLE_DATA_PORT),a
	ret

; LIST and PUNCH have no backing devices in this stage.
list:
	jr CONSOLE_RET

punch:
	jr CONSOLE_RET

; READER returns CP/M EOF because no reader device exists.
reader:
	ld a,#CONSOLE_EOF
	ret

; LISTST reports ready because LIST is a no-op sink.
listst:
	ld a,#CONSOLE_READY
	ret

CONSOLE_RET:
	ret

CONSOLE_CODE_END:

	.area WORK (ABS)
	.org CBIOS_CONSOLE_WORK_AREA
CONSOLE_STATE_START:
CONIN_SOFT_COUNT:
	.dw 0x0000
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
