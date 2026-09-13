; MAP11.COM -- prove the mode 11 decoder map on hardware.
;
; ../CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md, section 26.
; MEM_DECODER.pld revision 11 is the Phase 2 map:
;
;   mode 10   0000-DFFF  latch bank N                 E000-FFFF  bank 0
;   mode 11   0000-1FFF  latch bank N   2000-DFFF  bank 7   E000-FFFF  bank 0
;
; Revision 10 (Phase 1) put the common boundary at C000h in both modes.  This
; checks the new boundary from both sides, and the caller window, before trusting
; the OS that depends on them.
;
; For each application bank N (0, then 5), from a core copied into the program
; interrupt reservation at E000h -- common in both modes -- with interrupts off:
;
;   1. mode 10, bank 7   save, then sign 1FFF 2000 9000 BFFF C800 DFFF: 71-76
;   2. mode 10, bank N   save, then sign the same addresses: N1-N6
;   3. mode 11           1FFF must read N1, 2000-DFFF bank 7's 72-76, E000 the
;                        same as mode 10, the latch 18h|N.  Then write 2000=A5,
;                        DFFF=A6, 1FFE=5A and a common byte.
;   4. mode 10, bank N   N1-N6 untouched, 1FFE and the common byte arrived;
;                        restore the saved bytes
;   5. mode 10, bank 7   2000=A5 and DFFF=A6 arrived, 1FFF untouched; restore
;
; Bank 7 is the running OS.  The probed bytes there -- ZSDOS's first serial
; byte, unused image bytes, unused runtime stack space -- are all saved first
; and put back, and nothing in the OS runs while interrupts are off.

	.module map11
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONIN	= 0x01
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

BANK_PORT	= 0x00
ROMDIS_BIT	= 0x10
SHADOW_BIT	= 0x08

CORE_ADDR	= 0xe000		; common in modes 10 and 11
SAVE7		= 0xe2c0		; bank 7's six probed bytes
SAVEN		= 0xe2d0		; bank N's seven
CTEST		= 0xe2ff		; common byte written from mode 11
RES		= 0xe300		; core results
CSTACK		= 0xe3f0
TPA_NEEDED	= 0xe400		; the reservation must be TPA

K_SKIP		= 0
K_LIT		= 1			; want = value
K_NPAT		= 2			; want = (N << 4) | value
K_LATCH		= 3			; want = value | N
K_SAME		= 4			; want = RES[value]

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld de,#msg_banner
	call puts

	ld hl,(BDOS + 1)
	ld de,#TPA_NEEDED
	or a
	sbc hl,de
	jr nc,tpa_ok
	ld de,#msg_tpa
	call puts
	jp finish
tpa_ok:
	in a,(BANK_PORT)
	ld (entry_latch),a
	ld de,#msg_latch
	call puts
	ld a,(entry_latch)
	call hex
	call crlf
	ld a,(entry_latch)
	cp #ROMDIS_BIT
	jr z,latch_ok
	ld de,#msg_latch_bad
	call puts
	jp finish

latch_ok:
	ld hl,#core_start
	ld de,#CORE_ADDR
	ld bc,#core_end - core_start
	ldir
	xor a
	ld (total_fails),a
	call test_bank
	ld a,#5
	call test_bank
	ld a,(total_fails)
	or a
	ld de,#msg_pass
	jr z,done
	ld de,#msg_fail_all
done:
	call puts
finish:
	ld de,#msg_key
	call puts
	ld c,#BDOS_CONIN
	call BDOS
	call crlf
	ld sp,(entry_sp)
	ret

; A = application bank N.
test_bank:
	ld (cur_n),a
	ld de,#msg_bank
	call puts
	ld a,(cur_n)
	call hex
	call crlf

	ld (saved_sp),sp
	ld sp,#CSTACK
	di
	ld a,(cur_n)
	ld c,a
	call CORE_ADDR
	ld sp,(saved_sp)
	ei

	xor a
	ld (fails),a
	ld ix,#checks
	ld hl,#RES
	ld b,#NCHECKS
check_loop:
	push bc
	ld a,0(ix)
	or a
	jr z,check_next
	ld e,1(ix)
	cp #K_LIT
	jr z,have_want
	cp #K_SAME
	jr z,want_same
	cp #K_LATCH
	jr z,want_latch
	ld a,(cur_n)
	add a,a
	add a,a
	add a,a
	add a,a
	or e
	ld e,a
	jr have_want
want_latch:
	ld a,(cur_n)
	or e
	ld e,a
	jr have_want
want_same:
	push hl
	ld hl,#RES
	ld d,#0
	add hl,de
	ld e,(hl)
	pop hl
have_want:
	ld a,(hl)
	cp e
	jr z,check_next
	ld (got),a
	ld a,e
	ld (want),a
	ld a,(fails)
	inc a
	ld (fails),a
	ld de,#msg_fail
	call puts
	ld e,2(ix)
	ld d,3(ix)
	call puts
	ld de,#msg_got
	call puts
	ld a,(got)
	call hex
	ld de,#msg_want
	call puts
	ld a,(want)
	call hex
	call crlf
check_next:
	inc hl
	ld de,#4
	add ix,de
	pop bc
	djnz check_loop

	ld a,(fails)
	or a
	jr nz,bank_failed
	ld de,#msg_bank_pass
	jp puts
bank_failed:
	ld b,a
	ld a,(total_fails)
	add a,b
	ld (total_fails),a
	ld a,b
	call hex
	ld de,#msg_bank_fail
	jp puts

