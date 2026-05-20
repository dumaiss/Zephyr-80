; Zephyr-80 shadow-copy memory decoder test.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Load with the Zephyr-80 monitor L command, then run with:
;   G 8000
;
; This standalone test copies ROM pages into matching SRAM banks with the new
; shadow/copy memory-decoder behavior, then returns to the monitor with RET.
; It does not call monitor routines, does not use interrupts, and does not
; initialize SP.

	.module shadow_copy_test
	.area CODE (ABS)
	.org 0x8000

; Banking latch at I/O port 00h:
; - D0-D2 = SRAM bank number 0-7
; - D3    = shadow mode
; - D4    = ROM disable
; - D5-D7 = ROM page number 0-7
BANK_PORT		= 0x00
SHADOW_BIT		= 0x08
ROMDIS_BIT		= 0x10
COPY_LATCH0		= 0x08		; (0 << 5) | SHADOW_BIT | 0
RAM_ONLY_BANK0		= ROMDIS_BIT

; The copy manager must run below 2000h because copy mode maps
; 0000h-1FFFh as safe SRAM bank 0 while 2000h-FFFFh reads selected ROM and
; writes selected SRAM. The current monitor uses code below 1000h after return,
; so this test uses 1000h instead of 0100h to preserve the monitor's low-RAM
; execution copy.
COPY_STUB_DST		= 0x1000

; Low-RAM state used by the copy manager. These addresses are in the safe
; 0000h-1FFFh common SRAM window and do not touch the monitor code copy.
BANK_VAR		= 0x1f00
SAFE_TEST_VAR		= 0x1f01
SAVED_SP		= 0x1f02
SAVED_RET_LO		= 0x1f04
SAVED_RET_HI		= 0x1f05

PAGE_COPY_START		= 0x2000
PAGE_COPY_LEN		= 0xe000
LOW_COPY_START		= 0x0000
LOW_COPY_LEN		= 0x2000

start:
	di

	; Copy ROM page 0's low safe window into SRAM bank 0 first. In normal mode,
	; reads here come from ROM and writes go to the SRAM underneath it. After
	; copy mode is enabled, 0000h-1FFFh will be forced to this SRAM.
	ld hl,#LOW_COPY_START
	ld bc,#LOW_COPY_LEN
copy_low_page0_loop:
	ld a,(hl)
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,copy_low_page0_loop

	; Copy the manager into low SRAM while normal boot mapping still writes
	; underneath ROM. It intentionally overlays only the upper half of the low
	; 8K window, beyond the current monitor code used after return.
	ld hl,#copy_manager_start
	ld de,#COPY_STUB_DST
	ld bc,#copy_manager_end-copy_manager_start
	ldir

	; Select RAM-only bank 0 so 1000h fetches from SRAM, then jump to the copy
	; manager. The manager performs the actual switch into copy mode from low
	; SRAM; doing that from 8000h would fetch the next opcode from ROM.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a
	jp COPY_STUB_DST

copy_manager_start:
	; Save the monitor G trampoline return address before page-copying bank 0.
	; The E000h copy range includes the monitor stack, so the two return bytes
	; must be restored before RET.
	ld hl,#0x0000
	add hl,sp
	ld (SAVED_SP),hl
	ld a,(hl)
	ld (SAVED_RET_LO),a
	inc hl
	ld a,(hl)
	ld (SAVED_RET_HI),a

	; Copy page/bank 0 first. The low 8K was copied before entering the manager;
	; copy mode now fills page 0's 2000h-FFFFh range from ROM into RAM.
	; This includes the monitor stack, so the saved return address is repaired
	; after ROM is disabled.
	ld a,#COPY_LATCH0
	out (BANK_PORT),a
	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	; Then copy the remaining selectable ROM pages, 1 through 7, into matching
	; SRAM banks. The latch has three page bits, so there is no page number 8.
	ld a,#0x01
	ld (BANK_VAR),a

copy_page_loop:
	; COPY_LATCH(N) = (N << 5) | SHADOW_BIT | N.
	ld a,(BANK_VAR)
	ld e,a
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	or #SHADOW_BIT
	or e
	out (BANK_PORT),a

	; Copy only 2000h-FFFFh. In shadow mode that range reads selected ROM page N
	; and writes selected SRAM bank N, so HL and DE intentionally use the same
	; CPU-visible address.
	ld hl,#PAGE_COPY_START
	ld de,#PAGE_COPY_START
	ld bc,#PAGE_COPY_LEN
	ldir

	ld a,(BANK_VAR)
	inc a
	ld (BANK_VAR),a
	cp #0x08
	jr nz,copy_page_loop

	; Switch to RAM-only bank 0 while still executing from low SRAM bank 0.
	; The following stack repair and RET are safe because 1000h remains RAM.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a

	ld hl,(SAVED_SP)
	ld a,(SAVED_RET_LO)
	ld (hl),a
	inc hl
	ld a,(SAVED_RET_HI)
	ld (hl),a

	ld a,#0x55
	ld (SAFE_TEST_VAR),a
	ret

copy_manager_end:
