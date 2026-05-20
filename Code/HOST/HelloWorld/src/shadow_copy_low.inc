; Low-memory ROM-to-RAM shadow/copy routine for the Zephyr-80 memory decoder.
;
; Include this from code assembled at 0000h, before code that should continue
; running with ROM disabled. This routine uses no CALL/PUSH/POP and intentionally
; falls through after disabling ROM instead of returning through the stack.
;
; Banking latch at I/O port 00h:
; - D0-D2 = SRAM bank number 0-7
; - D3    = shadow/copy mode
; - D4    = ROM disable
; - D5-D7 = ROM page number 0-7
;
; Copy behavior:
; - Normal mode lets 0000h-1FFFh read ROM page 0 and write hidden SRAM bank 0.
; - Copy mode makes 0000h-1FFFh execute from SRAM bank 0, while 2000h-FFFFh
;   reads the selected ROM page and writes the selected SRAM bank.
; - RAM-only bank 0 leaves the copied code visible after ROM is disabled.

BANK_PORT		= 0x00
SHADOW_BIT		= 0x08
ROMDIS_BIT		= 0x10
COPY_LATCH0		= 0x08		; (0 << 5) | SHADOW_BIT | 0
RAM_ONLY_BANK0		= ROMDIS_BIT

LOW_COPY_START		= 0x0000
LOW_COPY_LEN		= 0x2000
PAGE_COPY_START		= 0x2000
PAGE_COPY_LEN		= 0xe000
SHADOW_COPY_BANK_VAR	= 0x1fff

shadow_copy_rom_to_ram:
	di

	; Copy the low safe window from ROM page 0 into SRAM bank 0 first. This
	; makes the code at 0000h-1FFFh available immediately after copy mode is
	; enabled.
	ld hl,#LOW_COPY_START
	ld bc,#LOW_COPY_LEN
shadow_copy_low_loop:
	ld a,(hl)
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,shadow_copy_low_loop

	; Complete page/bank 0 by copying 2000h-FFFFh in copy mode.
	ld a,#COPY_LATCH0
	out (BANK_PORT),a
	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	; Copy the remaining selectable pages, 1 through 7, into matching banks.
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

	; ROM is now copied into SRAM banks. Disable ROM and continue executing the
	; following code from SRAM bank 0.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a

shadow_copy_rom_to_ram_done:
	; Fall through to the including program.
