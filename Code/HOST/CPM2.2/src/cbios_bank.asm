; Local Zephyr-80 banking and launch BIOS extensions.
;
; This module is owned by the CPM2.2 port and implements the extended BIOS
; ABI exposed after ZBIOS_EXT_BASE.

	.globl MOVE,XMOVE,SELMEM,SETBNK,LAUNCH
	.globl BIOS_CODE_END
	.globl BANKING_CODE_START,BANKING_CODE_END
	.globl BANKING_STATE_START,BANKING_STATE_END
	.globl SAVED_BANK,DMA_BANK,XMOVE_SRC_BANK,XMOVE_DST_BANK,XMOVE_PENDING
	.globl MOVE_BUFFER,APP_LAUNCH_BANK
	.globl CURRENT_BANK,cbios_dma_addr
	.globl WBOOT,FBASE
	
	.area CODE (ABS)
	.org CBIOS_BANKING_CODE_BASE

BANKING_CODE_START:

; SELMEM
; Input: A = target RAM bank.
; Clobbers: AF. Preserves: BC, DE, HL, IX, IY.
SELMEM:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; SETBNK
; Input: A = future disk DMA bank.
; Clobbers: AF. Preserves: BC, DE, HL, IX, IY.
SETBNK:
	and #BANK_MASK
	ld (DMA_BANK),a
	ret

; XMOVE
; Input: C = source bank, B = destination bank.
; Clobbers: AF. Preserves: BC, DE, HL, IX, IY.
XMOVE:
	ld a,c
	and #BANK_MASK
	ld (XMOVE_SRC_BANK),a
	ld a,b
	and #BANK_MASK
	ld (XMOVE_DST_BANK),a
	ld a,#0x01
	ld (XMOVE_PENDING),a
	ret

; MOVE
; Input: BC = byte count, DE = source, HL = destination.
; Clobbers: AF, BC, DE, HL. Preserves: IX, IY.
MOVE:
	ld a,(XMOVE_PENDING)
	or a
	jr nz,MOVE_CROSS_BANK
	ld a,b
	or c
	ret z
	ldir
	ret

MOVE_CROSS_BANK:
	ld a,(CURRENT_BANK)
	ld (SAVED_BANK),a
	ld (MOVE_SRC_PTR),de
	ld (MOVE_DST_PTR),hl
	ld (MOVE_REMAIN),bc

MOVE_CROSS_LOOP:
	ld hl,(MOVE_REMAIN)
	ld a,h
	or l
	jr z,MOVE_CROSS_DONE

	ld a,h
	or a
	jr nz,MOVE_CROSS_FULL_CHUNK
	ld b,#0x00
	ld c,l
	jr MOVE_CROSS_HAVE_CHUNK

MOVE_CROSS_FULL_CHUNK:
	ld bc,#MOVE_BUFFER_SIZE

MOVE_CROSS_HAVE_CHUNK:
	ld (MOVE_CHUNK_LEN),bc

	ld a,(XMOVE_SRC_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld hl,(MOVE_SRC_PTR)
	ld de,#MOVE_BUFFER
	ld bc,(MOVE_CHUNK_LEN)
	ldir
	ld (MOVE_SRC_PTR),hl

	ld a,(XMOVE_DST_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld hl,#MOVE_BUFFER
	ld de,(MOVE_DST_PTR)
	ld bc,(MOVE_CHUNK_LEN)
	ldir
	ld (MOVE_DST_PTR),de

	ld hl,(MOVE_REMAIN)
	ld de,(MOVE_CHUNK_LEN)
	or a
	sbc hl,de
	ld (MOVE_REMAIN),hl
	jr MOVE_CROSS_LOOP

MOVE_CROSS_DONE:
	xor a
	ld (XMOVE_PENDING),a
	ld a,(SAVED_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; LAUNCH
; Input: A = target application bank. Does not return.
LAUNCH:
	di
	and #BANK_MASK
	ld (APP_LAUNCH_BANK),a

	; Restore the selected low-memory bank from the matching ROM page while
	; continuing to execute from protected high/common memory.
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

	ld a,(APP_LAUNCH_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a

	ld a,#0xc3
	ld (PZWBOOT),a
	ld hl,#WBOOT
	ld (PZWBOOT + 1),hl
	ld (PZBDOS),a
	ld hl,#FBASE
	ld (PZBDOS + 1),hl

	xor a
	ld hl,#DEFAULT_DMA
	ld b,#DEFAULT_DMA_LEN
LAUNCH_CLEAR_DMA:
	ld (hl),a
	inc hl
	djnz LAUNCH_CLEAR_DMA

	ld bc,#DEFAULT_DMA
	ld (cbios_dma_addr),bc
	ld sp,#APP_STACK_TOP
	ld hl,#WBOOT
	push hl
	jp MONITOR_ENTRY

BANKING_CODE_END:
BIOS_CODE_END:

	.area WORK (ABS)
	.org CBIOS_BANK_WORK_AREA
BANKING_STATE_START:
SAVED_BANK:
	.db 0x00
DMA_BANK:
	.db 0x00
XMOVE_SRC_BANK:
	.db 0x00
XMOVE_DST_BANK:
	.db 0x00
XMOVE_PENDING:
	.db 0x00
APP_LAUNCH_BANK:
	.db 0x00
MOVE_SRC_PTR:
	.dw 0x0000
MOVE_DST_PTR:
	.dw 0x0000
MOVE_REMAIN:
	.dw 0x0000
MOVE_CHUNK_LEN:
	.dw 0x0000
BANKING_STATE_END:

	.area CODE (ABS)
