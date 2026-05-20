; Early ROM-to-RAM relocation for the monitor.
;
; This code runs at reset before the monitor initializes SP, so it must not use
; CALL, RET, PUSH, or POP. The reset vector jumps here in the high common ROM
; window after the BIOS jump table. This routine copies the high safe/common
; window into SRAM bank 0, uses the memory decoder's shadow/copy mode to copy
; ROM pages into matching RAM banks, disables ROM, and then falls through to
; normal monitor initialization from RAM.

monitor_rom_entry_high:
shadow_copy_rom_to_ram:
	di

	; Start from the reset/default banking state explicitly: ROM enabled,
	; shadow disabled, RAM bank 0, ROM page 0.
	xor a
	out (BANK_PORT),a

	; Normal mode reads E000h-FFFFh from ROM page 0 and writes the same address
	; to hidden SRAM bank 0. Copy this high window first because shadow/copy
	; mode will force E000h-FFFFh to SRAM bank 0 for safe execution.
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

	; Enable shadow/copy mode for page/bank 0. The next instruction is still
	; in E000h-FFFFh, so it is fetched from the just-copied SRAM bank 0 image.
	ld a,#COPY_LATCH0
	out (BANK_PORT),a

	; Complete page/bank 0 by copying 0000h-DFFFh. In copy mode this range
	; reads selected ROM and writes selected SRAM at the same CPU address.
	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	; Pages 1-7 intentionally lose their upper 8 KiB in this model. The safe
	; E000h-FFFFh window is always SRAM bank 0 during copy mode, so only each
	; page's 0000h-DFFFh region can be copied.
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

	; Disable ROM, disable shadow/copy mode, and select RAM bank 0. The monitor
	; continues from the SRAM image because this code and the following monitor
	; initialization are in E000h-FFFFh and were copied into SRAM bank 0 first.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a

shadow_copy_rom_to_ram_done:
	; Fall through to normal monitor initialization.
