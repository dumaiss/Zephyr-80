; ===========================================================================
; Cartridge I/O adaptation.
;
; The standard ColecoVision BIOS is a known image, so it is adapted through a
; table of verified operand addresses. A cartridge is not known in advance, so
; its direct I/O operands are located by a recursive-descent trace from the
; cartridge header's documented entry vectors.
;
; Only a byte the trace proves is the operand of a reachable I/O instruction is
; ever rewritten. A data table that merely happens to contain a D3h or DBh byte
; is left alone: a blind byte scan finds nine such bytes in Donkey Kong, which
; has no direct I/O at all. Coverage is therefore deliberately incomplete. Code
; reached only through a computed jump is not traced, and a port held in C is
; not an operand and cannot be rewritten at all. Both cases are reported, and
; a per-title PAT manifest can supply the sites the trace cannot reach.
;
; This file is included by the loader and by the standalone scanner test. It
; depends on CART_BUFFER, cart_byte_count, BDOS, puts and the scratch areas
; declared by its includer, and it performs no I/O of its own.
; ===========================================================================

CART_BASE		= 0x8000
CART_BUFFER_BIAS	= CART_BASE - CART_BUFFER

; A ColecoVision decodes only A0 across the A0h-BFh VDP block; LunchCrema
; passes A1:A0 to the V9958 as its four-port selector.
VDP_BLOCK_LO		= 0xa0
VDP_BLOCK_HI		= 0xbf

; Afternoon Blend decodes A2:A0 within E0h-FFh. Only writes reach the PSGs;
; reads in that block are the controller latches, which the I/O Controller
; already presents at the addresses ColecoVision software expects.
SOUND_BLOCK_LO		= 0xe0
SOUND_BLOCK_HI		= 0xff

CART_HEADER_ENTRY	= 0x0a
CART_HEADER_VECTORS	= 0x0c
CART_VECTOR_COUNT	= 8
CART_VECTOR_BYTES	= 3

SCAN_BITMAP_BYTES	= 0x1000
SCAN_WORKLIST_BYTES	= 0x0800
SCAN_WORKLIST_END	= SCAN_WORKLIST + SCAN_WORKLIST_BYTES

; ---------------------------------------------------------------------------
; Trace driver.
; ---------------------------------------------------------------------------

; Trace the loaded cartridge and adapt every reachable direct I/O operand.
; Inputs: CART_BUFFER holds the image; cart_byte_count is its length in bytes.
; Outputs: operands rewritten in place; scan_vdp_count, scan_snd_count,
;   scan_ind_count, scan_overflow and scan_scanned updated.
; Clobbers AF, BC, DE, HL. Does not block, emit I/O, or touch the takeover
; bank. Not ISR-safe.
scan_cart_io:
	call scan_reset

	; Refuse to trace an image with no cartridge header. Its entry vectors
	; would be arbitrary data, and tracing from a wrong address decodes data
	; as code, which is exactly the failure mode this scanner exists to avoid.
	ld hl,#CART_BUFFER
	ld a,(hl)
	inc hl
	ld b,(hl)
	cp #0xaa
	jr nz,scan_header_reversed
	ld a,b
	cp #0x55
	jr z,scan_header_ok
	ret
scan_header_reversed:
	cp #0x55
	ret nz
	ld a,b
	cp #0xaa
	ret nz

scan_header_ok:
	ld a,#1
	ld (scan_scanned),a
	call scan_seed

scan_drain:
	call scan_pop
	ret c
scan_walk:
	call scan_mark
	jr c,scan_drain
	call scan_step
	or a
	jr z,scan_walk
	jr scan_drain

; Clear the visited bitmap, empty the worklist and zero the report counters.
; Clobbers AF, BC, DE, HL.
scan_reset:
	ld hl,#SCAN_BITMAP
	ld (hl),#0x00
	ld de,#(SCAN_BITMAP + 1)
	ld bc,#(SCAN_BITMAP_BYTES - 1)
	ldir
	ld hl,#SCAN_WORKLIST
	ld (scan_wl_ptr),hl
	ld hl,#0
	ld (scan_vdp_count),hl
	ld (scan_snd_count),hl
	ld (scan_ind_count),hl
	xor a
	ld (scan_overflow),a
	ld (scan_scanned),a
	ret

