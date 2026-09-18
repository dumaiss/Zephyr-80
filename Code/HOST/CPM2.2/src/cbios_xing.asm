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

; SIO IM2 entry now belongs to cbios_irq.asm.

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
;   Called only in managed modes 10/11; flat mode has no common stack.
xing_select_ram_bank:
	and #BANK_MASK
	push bc
	ld b,a
	in a,(BANK_PORT)
	and #MEM_MODE0
	or #MEM_MODE_APPLICATION
	or b
	pop bc
	out (BANK_PORT),a
	ret
XING_SELECT_END:

; ROM record primitive. In: A=return latch, B=ROM/destination latch,
; C=BANK_PORT, HL=ROM source, DE=SRAM destination. IRQs must be masked.
; Out: original mapping restored; BC=0, HL/DE advanced 128, A preserved.
; Stack used only in SRAM mode. No VDP traffic; not ISR-safe; bounded copy.
; The builder mirrors ROM_ACCESS_BASE..+SIZE into each filesystem page's
; unused tail, so instruction fetches continue in ROM after OUT (C),B.
	.org ROM_ACCESS_BASE - 2
xing_rom_read:
	out (c),b
ROM_ACCESS_START:
	ld bc,#ROMDISK_RECORD_BYTES
	ldir
	out (BANK_PORT),a
ROM_ACCESS_END:
	ret
; A label minus a constant is relocatable, so compare label differences: the
; two bytes of OUT (C),B must be all that precedes the mirrored primitive.
	.ifne (ROM_ACCESS_START - xing_rom_read) - 2
	.error 1			; primitive not at ROM_ACCESS_BASE
	.endif
	.ifne (ROM_ACCESS_END - ROM_ACCESS_START) - ROM_ACCESS_SIZE
	.error 1			; mirrored primitive is not ROM_ACCESS_SIZE bytes
	.endif

XING_CODE_END:

; A label minus a constant is relocatable to the assembler; a difference of two
; labels is not, so the checks compare lengths.  The .org above splits this
; layer into two blocks, and a difference may not straddle it, so each block is
; bounded against its own origin: the selector must stop short of the mirrored
; primitive, and the primitive must stop short of the region limit.
	.ifgt (XING_SELECT_END - XING_CODE_START) - ((ROM_ACCESS_BASE - 2) - CBIOS_XING_CODE_BASE)
	.error 1			; selector runs into the ROM primitive
	.endif
	.ifgt (XING_CODE_END - xing_rom_read) - (CBIOS_XING_CODE_LIMIT - (ROM_ACCESS_BASE - 2))
	.error 1			; crossing layer overflows its gap
	.endif
