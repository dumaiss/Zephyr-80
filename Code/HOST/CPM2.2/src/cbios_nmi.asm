; Local Zephyr-80 non-maskable interrupt support.
;
; This module implements a common high-memory NMI handler. Normal CP/M runtime
; code must not patch the low-memory NMI vector at 0066h because that address is
; inside CP/M's default FCB area, 005Ch-007Fh.

	.globl NMI_HANDLER
	.globl NMI_CODE_START,NMI_CODE_END
	.globl patch_nmi_vector
	.globl WBOOT

NMI_STACK_DUMP_LEN	= 0x80
NMI_STACK_DUMP_COLUMNS	= 0x10
NMI_DEBOUNCE_DELAY_COUNT	= 0xffff

	.area CODE (ABS)
	.org CBIOS_NMI_CODE_BASE

NMI_CODE_START:
NMI_HANDLER:
	push af
	ld a,(NMI_DEBOUNCE_ACTIVE)
	or a
	jr z,NMI_ACCEPT
	xor a
	ld (NMI_DEBOUNCE_ACTIVE),a
NMI_ACCEPT:
	ld a,#0xff
	ld (NMI_DEBOUNCE_ACTIVE),a
	pop af

	; Save original stack pointer and register snapshot before any calls.
	ld (NMI_OLD_SP),sp
	push af
	push bc
	push de
	push hl
	push ix
	push iy
	exx
	push bc
	push de
	push hl
	ex af,af'
	push af
	ex af,af'
	ld (NMI_SAVED_STACK),sp

	ld sp,#CBIOS_STACK_TOP
	call NMI_PRINT_SNAPSHOT
	call NMI_PROMPT_CHOICE
	or a
	jr z,NMI_CONTINUE
	call NMI_DEBOUNCE_DELAY
	xor a
	ld (NMI_DEBOUNCE_ACTIVE),a
	jp WBOOT

NMI_CONTINUE:
	call NMI_DEBOUNCE_DELAY
	xor a
	ld (NMI_DEBOUNCE_ACTIVE),a
	ld sp,(NMI_SAVED_STACK)
	pop af
	ex af,af'
	pop hl
	pop de
	pop bc
	exx
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	retn

patch_nmi_vector:
	; Retained as a compatibility symbol for older callers, but intentionally
	; disabled. Page-zero/NMI patching must not be replicated across banks:
	; banks 2-7 hold RAM-disk storage, and 0066h is CP/M default FCB space.
	ret

NMI_DEBOUNCE_DELAY:
	push bc
	ld bc,#NMI_DEBOUNCE_DELAY_COUNT
NMI_DEBOUNCE_DELAY_LOOP:
	dec bc
	ld a,b
	or c
	jr nz,NMI_DEBOUNCE_DELAY_LOOP
	pop bc
	ret

NMI_PROMPT_CHOICE:
	ld hl,#NMI_PROMPT_STRING
	call NMI_PRINT_STRING
NMI_PROMPT_CHOICE_LOOP:
	call conin
	cp #'C'
	jr z,NMI_PROMPT_CONTINUE
	cp #'c'
	jr z,NMI_PROMPT_CONTINUE
	cp #'W'
	jr z,NMI_PROMPT_WBOOT
	cp #'w'
	jr z,NMI_PROMPT_WBOOT
	cp #'M'
	jr z,NMI_PROMPT_WBOOT
	cp #'m'
	jr z,NMI_PROMPT_WBOOT
	jr NMI_PROMPT_CHOICE_LOOP
NMI_PROMPT_CONTINUE:
	call NMI_PRINT_CRLF
	xor a
	ret
NMI_PROMPT_WBOOT:
	call NMI_PRINT_CRLF
	ld a,#0x01
	ret

NMI_PRINT_SNAPSHOT:
	ld hl,#NMI_SNAPSHOT_STRING
	call NMI_PRINT_STRING
	call NMI_PRINT_CRLF

	ld hl,#PC_LABEL
	call NMI_PRINT_STRING
	ld hl,(NMI_OLD_SP)
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld l,e
	ld h,d
	call NMI_PRINT_HEX_WORD
	call NMI_PRINT_CRLF

	ld hl,#SP_LABEL
	call NMI_PRINT_STRING
	ld hl,(NMI_OLD_SP)
	call NMI_PRINT_HEX_WORD
	call NMI_PRINT_CRLF

	ld hl,#AF_BC_DE_HL_LABEL
	call NMI_PRINT_STRING
	ld bc,#18
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#16
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#14
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#12
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CRLF

	ld hl,#IX_IY_LABEL
	call NMI_PRINT_STRING
	ld bc,#10
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#8
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CRLF

	ld hl,#AFP_BCP_DEP_HLP_LABEL
	call NMI_PRINT_STRING
	ld bc,#0
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#2
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#4
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CHAR_SPACE
	ld bc,#6
	call NMI_PRINT_SAVED_WORD
	call NMI_PRINT_CRLF

	ld hl,#BANK_LABEL
	call NMI_PRINT_STRING
	in a,(BANK_PORT)
	and #RAM_BANK_MASK
	call NMI_PRINT_HEX_BYTE
	call NMI_PRINT_CRLF

	ld hl,#STACK_BYTES_LABEL
	call NMI_PRINT_STRING
	call NMI_PRINT_CRLF

	ld hl,(NMI_OLD_SP)
	ld (NMI_STACK_DUMP_PTR),hl
	ld a,#NMI_STACK_DUMP_LEN
	ld (NMI_STACK_DUMP_REMAIN),a
	xor a
	ld (NMI_STACK_DUMP_COLUMN),a
NMI_PRINT_STACK_LOOP:
	ld hl,(NMI_STACK_DUMP_PTR)
	ld a,(hl)
	inc hl
	ld (NMI_STACK_DUMP_PTR),hl
	call NMI_PRINT_HEX_BYTE

	ld a,(NMI_STACK_DUMP_REMAIN)
	dec a
	ld (NMI_STACK_DUMP_REMAIN),a
	jr z,NMI_PRINT_STACK_DONE

	ld a,(NMI_STACK_DUMP_COLUMN)
	inc a
	and #(NMI_STACK_DUMP_COLUMNS - 1)
	ld (NMI_STACK_DUMP_COLUMN),a
	jr z,NMI_PRINT_STACK_NEWLINE
	call NMI_PRINT_CHAR_SPACE
	jr NMI_PRINT_STACK_LOOP
NMI_PRINT_STACK_NEWLINE:
	call NMI_PRINT_CRLF
	jr NMI_PRINT_STACK_LOOP
NMI_PRINT_STACK_DONE:
	call NMI_PRINT_CRLF
	ret

NMI_PRINT_STRING:
	push hl
NMI_PRINT_STRING_LOOP:
	ld a,(hl)
	or a
	jr z,NMI_PRINT_STRING_DONE
	ld c,a
	call conout
	inc hl
	jr NMI_PRINT_STRING_LOOP
NMI_PRINT_STRING_DONE:
	pop hl
	ret

NMI_PRINT_HEX_NIBBLE:
	and #0x0f
	cp #10
	jr c,NMI_PRINT_HEX_NIBBLE_DIGIT
	add #('A' - 10)
	jr NMI_PRINT_HEX_NIBBLE_EMIT
NMI_PRINT_HEX_NIBBLE_DIGIT:
	add #'0'
NMI_PRINT_HEX_NIBBLE_EMIT:
	ld c,a
	call conout
	ret

NMI_PRINT_HEX_BYTE:
	push af
	rlca
	rlca
	rlca
	rlca
	and #0x0f
	call NMI_PRINT_HEX_NIBBLE
	pop af
	and #0x0f
	call NMI_PRINT_HEX_NIBBLE
	ret

NMI_PRINT_HEX_WORD:
	push hl
	ld a,h
	call NMI_PRINT_HEX_BYTE
	ld a,l
	call NMI_PRINT_HEX_BYTE
	pop hl
	ret

NMI_PRINT_SAVED_WORD:
	; Entry: BC = offset from saved-stack base.
	push hl
	ld hl,(NMI_SAVED_STACK)
	add hl,bc
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld l,e
	ld h,d
	call NMI_PRINT_HEX_WORD
	pop hl
	ret

NMI_PRINT_CHAR_SPACE:
	ld c,#' '
	call conout
	ret

NMI_PRINT_CRLF:
	ld c,#CR
	call conout
	ld c,#LF
	call conout
	ret

NMI_SNAPSHOT_STRING:
	.ascii /NMI snapshot/
	.db 0
PC_LABEL:
	.ascii /PC: /
	.db 0
SP_LABEL:
	.ascii /SP: /
	.db 0
AF_BC_DE_HL_LABEL:
	.ascii /AF BC DE HL: /
	.db 0
IX_IY_LABEL:
	.ascii /IX IY: /
	.db 0
AFP_BCP_DEP_HLP_LABEL:
	.ascii /AF' BC' DE' HL': /
	.db 0
BANK_LABEL:
	.ascii /BANK: /
	.db 0
STACK_BYTES_LABEL:
	.ascii /Stack bytes:/
	.db 0
NMI_PROMPT_STRING:
	.ascii /C=continue W=warm boot: /
	.db 0

NMI_CODE_END:
