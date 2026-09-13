; MAP11.COM -- prove the Phase 1 mode 11 decoder on hardware.
;
; Phase 1 of ../CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md.
; MEM_DECODER.pld revision 10 gives latch mode 11 (ROM_DIS | RAM_SHADOW) its
; own map:
;
;   0000-1FFF   latch bank N     caller window
;   2000-BFFF   RAM bank 7       OS body
;   C000-FFFF   RAM bank 0       common
;
; Until revision 10, mode 11 decoded exactly like mode 10.  This program tells
; the two apart, and checks every boundary from both sides, before any OS code
; depends on the new mode.
;
; For each application bank N tested (0, then 5):
;
;   1. mode 10, bank 7    sign 1FFF 2000 8000 BFFF with 71 72 73 74
;   2. mode 10, bank N    sign the same addresses with N1 N2 N3 N4
;   3. mode 11            read them back: 1FFF must be N1, the body 72-74,
;                         C000 must match mode 10, and the latch 18h|N.
;                         Then write 2000=A5, 1FFE=5A and a common byte.
;   4. mode 10, bank N    the body is still N2-N4; the 1FFE and common
;                         writes from mode 11 arrived
;   5. mode 10, bank 7    the 2000 write from mode 11 arrived; 1FFF untouched
;
; Changing the latch replaces 0000-BFFF, including this program, so the mapping
; walk is a linear core copied to C000h and run from there with its stack in
; common memory and interrupts disabled.  The core contains no absolute control
; transfers; its results go to a common buffer and are checked back here in
; mode 10, bank 0.
;
; Bank 5 is used because nothing in the baseline OS touches banks 4-7 after
; boot.  It borrows C000h-C3FFh of the TPA, which is below the CCP at C400h, so
; it returns to the CCP -- after a key press, because the console's warm-boot
; redraw would otherwise take the results off the screen.

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

CORE_ADDR	= 0xc000		; common in modes 10 and 11
CTEST		= 0xc2ff		; common byte written from mode 11
RES		= 0xc300		; core results
CSTACK		= 0xc3f0
CORE_LIMIT	= 0xc400		; the CCP starts here

; Check kinds.  Each check entry: kind, value, label address.
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

	; The TPA must reach past the borrowed C000h-C3FFh.
	ld hl,(BDOS + 1)
	ld de,#CORE_LIMIT
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
	xor a
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
	; fall through

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
	; K_NPAT
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
; interrupts disabled, SP in common memory.  Linear code, no absolute control
; transfers; every data address is either a probe address or common memory.
core_start:
	ld a,c
	add a,a
	add a,a
	add a,a
	add a,a
	ld b,a				; B = N << 4

	; 1. mode 10, bank 7: bank 7's own signatures
	ld a,#ROMDIS_BIT | 7
	out (BANK_PORT),a
	ld a,#0x71
	ld (0x1fff),a
	ld a,#0x72
	ld (0x2000),a
	ld a,#0x73
	ld (0x8000),a
	ld a,#0x74
	ld (0xbfff),a

	; 2. mode 10, bank N: the application bank's signatures
	ld a,c
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld a,b
	or #1
	ld (0x1fff),a
	ld a,b
	or #2
	ld (0x2000),a
	ld a,b
	or #3
	ld (0x8000),a
	ld a,b
	or #4
	ld (0xbfff),a
	xor a
	ld (0x1ffe),a
	ld (CTEST),a
	ld a,(0xc000)
	ld (RES + 0),a

	; 3. mode 11: read the map, then write through it
	ld a,c
	or #ROMDIS_BIT | SHADOW_BIT
	out (BANK_PORT),a
	ld a,(0x1fff)
	ld (RES + 1),a
	ld a,(0x2000)
	ld (RES + 2),a
	ld a,(0x8000)
	ld (RES + 3),a
	ld a,(0xbfff)
	ld (RES + 4),a
	ld a,(0xc000)
	ld (RES + 5),a
	in a,(BANK_PORT)
	ld (RES + 6),a
	ld a,#0xa5
	ld (0x2000),a
	ld a,#0x5a
	ld (0x1ffe),a
	ld a,#0xc3
	ld (CTEST),a

	; 4. mode 10, bank N: what mode 11 did to the application bank
	ld a,c
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld a,(0x1fff)
	ld (RES + 7),a
	ld a,(0x2000)
	ld (RES + 8),a
	ld a,(0x8000)
	ld (RES + 9),a
	ld a,(0xbfff)
	ld (RES + 10),a
	ld a,(0x1ffe)
	ld (RES + 11),a
	ld a,(CTEST)
	ld (RES + 12),a
	in a,(BANK_PORT)
	ld (RES + 13),a

	; 5. mode 10, bank 7: what mode 11 did to bank 7
	ld a,#ROMDIS_BIT | 7
	out (BANK_PORT),a
	ld a,(0x2000)
	ld (RES + 14),a
	ld a,(0x1fff)
	ld (RES + 15),a
	ld a,(0xbfff)
	ld (RES + 16),a

	; back to CP/M: mode 10, bank 0
	ld a,#ROMDIS_BIT
	out (BANK_PORT),a
	ret
