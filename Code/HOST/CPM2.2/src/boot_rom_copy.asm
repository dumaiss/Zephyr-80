; Cold boot: page 0 -> SRAM 0, page BOOT_OS_ROM_PAGE -> SRAM 7.
; Input: reset latch selects page 0, mode 00. No stack required.
; Output: application mode, bank 0; jumps to boot. Clobbers AF/BC/DE/HL.
; Blocking full-page copies, no VDP traffic, not ISR-safe.
; IRQ masking belongs to irq_rom_entry in the page-0 common image.
	.globl cpm_rom_entry_high,rom_copy_masked,BOOTSTRAP_END
	.globl cbios_boot_after_rom_copy
cpm_rom_entry_high:
	jp irq_rom_entry

	.area RESET (ABS)
	.org 0x0003
rom_copy_masked:
	ld a,#MEM_MODE_ROM
	out (BANK_PORT),a
	ld hl,#0x0000
	ld de,#0x0000
	ld bc,#0x0000             ; Z80 LDIR: exactly 65536 transfers
	ldir
	ld a,#(BOOT_OS_ROM_PAGE << ROM_PAGE_SHIFT) | MEM_MODE_ROM | OS_BANK
	out (BANK_PORT),a
	; The next instruction has identical bytes at this address in page 7.
	ld hl,#0x0000
	ld de,#0x0000
	ld bc,#0x0000
	ldir
	ld a,#MEM_MODE_APPLICATION
	out (BANK_PORT),a
	; Execution now continues in the identical bootstrap in SRAM bank 0.
cbios_boot_after_rom_copy:
	jp boot                     ; boot selects mode 11 before installing SP
BOOTSTRAP_END:
; Both labels must follow the same .org for the difference to resolve, so
; measure from rom_copy_masked and drop its 0003h origin from the budget.
	.ifgt (BOOTSTRAP_END - rom_copy_masked) - (BOOTSTRAP_LIMIT - 0x0003)
	.error 1			; bootstrap overruns its zero-page budget
	.endif
	.area CODE (ABS)
	.org CBIOS_BASE + 0x004e     ; immediately after cpm_rom_entry_high
