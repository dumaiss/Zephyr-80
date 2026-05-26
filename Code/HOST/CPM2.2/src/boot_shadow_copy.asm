; Zephyr-80 ROM-to-RAM boot copy for the CP/M ROM image.
;
; This local source is adapted from the approved known-good shadow-copy
; behavior. It must not use CALL, RET, PUSH, or POP because no valid stack is
; assumed until after ROM has been copied into RAM and disabled.

	.globl cpm_rom_entry_high
	.globl shadow_copy_rom_to_ram
	.globl shadow_copy_rom_to_ram_done
	.globl cbios_boot_after_rom_copy

cpm_rom_entry_high:
shadow_copy_rom_to_ram:
	di

	; Normal ROM mode reads C000h-FFFFh from ROM and writes SRAM underneath.
	; Copy the common window first so execution remains safe after copy mode.
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

	; Enable shadow/copy mode for page/bank 0.
	ld a,#COPY_LATCH0
	out (BANK_PORT),a

	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	; Copy pages/banks 1 through 7. The upper 16 KiB remains common bank 0.
	; Do not install page-zero or NMI vectors while walking these banks:
	; banks 2-7 are RAM-disk storage, and 0066h is CP/M default FCB space.
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

	; Disable ROM, leave copy mode, and select RAM bank 0.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a

shadow_copy_rom_to_ram_done:
	jp cbios_boot_after_rom_copy

cbios_boot_after_rom_copy:
	ld sp,#CBIOS_STACK_TOP
	jp boot