; ---------------------------------------------------------------------------
; Copied to CORE_ADDR and run there.  Entry: C = application bank N,
; interrupts disabled, SP in common memory.  Linear code; every data address is
; a probe address or common memory.
core_start:
	ld a,c
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a				; B = N << 4

	; 1. mode 10, bank 7: save, then sign
	ld a,#ROMDIS_BIT | 7
	out (BANK_PORT),a
	ld a,(0x1fff)
	ld (SAVE7 + 0),a
	ld a,(0x2000)
	ld (SAVE7 + 1),a
	ld a,(0x9000)
	ld (SAVE7 + 2),a
	ld a,(0xbfff)
	ld (SAVE7 + 3),a
	ld a,(0xc800)
	ld (SAVE7 + 4),a
	ld a,(0xdfff)
	ld (SAVE7 + 5),a
	ld a,#0x71
	ld (0x1fff),a
	ld a,#0x72
	ld (0x2000),a
	ld a,#0x73
	ld (0x9000),a
	ld a,#0x74
	ld (0xbfff),a
	ld a,#0x75
	ld (0xc800),a
	ld a,#0x76
	ld (0xdfff),a

	; 2. mode 10, bank N: save, then sign
	ld a,c
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld a,(0x1ffe)
	ld (SAVEN + 0),a
	ld a,(0x1fff)
	ld (SAVEN + 1),a
	ld a,(0x2000)
	ld (SAVEN + 2),a
	ld a,(0x9000)
	ld (SAVEN + 3),a
	ld a,(0xbfff)
	ld (SAVEN + 4),a
	ld a,(0xc800)
	ld (SAVEN + 5),a
	ld a,(0xdfff)
	ld (SAVEN + 6),a
	ld a,b
	or #1
	ld (0x1fff),a
	ld a,b
	or #2
	ld (0x2000),a
	ld a,b
	or #3
	ld (0x9000),a
	ld a,b
	or #4
	ld (0xbfff),a
	ld a,b
	or #5
	ld (0xc800),a
	ld a,b
	or #6
	ld (0xdfff),a
	xor a
	ld (0x1ffe),a
	ld (CTEST),a
	ld a,(0xe000)
	ld (RES + 0),a

	; 3. mode 11: read the map, then write through it
	ld a,c
	or #ROMDIS_BIT | SHADOW_BIT
	out (BANK_PORT),a
	ld a,(0x1fff)
	ld (RES + 1),a
	ld a,(0x2000)
	ld (RES + 2),a
	ld a,(0x9000)
	ld (RES + 3),a
	ld a,(0xbfff)
	ld (RES + 4),a
	ld a,(0xc800)
	ld (RES + 5),a
	ld a,(0xdfff)
	ld (RES + 6),a
	ld a,(0xe000)
	ld (RES + 7),a
	in a,(BANK_PORT)
	ld (RES + 8),a
	ld a,#0xa5
	ld (0x2000),a
	ld a,#0xa6
	ld (0xdfff),a
	ld a,#0x5a
	ld (0x1ffe),a
	ld a,#0xc3
	ld (CTEST),a

	; 4. mode 10, bank N: what mode 11 did to it; restore
	ld a,c
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld a,(0x1fff)
	ld (RES + 9),a
	ld a,(0x2000)
	ld (RES + 10),a
	ld a,(0x9000)
	ld (RES + 11),a
	ld a,(0xbfff)
	ld (RES + 12),a
	ld a,(0xc800)
	ld (RES + 13),a
	ld a,(0xdfff)
	ld (RES + 14),a
	ld a,(0x1ffe)
	ld (RES + 15),a
	ld a,(CTEST)
	ld (RES + 16),a
	in a,(BANK_PORT)
	ld (RES + 17),a
	ld a,(SAVEN + 0)
	ld (0x1ffe),a
	ld a,(SAVEN + 1)
	ld (0x1fff),a
	ld a,(SAVEN + 2)
	ld (0x2000),a
	ld a,(SAVEN + 3)
	ld (0x9000),a
	ld a,(SAVEN + 4)
	ld (0xbfff),a
	ld a,(SAVEN + 5)
	ld (0xc800),a
	ld a,(SAVEN + 6)
	ld (0xdfff),a

	; 5. mode 10, bank 7: what mode 11 did to it; restore
	ld a,#ROMDIS_BIT | 7
	out (BANK_PORT),a
	ld a,(0x2000)
	ld (RES + 18),a
	ld a,(0xdfff)
	ld (RES + 19),a
	ld a,(0x1fff)
	ld (RES + 20),a
	ld a,(SAVE7 + 0)
	ld (0x1fff),a
	ld a,(SAVE7 + 1)
	ld (0x2000),a
	ld a,(SAVE7 + 2)
	ld (0x9000),a
	ld a,(SAVE7 + 3)
	ld (0xbfff),a
	ld a,(SAVE7 + 4)
	ld (0xc800),a
	ld a,(SAVE7 + 5)
	ld (0xdfff),a

	; back to CP/M: mode 10, bank 0
	ld a,#ROMDIS_BIT
	out (BANK_PORT),a
	ret
core_end:

	.ifgt (core_end - core_start) - (SAVE7 - CORE_ADDR)
	.error 1			; the core runs into its save area
	.endif

; ---------------------------------------------------------------------------
checks:
	.db K_SKIP, 0
	.dw lbl_e000_m10
	.db K_NPAT, 1
	.dw lbl_1fff_m11
	.db K_LIT, 0x72
	.dw lbl_2000_m11
	.db K_LIT, 0x73
	.dw lbl_9000_m11
	.db K_LIT, 0x74
	.dw lbl_bfff_m11
	.db K_LIT, 0x75
	.dw lbl_c800_m11
	.db K_LIT, 0x76
	.dw lbl_dfff_m11
	.db K_SAME, 0
	.dw lbl_e000_m11
	.db K_LATCH, ROMDIS_BIT | SHADOW_BIT
	.dw lbl_latch_m11
	.db K_NPAT, 1
	.dw lbl_1fff_m10
	.db K_NPAT, 2
	.dw lbl_2000_m10
	.db K_NPAT, 3
	.dw lbl_9000_m10
	.db K_NPAT, 4
	.dw lbl_bfff_m10
	.db K_NPAT, 5
	.dw lbl_c800_m10
	.db K_NPAT, 6
	.dw lbl_dfff_m10
	.db K_LIT, 0x5a
	.dw lbl_1ffe_m10
	.db K_LIT, 0xc3
	.dw lbl_common
	.db K_LATCH, ROMDIS_BIT
	.dw lbl_latch_m10
	.db K_LIT, 0xa5
	.dw lbl_2000_b7
	.db K_LIT, 0xa6
	.dw lbl_dfff_b7
	.db K_LIT, 0x71
	.dw lbl_1fff_b7