; Push the documented cartridge entry points: the start address in the header
; and the eight RST/NMI vector slots. The slots are seeded as ordinary code so
; the trace decodes whatever JP or RET each one holds.
; Clobbers AF, BC, DE, HL.
scan_seed:
	ld hl,#(CART_BUFFER + CART_HEADER_ENTRY)
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call scan_push_logical
	ld hl,#(CART_BUFFER + CART_HEADER_VECTORS)
	ld b,#CART_VECTOR_COUNT
scan_seed_loop:
	push bc
	call scan_push_buffer
	ld de,#CART_VECTOR_BYTES
	add hl,de
	pop bc
	djnz scan_seed_loop
	ret

; ---------------------------------------------------------------------------
; Worklist and visited bitmap.
; ---------------------------------------------------------------------------

; Output: CF set when the worklist is empty, otherwise HL = the next address.
; Clobbers AF, DE, HL.
scan_pop:
	ld hl,(scan_wl_ptr)
	ld de,#SCAN_WORKLIST
	or a
	sbc hl,de
	ld a,h
	or l
	scf
	ret z
	ld hl,(scan_wl_ptr)
	dec hl
	ld d,(hl)
	dec hl
	ld e,(hl)
	ld (scan_wl_ptr),hl
	ex de,hl
	or a
	ret

; Inputs: HL = a logical Coleco address.
; Queues the matching image byte, if the address names one. Preserves HL is
; not required of callers; HL is destroyed. Clobbers AF, BC, DE, HL.
scan_push_logical:
	ld bc,#-CART_BUFFER_BIAS
	add hl,bc
	; A logical address below the cartridge wraps to at least CART_BUFFER +
	; 8000h, which no image reaches, so the range test below rejects it.
	jr scan_push_buffer

; Inputs: HL = a candidate image address.
; Queues it unless it lies outside the image, is already a known instruction
; start, or the worklist is full. A dropped entry costs coverage, never
; correctness, so an overflow is recorded and the trace continues.
; Preserves HL. Clobbers AF, BC, DE.
scan_push_buffer:
	push hl
	call scan_in_range
	jr c,scan_push_done
	call scan_is_marked
	jr nz,scan_push_done
	ld de,(scan_wl_ptr)
	ld a,d
	cp #(SCAN_WORKLIST_END >> 8)
	jr nc,scan_push_full
	ld a,l
	ld (de),a
	inc de
	ld a,h
	ld (de),a
	inc de
	ld (scan_wl_ptr),de
	jr scan_push_done
scan_push_full:
	ld a,#1
	ld (scan_overflow),a
scan_push_done:
	pop hl
	ret

; Inputs: HL = an address to test.
; Output: CF set when HL lies outside the loaded image. Preserves HL.
; Clobbers AF, DE.
scan_in_range:
	push hl
	push de
	ld de,#CART_BUFFER
	or a
	sbc hl,de
	jr c,scan_in_range_done
	ld de,(cart_byte_count)
	or a
	sbc hl,de
	ccf
scan_in_range_done:
	pop de
	pop hl
	ret

; Inputs: HL = an address inside the image.
; Output: Z set when the address is not yet a known instruction start.
; Preserves HL. Clobbers AF, BC, DE.
scan_is_marked:
	push hl
	call scan_bit_locate
	ld a,(hl)
	and b
	pop hl
	ret

; Inputs: HL = an address to visit.
; Output: CF set when the walk must stop, because the address lies outside the
;   image or has already been visited. Otherwise the address is recorded as an
;   instruction start and CF is clear. Preserves HL. Clobbers AF, BC, DE.
scan_mark:
	call scan_in_range
	ret c
	call scan_is_marked
	jr z,scan_mark_new
	scf
	ret
scan_mark_new:
	push hl
	call scan_bit_locate
	ld a,(hl)
	or b
	ld (hl),a
	pop hl
	or a
	ret

; Inputs: HL = an address inside the image.
; Outputs: HL = the bitmap byte holding its flag, B = that flag's mask.
; Clobbers AF, DE.
scan_bit_locate:
	ld de,#CART_BUFFER
	or a
	sbc hl,de
	ld a,l
	and #0x07
	inc a
	ld b,#0x01
scan_bit_rotate:
	dec a
	jr z,scan_bit_located
	sla b
	jr scan_bit_rotate
scan_bit_located:
	srl h
	rr l
	srl h
	rr l
	srl h
	rr l
	ld de,#SCAN_BITMAP
	add hl,de
	ret

; ---------------------------------------------------------------------------
; Instruction decode.
; ---------------------------------------------------------------------------

; Decode the instruction at HL, apply its I/O and control-flow effects, and
; advance past it.
; Inputs: HL = an instruction start that has already been marked.
; Outputs: HL advanced past the instruction; A = 0 to continue the
;   straight-line walk, A = 1 to stop it. Clobbers AF, BC, DE.
scan_step:
	ld a,(hl)
	cp #0xcb
	jr z,scan_step_cb
	cp #0xed
	jp z,scan_step_ed
	cp #0xdd
	jp z,scan_step_index
	cp #0xfd
	jp z,scan_step_index
	jp scan_step_main

; Every CBh form is two bytes and none of them branches or performs I/O.
scan_step_cb:
	ld de,#2
	jr scan_step_continue

; Common exits. DE holds the instruction's length.
scan_step_continue:
	add hl,de
	xor a
	ret
scan_step_stop:
	add hl,de
	ld a,#1
	ret

scan_step_main:
	ld c,a
	call scan_main_len
	ld e,a
	ld d,#0

	ld a,c
	cp #0xd3			; OUT (n),A
	jr z,scan_step_out_n
	cp #0xdb			; IN A,(n)
	jr z,scan_step_in_n
	cp #0xc3			; JP nn
	jr z,scan_step_jp
	cp #0xcd			; CALL nn
	jr z,scan_step_branch_nn
	cp #0x18			; JR e
	jr z,scan_step_jr
	cp #0x10			; DJNZ e
	jr z,scan_step_jr_cc
	cp #0xc9			; RET
	jr z,scan_step_stop
	cp #0xe9			; JP (HL)
	jr z,scan_step_stop

	; JR cc,e occupies 20h, 28h, 30h and 38h.
	and #0xe7
	cp #0x20
	jr z,scan_step_jr_cc

	; JP cc,nn occupies C2h+8n and CALL cc,nn occupies C4h+8n.
	ld a,c
	and #0xc7
	cp #0xc2
	jr z,scan_step_branch_nn
	cp #0xc4
	jr z,scan_step_branch_nn
	jr scan_step_continue

; An unconditional jump ends the straight-line walk; its target is queued.
scan_step_jp:
	call scan_push_word
	jr scan_step_stop

; A call or conditional jump queues its target and falls through.
scan_step_branch_nn:
	call scan_push_word
	jr scan_step_continue

scan_step_jr:
	call scan_push_rel
	jr scan_step_stop

scan_step_jr_cc:
	call scan_push_rel
	jr scan_step_continue

; OUT (n),A reaches either the VDP block or an Afternoon Blend PSG.
scan_step_out_n:
	push hl
	inc hl
	call scan_adapt_out
	pop hl
	jr scan_step_continue

; IN A,(n) only needs adapting in the VDP block.
scan_step_in_n:
	push hl
	inc hl
	call scan_adapt_in
	pop hl
	jr scan_step_continue

; Inputs: HL = an instruction holding a 16-bit logical address operand.
; Queues that address. Preserves DE and HL. Clobbers AF, BC.
scan_push_word:
	push hl
	push de
	inc hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call scan_push_logical
	pop de
	pop hl
	ret

; Inputs: HL = a two-byte relative branch.
; Queues its target, which is relative to the following instruction.
; Preserves DE and HL. Clobbers AF, BC.
scan_push_rel:
	push hl
	push de
	inc hl
	ld a,(hl)
	inc hl
	ld e,a
	add a,a				; CF = the displacement's sign
	sbc a,a				; A = 00h or FFh
	ld d,a
	add hl,de
	call scan_push_buffer
	pop de
	pop hl
	ret

