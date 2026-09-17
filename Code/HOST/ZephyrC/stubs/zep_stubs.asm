; zep_stubs.asm -- ZephyrC code that must live in common memory.
;
; Assembled for its run address with sdasz80 and embedded into the library as a
; byte image (tools/ihx2c.py).  zep__stubs_install() copies it to E300h once per
; program.  Addresses here are mirrored in src/zep_internal.h; the checks at the
; end refuse to assemble if the layout moves.
;
; Everything here runs with any bank mapped: it touches only E300h-E3FFh and,
; for bank_call, the BDOS facade.

	.module zep_stubs
	.area CODE (ABS)
	.org 0xe300

TICK_STATE	= 0xe3a0		; 12 bytes x 4 channels, to E3CFh
BC_BANK		= 0xe3d0
BC_HOME		= 0xe3d1
BC_ENTRY	= 0xe3d2
BC_ARG		= 0xe3d4
BC_RESULT	= 0xe3d6
BC_FACADE	= 0xe3d8
BC_REGS		= 0xe3da		; A C B E D L H, to E3E0h

ZB_SELMEM	= 212
BASE_TICKS	= 180			; the CTC runs at 180.0115 Hz

stub_tick:
	jp tick_isr			; E300h
stub_bank_call:
	jp bank_call			; E303h

; ---------------------------------------------------------------------------
; CTC tick callback.
;
; The BIOS dispatcher calls it on its interrupt stack, interrupts disabled,
; with C = the channel.  It may use AF, BC, DE and HL, and returns with RET.
;
; State per channel, 12 bytes:
;   +0  rate            +1  phase accumulator (16)
;   +3  produced        +4  consumed
;   +5  overflow (16)   +7  raw interrupt count (32)
;
; produced and consumed are a single-producer, single-consumer queue: this
; callback only ever writes `produced`, and the program only ever writes
; `consumed`, so neither side has to disable interrupts to stay consistent.
; That matters more than it looks: the usual "disable, touch, restore" sequence
; reads IFF2 with `ld a,i`, which on an NMOS Z80 reports interrupts disabled if
; one arrives during the instruction -- and the restore then leaves them off for
; good.  Nothing here or in the library relies on that instruction.
;
; The accumulator gains `rate` every base tick and publishes a logical tick each
; time it reaches 180.  rate <= 180, so at most one tick per interrupt.
; ---------------------------------------------------------------------------
tick_isr:
	ld a,c
	add a,a
	ld d,a				; channel x 2
	add a,a				; x 4
	add a,a				; x 8
	add a,d
	add a,d				; x 12
	ld e,a
	ld d,#0
	ld hl,#TICK_STATE
	add hl,de			; HL -> this channel's state

	push hl
	ld de,#7
	add hl,de			; raw count
	inc (hl)
	jr nz,tick_counted
	inc hl
	inc (hl)
	jr nz,tick_counted
	inc hl
	inc (hl)
	jr nz,tick_counted
	inc hl
	inc (hl)
tick_counted:
	pop hl

	ld e,(hl)			; rate
	ld d,#0
	inc hl
	ld c,(hl)
	inc hl
	ld b,(hl)			; BC = accumulator, HL -> its high byte
	ex de,hl			; HL = rate, DE -> accumulator high byte
	add hl,bc			; HL = accumulator + rate
	ld a,l
	sub #BASE_TICKS
	ld c,a
	ld a,h
	sbc a,#0
	jr c,tick_store			; still short of a tick

	ld h,a
	ld l,c				; HL = accumulator + rate - 180
	ex de,hl			; HL -> accumulator high, DE = new value
	ld (hl),d
	dec hl
	ld (hl),e
	inc hl
	inc hl				; -> produced

	; Publish one tick unless the queue already holds 255.
	ld a,(hl)
	inc a
	inc hl				; -> consumed
	cp (hl)
	jr z,tick_overflow
	dec hl				; -> produced
	ld (hl),a
	ret
tick_overflow:
	inc hl				; -> overflow low
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret

tick_store:
	ex de,hl
	ld (hl),d
	dec hl
	ld (hl),e
	ret

; ---------------------------------------------------------------------------
; Bank call trampoline.
;
; In: BC_BANK, BC_HOME, BC_ENTRY, BC_ARG, BC_FACADE set by zep_bank_call.
; Maps BC_BANK, calls BC_ENTRY with HL = BC_ARG, maps BC_HOME back.
; Out: HL = the callee's HL, or FFFFh if SELMEM refused the bank.
;
; SELMEM changes 0000h-DFFFh under the caller, which is why this is here and why
; it calls the facade directly rather than through page zero.  The stack is in
; common memory (z88dk loads SP from 0006h).  The caller keeps IX/IY
; (zep__call_saved), because the BDOS facade does not.
; ---------------------------------------------------------------------------
bank_call:
	ld a,(BC_BANK)
	call bc_select
	or a
	jr nz,bc_refused
	ld hl,(BC_ARG)
	call bc_invoke
	ld (BC_RESULT),hl
	ld a,(BC_HOME)
	call bc_select
	ld hl,(BC_RESULT)
	ret
bc_refused:
	ld hl,#0xffff
	ret

bc_invoke:
	ld de,(BC_ENTRY)
	push de
	ret				; into the callee; its RET returns after the call

; A = bank.  Out: A = SELMEM status.
bc_select:
	ld (BC_REGS),a
	ld de,#BC_REGS
	ld c,#ZB_SELMEM
	ld hl,(BC_FACADE)
	jp (hl)

stub_code_end:

	; Label minus label: a label minus a constant is relocatable here.
	.ifgt (stub_code_end - stub_tick) - (TICK_STATE - 0xe300)
	.error 1			; the stub code has grown into its state
	.endif

; Signature, which also fixes the image length.
	.org 0xe3f0
	.ascii "ZEPSTUB2"