core_end:

; ---------------------------------------------------------------------------
checks:
	.db K_SKIP, 0
	.dw lbl_c000_m10
	.db K_NPAT, 1
	.dw lbl_1fff_m11
	.db K_LIT, 0x72
	.dw lbl_2000_m11
	.db K_LIT, 0x73
	.dw lbl_8000_m11
	.db K_LIT, 0x74
	.dw lbl_bfff_m11
	.db K_SAME, 0
	.dw lbl_c000_m11
	.db K_LATCH, ROMDIS_BIT | SHADOW_BIT
	.dw lbl_latch_m11
	.db K_NPAT, 1
	.dw lbl_1fff_m10
	.db K_NPAT, 2
	.dw lbl_2000_m10
	.db K_NPAT, 3
	.dw lbl_8000_m10
	.db K_NPAT, 4
	.dw lbl_bfff_m10
	.db K_LIT, 0x5a
	.dw lbl_1ffe_m10
	.db K_LIT, 0xc3
	.dw lbl_common
	.db K_LATCH, ROMDIS_BIT
	.dw lbl_latch_m10
	.db K_LIT, 0xa5
	.dw lbl_2000_b7
	.db K_LIT, 0x71
	.dw lbl_1fff_b7
	.db K_LIT, 0x74
	.dw lbl_bfff_b7
NCHECKS		= (. - checks) / 4

lbl_c000_m10:	.ascii "C000 mode 10$"
lbl_1fff_m11:	.ascii "1FFF mode 11 = app bank$"
lbl_2000_m11:	.ascii "2000 mode 11 = bank 7$"
lbl_8000_m11:	.ascii "8000 mode 11 = bank 7$"
lbl_bfff_m11:	.ascii "BFFF mode 11 = bank 7$"
lbl_c000_m11:	.ascii "C000 mode 11 = bank 0$"
lbl_latch_m11:	.ascii "latch readback, mode 11$"
lbl_1fff_m10:	.ascii "1FFF app bank after mode 11$"
lbl_2000_m10:	.ascii "2000 app bank not hit by mode 11$"
lbl_8000_m10:	.ascii "8000 app bank not hit by mode 11$"
lbl_bfff_m10:	.ascii "BFFF app bank not hit by mode 11$"
lbl_1ffe_m10:	.ascii "1FFE mode 11 write -> app bank$"
lbl_common:	.ascii "C2FF mode 11 write -> common$"
lbl_latch_m10:	.ascii "latch readback, mode 10$"
lbl_2000_b7:	.ascii "2000 mode 11 write -> bank 7$"
lbl_1fff_b7:	.ascii "1FFF bank 7 not hit by mode 11$"
lbl_bfff_b7:	.ascii "BFFF bank 7$"

msg_banner:	.ascii "MAP11 - mode 11 decoder test (MEM_DECODER rev 10)"
		.db 13,10
		.ascii "$"
msg_tpa:	.ascii "TPA ends below C400h; cannot borrow C000h."
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
; DE = '$'-terminated string.  Preserves BC, HL, IX.
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

; A = byte, printed as two hex digits.  Preserves BC, HL, IX.
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