NCHECKS		= (. - checks) / 4

lbl_e000_m10:	.ascii "E000 mode 10$"
lbl_1fff_m11:	.ascii "1FFF mode 11 = app bank$"
lbl_2000_m11:	.ascii "2000 mode 11 = bank 7$"
lbl_9000_m11:	.ascii "9000 mode 11 = bank 7$"
lbl_bfff_m11:	.ascii "BFFF mode 11 = bank 7$"
lbl_c800_m11:	.ascii "C800 mode 11 = bank 7$"
lbl_dfff_m11:	.ascii "DFFF mode 11 = bank 7$"
lbl_e000_m11:	.ascii "E000 mode 11 = common$"
lbl_latch_m11:	.ascii "latch readback, mode 11$"
lbl_1fff_m10:	.ascii "1FFF app bank after mode 11$"
lbl_2000_m10:	.ascii "2000 app bank not hit by mode 11$"
lbl_9000_m10:	.ascii "9000 app bank not hit by mode 11$"
lbl_bfff_m10:	.ascii "BFFF app bank not hit by mode 11$"
lbl_c800_m10:	.ascii "C800 mode 10 = app bank, not common$"
lbl_dfff_m10:	.ascii "DFFF mode 10 = app bank, not common$"
lbl_1ffe_m10:	.ascii "1FFE mode 11 write -> app bank$"
lbl_common:	.ascii "E2FF mode 11 write -> common$"
lbl_latch_m10:	.ascii "latch readback, mode 10$"
lbl_2000_b7:	.ascii "2000 mode 11 write -> bank 7$"
lbl_dfff_b7:	.ascii "DFFF mode 11 write -> bank 7$"
lbl_1fff_b7:	.ascii "1FFF bank 7 not hit by mode 11$"

msg_banner:	.ascii "MAP11 - mode 11 decoder test (MEM_DECODER rev 11)"
		.db 13,10
		.ascii "$"
msg_tpa:	.ascii "TPA ends below E400h; cannot use the E000h reservation."
		.db 13,10
		.ascii "$"
msg_latch:	.ascii "latch at entry: $"
msg_latch_bad:	.ascii "expected 10 (mode 10, bank 0); not testing."
		.db 13,10
		.ascii "$"
msg_bank:	.ascii "application bank $"
msg_key:	.ascii "press a key$"
msg_fail:	.ascii "  FAIL $"
msg_got:	.ascii ": got $"
msg_want:	.ascii " want $"
msg_bank_pass:	.ascii "  all checks pass"
		.db 13,10
		.ascii "$"
msg_bank_fail:	.ascii " checks failed"
		.db 13,10
		.ascii "$"
msg_pass:	.ascii "MAP11: PASS"
		.db 13,10
		.ascii "$"
msg_fail_all:	.ascii "MAP11: FAIL"
		.db 13,10
		.ascii "$"

; ---------------------------------------------------------------------------
puts:
	push bc
	push hl
	push ix
	ld c,#BDOS_PRINT
	call BDOS
	pop ix
	pop hl
	pop bc
	ret

crlf:
	ld a,#13
	call conout
	ld a,#10
	jr conout

hex:
	push af
	rrca
	rrca
	rrca
	rrca
	call nibble
	pop af
nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
conout:
	push bc
	push de
	push hl
	push ix
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop ix
	pop hl
	pop de
	pop bc
	ret

entry_sp:	.dw 0
saved_sp:	.dw 0
entry_latch:	.db 0
cur_n:		.db 0
fails:		.db 0
total_fails:	.db 0
got:		.db 0
want:		.db 0

		.ds 64
stack_top:
