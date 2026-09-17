; Local Zephyr-80 CP/M console BIOS facade.
;
; CP/M entry labels stay stable while the active console backend is selected
; through a small driver table. The Makefile selects the linked backend.
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
; The facade preserves DE and HL around the indirect call, but NOT BC (the
; packed facade region has no free bytes to save it). Backend routines follow
; the CP/M register conventions for their specific entry points; per that
; convention a backend such as CONST may clobber BC, so callers must not hold a
; live value in BC across a console BIOS call.
;
; CP/M BDOS function 2 uses a small private stack while checking console
; status and outputting characters. The Virtual Drip backend is intentionally
; deeper than the legacy byte-oriented SIO backend, so dispatch runs backend
; calls on a private console stack in the BIOS stack reserve and restores the
; caller stack before returning.

	.globl const,conin,conout,list,punch,reader,listst
	.globl console_init,console_set_driver,console_wait_key
	.globl console_backend_driver,console_backend_init
	.globl CONSOLE_CODE_START,CONSOLE_CODE_END
	.globl CONSOLE_STATE_START,CONSOLE_STATE_END
	.globl CONSOLE_DRIVER

	.area CODE (ABS)
	.org CBIOS_CONSOLE_CODE_BASE

CONSOLE_CODE_START:

; Initialize the default console backend.
; Purpose:
;   Install the build-selected console table and clear its backend state.
; Inputs: none.
; Outputs: CONSOLE_DRIVER points at console_backend_driver.
; Clobbers: AF, HL.
console_init:
	ld hl,#console_backend_driver
	ld (CONSOLE_DRIVER),hl
	jp console_backend_init

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
	; pointer, call it through a tiny return shim on the console stack, then
	; restore facade registers and the caller stack.
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
	ld (CONSOLE_CALLER_SP),sp
	ld sp,#CBIOS_CONSOLE_STACK_TOP
	ld de,#CONSOLE_CALL_RETURN
	push de
	jp (hl)

CONSOLE_CALL_RETURN:
	ld hl,(CONSOLE_CALLER_SP)
	ld sp,hl
	pop hl
	pop de
	ret

; ---------------------------------------------------------------------------
; console_wait_key -- hold the screen until a key is pressed.
;
; Warm boot reinitialises the console, and that clears the screen, so whatever a
; program printed on its way out would be gone before it could be read.  WBOOT
; calls this first.
;
; Only programs that warm boot come here.  A transient that returns to the CCP
; does not, and neither does ZCPR2's own ^C, which restarts the command
; processor without a warm boot.
;
; It runs on the driver the ending program left installed, before console_init
; rebuilds it, so a graphics screen is still on display while the operator
; reads it.  The caller enables interrupts first so a serial console can answer;
; the CTC and every program callback have already been reset by then.
;
; The wait is bounded.  A program that wrecks console input must not leave the
; machine needing a power cycle, so after about thirty seconds the warm boot
; goes ahead anyway.
;
; The spin between polls is register-only and looks at the console about a
; hundred times a second, the rate the V9958 CONIN idle loop settled on: this
; machine has no regulators, and a faster idle loop is audible on the rail.
;
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
CONSOLE_WAIT_SPIN	= 3800		; 26 T-states each: about 9.9 ms at 10 MHz
CONSOLE_WAIT_POLLS	= 3000		; about 30 seconds

console_wait_key:
	ld hl,#console_wait_prompt
console_wait_text:
	ld a,(hl)
	or a
	jr z,console_wait_start
	push hl
	ld c,a
	call conout
	pop hl
	inc hl
	jr console_wait_text

console_wait_start:
	ld de,#CONSOLE_WAIT_POLLS
console_wait_poll:
	ld hl,#CONSOLE_WAIT_SPIN
console_wait_spin:
	dec hl
	ld a,h
	or l
	jr nz,console_wait_spin

	; CONST also publishes pending output on this machine's consoles, so the
	; prompt appears on the first pass.
	call const
	or a
	jr nz,console_wait_key_ready
	dec de
	ld a,d
	or e
	jr nz,console_wait_poll
	ret				; timed out; warm boot anyway

console_wait_key_ready:
	jp conin			; consume the key and return

console_wait_prompt:
	.db 13,10
	.ascii "[any key]"
	.db 0

CONSOLE_CODE_END:

	.area WORK (ABS)
	.org CBIOS_CONSOLE_WORK_AREA
CONSOLE_STATE_START:
CONSOLE_DRIVER:
	.dw console_backend_driver
CONSOLE_CALLER_SP:
	.dw 0x0000

CONSOLE_STATE_END:

	.area CODE (ABS)