; EDh forms. The four-byte cases are LD (nn),dd and LD dd,(nn); everything
; else is two bytes. IN r,(C), OUT (C),r and the block I/O forms take their
; port from C, so no operand exists to rewrite and they are only counted.
; Inputs: HL = the EDh byte. Outputs and clobbers match scan_step.
scan_step_ed:
	inc hl
	ld a,(hl)
	dec hl
	ld c,a
	and #0xc7
	ld b,a
	ld de,#2
	cp #0x43
	jr nz,scan_step_ed_decoded
	ld de,#4
scan_step_ed_decoded:
	ld a,b
	cp #0x40			; IN r,(C)
	jr z,scan_step_ed_indirect
	cp #0x41			; OUT (C),r
	jr z,scan_step_ed_indirect
	ld a,c
	; A2h, A3h, AAh, ABh, B2h, B3h, BAh and BBh are INI, OUTI, IND, OUTD and
	; their repeating forms. Masking A4 and A3 away leaves exactly those
	; eight; LDI, CPI and their relatives clear A1 and are not I/O.
	and #0xe6
	cp #0xa2
	jr nz,scan_step_ed_flow
scan_step_ed_indirect:
	push bc
	ld bc,(scan_ind_count)
	inc bc
	ld (scan_ind_count),bc
	pop bc
scan_step_ed_flow:
	ld a,b
	cp #0x45			; RETN and RETI
	jp z,scan_step_stop
	jp scan_step_continue

; DDh and FDh forms. The prefix adds one byte, plus a displacement whenever
; the prefixed opcode would have referenced (HL).
; Inputs: HL = the prefix byte. Outputs and clobbers match scan_step.
scan_step_index:
	inc hl
	ld a,(hl)
	dec hl
	cp #0xcb
	jr z,scan_step_index_cb
	cp #0xdd
	jr z,scan_step_index_cancel
	cp #0xfd
	jr z,scan_step_index_cancel
	cp #0xed
	jr z,scan_step_index_cancel
	ld c,a
	call scan_main_len
	ld e,a
	ld d,#0
	inc de				; the prefix itself
	ld a,c
	call scan_index_is_hl_form
	jr nc,scan_step_index_decoded
	inc de				; the displacement byte
scan_step_index_decoded:
	ld a,c
	cp #0xe9			; JP (IX) and JP (IY)
	jp z,scan_step_stop
	jp scan_step_continue

; DDh CBh d op and FDh CBh d op are always four bytes and never branch.
scan_step_index_cb:
	ld de,#4
	jp scan_step_continue

; A second index prefix, or an EDh prefix, cancels this one. Resume decoding
; at the following byte rather than guessing a length.
scan_step_index_cancel:
	ld de,#1
	jp scan_step_continue

; Inputs: A = a main-page opcode carried by a DDh or FDh prefix.
; Output: CF set when the opcode references (HL) and so gains a displacement.
; Clobbers AF, B.
scan_index_is_hl_form:
	ld b,a
	cp #0x34			; INC (HL)
	jr z,scan_index_yes
	cp #0x35			; DEC (HL)
	jr z,scan_index_yes
	cp #0x36			; LD (HL),n
	jr z,scan_index_yes
	cp #0x76			; HALT, not LD (HL),(HL)
	jr z,scan_index_no
	and #0xc7
	cp #0x46			; LD r,(HL)
	jr z,scan_index_yes
	cp #0x86			; ALU A,(HL)
	jr z,scan_index_yes
	ld a,b
	and #0xf8
	cp #0x70			; LD (HL),r
	jr z,scan_index_yes
scan_index_no:
	or a
	ret
scan_index_yes:
	scf
	ret

; Inputs: A = a main-page opcode.
; Output: A = its total length in bytes. The four prefix opcodes report 1;
;   their own handlers decode them. Preserves BC and HL; clobbers DE, which
;   every caller reloads with the decoded length immediately afterwards.
scan_main_len:
	push hl
	ld l,a
	ld h,#0
	ld de,#scan_len_main
	add hl,de
	ld a,(hl)
	pop hl
	ret

