; Zephyr-80 common crossing layer (banked OS, Phase 1 step 3).
;
; Code that has to stay correct whichever RAM mode the latch is in when it
; runs: mode 10 (application execution) or mode 11 (OS execution, bank 7 in
; 2000h-BFFFh).  See docs/Zephyr-80_OS_Execution_Memory_Architecture.md.
;
; Everything here runs from common memory.  Nothing here changes the mapping
; under its own stack, so a caller of anything that writes the latch must
; already have SP in common memory.
;
; Placement is transitional: the 36-byte gap between the SIO core and the BIOS
; extensions.  Phase 1 step 7 rebuilds common memory and this moves with it.

	.globl xing_isr,xing_select_ram_bank
	.globl XING_CODE_START,XING_CODE_END
	.globl sio_core_isr

	.area CODE (ABS)
	.org CBIOS_XING_CODE_BASE

XING_CODE_START:

; xing_isr -- IM2 entry for the SIO interrupt.
; Purpose:
;   Take interrupt work off the interrupted stack.  The Z80 has already pushed
;   the return address there; nothing else lands on it.  That matters once
;   ZSDOS runs in bank 7 on its own small stack (plan F2).
; Entry:
;   Interrupts disabled by the acknowledge; any RAM mode; any SP.
; Exit:
;   RETI with interrupts enabled.
; Invariants:
;   One saved-SP slot, so not reentrant.  The body runs with interrupts
;   disabled, and EI's one-instruction delay keeps RETI from nesting.
;   EI before RETI is required: accepting the interrupt cleared IFF1 and IFF2,
;   and RETI does not set them.  The handler used to end in a bare RETI, which
;   left interrupts disabled until foreground code next ran EI.
xing_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	call sio_core_isr
	ld sp,(CBIOS_ISR_SP_SAVE)
	ei
	reti

; xing_select_ram_bank
; Purpose:
;   Select RAM bank A while keeping the RAM mode the latch is already in: mode
;   11 stays mode 11, where only the caller window 0000h-1FFFh changes bank;
;   anything else becomes mode 10.
; Input:
;   A = bank.
; Output:
;   Latch written; A = the value written.
; Clobbers:
;   F.  Preserves BC, DE, HL.
; Invariants:
;   SP and PC must be in common memory: in mode 10 the switch replaces
;   everything below C000h.
;   Never called in mode 01 (shadow/copy): D3 alone is read as mode 11.
xing_select_ram_bank:
	and #BANK_MASK
	push bc
	ld b,a
	in a,(BANK_PORT)
	and #SHADOW_BIT
	or #ROMDIS_BIT
	or b
	pop bc
	out (BANK_PORT),a
	ret

XING_CODE_END:

; A label minus a constant is relocatable to the assembler; a difference of two
; labels is not, so the check compares lengths.
	.ifgt (XING_CODE_END - XING_CODE_START) - (CBIOS_XING_CODE_LIMIT - CBIOS_XING_CODE_BASE)
	.error 1			; crossing layer overflows its gap
	.endif
