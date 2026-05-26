; Primitive bank-selection support for UOW-002 boot and warm boot.
;
; Full CP/M banking extension entries are implemented by UOW-003. This module
; only provides the low-level selection primitive needed by BOOT/WBOOT.

	.globl bank_select_internal
	.globl select_ram_bank0
	.globl CURRENT_BANK
	.globl BANK_HELPERS_START,BANK_HELPERS_END

BANK_HELPERS_START:

; Input: A = RAM bank number.
; Output: selected RAM-only bank A&07h, CURRENT_BANK updated.
; Clobbers: AF.
; Invariant:
;   This primitive is safe for early BOOT/WBOOT use. It performs no CALL, RET
;   side effects beyond its own return and does not depend on driver state.
bank_select_internal:
	and #RAM_BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; Output: RAM bank 0 selected.
; Clobbers: AF.
select_ram_bank0:
	xor a
	jp bank_select_internal

BANK_HELPERS_END:
