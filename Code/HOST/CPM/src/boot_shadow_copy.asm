; Zephyr-80 ROM-to-RAM boot copy skeleton for the CP/M ROM image.
;
; The reset vector at 0000h jumps here in the high safe/common window. This
; code must not use CALL, RET, PUSH, or POP because no valid stack is assumed
; until after ROM has been copied into RAM and disabled.

	.globl cpm_rom_entry_high
	.globl shadow_copy_rom_to_ram
	.globl shadow_copy_rom_to_ram_done
	.globl cbios_boot_after_rom_copy

cpm_rom_entry_high:
shadow_copy_rom_to_ram:
	di

	; Normal ROM mode reads E000h-FFFFh from ROM and writes SRAM underneath.
	; Copy this high window first so execution continues from SRAM bank 0 after
	; shadow/copy mode makes E000h-FFFFh the safe/common RAM area.
	ld hl,#HIGH_COPY_START
	ld bc,#HIGH_COPY_LEN
shadow_copy_high_loop:
	ld a,(hl)
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,shadow_copy_high_loop

	; Enable shadow/copy mode for page/bank 0. From here until ROM is disabled:
	;   0000h-DFFFh reads selected ROM and writes selected SRAM bank.
	;   E000h-FFFFh reads/writes SRAM bank 0.
	ld a,#COPY_LATCH0
	out (BANK_PORT),a

	; Complete page/bank 0. Page copies stop before E000h because the top 8 KiB
	; is the safe/common execution window during shadow/copy mode.
	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	; Copy pages/banks 1 through 7. The top 8 KiB of RAM banks 1-7 is sacrificed
	; under this common-area model, so each page contributes only 56 KiB.
	ld a,#0x01
	ld (SHADOW_COPY_BANK_VAR),a

shadow_copy_page_loop:
	; COPY_LATCH(N) = (N << 5) | SHADOW_BIT | N.
	ld a,(SHADOW_COPY_BANK_VAR)
	ld e,a
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	or #SHADOW_BIT
	or e
	out (BANK_PORT),a

	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	ld a,(SHADOW_COPY_BANK_VAR)
	inc a
	ld (SHADOW_COPY_BANK_VAR),a
	cp #0x08
	jr nz,shadow_copy_page_loop

	; Disable ROM, disable shadow/copy mode, and select RAM bank 0. The next
	; jump enters a RAM-resident placeholder path until real CP/M boot exists.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a

shadow_copy_rom_to_ram_done:
	jp cbios_boot_after_rom_copy

; Stack is safe only after ROM is disabled and high common SRAM bank 0 is active.
cbios_boot_after_rom_copy:
	ld sp,#CBIOS_STACK_TOP
	jp boot