; ---------------------------------------------------------------------------
; Operand rewriting.
; ---------------------------------------------------------------------------

; Inputs: HL = the operand byte of a reachable OUT (n),A.
; Output: the operand rewritten when it names a Coleco VDP or sound port.
; Preserves DE and HL. Clobbers AF, BC.
scan_adapt_out:
	ld a,(hl)
	cp #VDP_BLOCK_LO
	ret c
	cp #(VDP_BLOCK_HI + 1)
	jr c,scan_adapt_vdp
	cp #SOUND_BLOCK_LO
	ret c				; C0h-DFh is not decoded on Zephyr
	; Any write in E0h-FFh is meant for the ColecoVision's single SN76489.
	; Afternoon Blend answers at PSG0.
	ld a,#ZEPHYR_SOUND_PORT
	cp (hl)
	ret z
	ld (hl),a
	ld bc,(scan_snd_count)
	inc bc
	ld (scan_snd_count),bc
	ret

; Inputs: HL = the operand byte of a reachable IN A,(n).
; Output: the operand rewritten when it names a Coleco VDP port. Reads in
;   E0h-FFh are controller latches and are already correct.
; Preserves DE and HL. Clobbers AF, BC.
scan_adapt_in:
	ld a,(hl)
	cp #VDP_BLOCK_LO
	ret c
	cp #(VDP_BLOCK_HI + 1)
	ret nc

; Inputs: HL = a VDP operand byte in A0h-BFh.
; Output: the port reduced to the native data or command port, preserving the
;   A0 sense the ColecoVision decodes. Preserves DE and HL. Clobbers AF, BC.
scan_adapt_vdp:
	ld a,(hl)
	and #0x01
	or #ZEPHYR_VDP_DATA_PORT
	cp (hl)
	ret z
	ld (hl),a
	ld bc,(scan_vdp_count)
	inc bc
	ld (scan_vdp_count),bc
	ret

; ---------------------------------------------------------------------------
; Total length of every main-page Z80 opcode. The four prefix opcodes carry 1.
; tools/check_build.py re-derives this table and fails the build on a
; mismatch, so it must not be edited by hand.
; ---------------------------------------------------------------------------
scan_len_main:
	.db 1,3,1,1,1,1,2,1	; 00
	.db 1,1,1,1,1,1,2,1	; 08
	.db 2,3,1,1,1,1,2,1	; 10
	.db 2,1,1,1,1,1,2,1	; 18
	.db 2,3,3,1,1,1,2,1	; 20
	.db 2,1,3,1,1,1,2,1	; 28
	.db 2,3,3,1,1,1,2,1	; 30
	.db 2,1,3,1,1,1,2,1	; 38
	.db 1,1,1,1,1,1,1,1	; 40
	.db 1,1,1,1,1,1,1,1	; 48
	.db 1,1,1,1,1,1,1,1	; 50
	.db 1,1,1,1,1,1,1,1	; 58
	.db 1,1,1,1,1,1,1,1	; 60
	.db 1,1,1,1,1,1,1,1	; 68
	.db 1,1,1,1,1,1,1,1	; 70
	.db 1,1,1,1,1,1,1,1	; 78
	.db 1,1,1,1,1,1,1,1	; 80
	.db 1,1,1,1,1,1,1,1	; 88
	.db 1,1,1,1,1,1,1,1	; 90
	.db 1,1,1,1,1,1,1,1	; 98
	.db 1,1,1,1,1,1,1,1	; A0
	.db 1,1,1,1,1,1,1,1	; A8
	.db 1,1,1,1,1,1,1,1	; B0
	.db 1,1,1,1,1,1,1,1	; B8
	.db 1,1,3,3,3,1,2,1	; C0
	.db 1,1,3,1,3,3,2,1	; C8
	.db 1,1,3,2,3,1,2,1	; D0
	.db 1,1,3,2,3,1,2,1	; D8
	.db 1,1,3,1,3,1,2,1	; E0
	.db 1,1,3,1,3,1,2,1	; E8
	.db 1,1,3,1,3,1,2,1	; F0
	.db 1,1,3,1,3,1,2,1	; F8
scan_len_main_end:
