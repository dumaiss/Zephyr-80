; XING.COM -- prove Phase 1 steps 3-5 of the banked OS on hardware.
;
; ../CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md, Phase 1:
;
;   step 3  common crossing layer: mode-preserving bank select, ISR stack
;   step 4  BIOS latch writers restore the mode they found; drive A's read no
;           longer forces EI
;   step 5  the bank primitives refuse bank 7, the OS bank
;
; Nothing in the OS enters mode 11 yet, so this program does it itself and
; calls the BIOS from there, the way ZSDOS will from bank 7.
;
;   part 1  SELMEM 7, SETBNK 7 and XMOVE with bank 7 return FFh and change
;           nothing; SETBNK 0 still works
;   part 2  from common memory: SELMEM 5/0 in mode 10 and in mode 11 (mode 11
;           must survive); a cross-bank MOVE 5->0 called in mode 11 copies the
;           data and returns in mode 11
;   part 3  drive A and drive B: the same record read in mode 10 and in mode
;           11 is identical, and the mode-11 read returns in mode 11
;   part 4  drive A read preserves the caller's interrupt state, off and on
;
; The program sits in the caller window (0000h-1FFFh), which stays mapped in
; mode 11, so it can switch to mode 11 itself for part 3.  Changing the bank
; replaces that window too, so part 2 runs from a core copied to C000h.  Its
; buffers borrow C000h-C3FFh of the TPA.
;
; It calls BIOS entries at fixed addresses and checks they are jumps first.
; It exits by warm boot after a key press, because it selects drives behind
; ZSDOS's back.

	.module xing
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONIN	= 0x01
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

BIOS_SELDSK	= 0xda1b
BIOS_SETTRK	= 0xda1e
BIOS_SETSEC	= 0xda21
BIOS_SETDMA	= 0xda24
BIOS_READ	= 0xda27
EXT_MOVE	= 0xda33
EXT_XMOVE	= 0xda36
EXT_SELMEM	= 0xda39
EXT_SETBNK	= 0xda3c

BANK_PORT	= 0x00
MODE10		= 0x10
MODE11		= 0x18
REJECTED	= 0xff

CORE_ADDR	= 0xc000
BUF1		= 0xc100
BUF2		= 0xc180
RES		= 0xc300
CSTACK		= 0xc3f0
CORE_LIMIT	= 0xc400

PAT_SRC		= 0x3000		; in bank 5
PAT_DST		= 0x4000		; in bank 0, above this program
PAT_LEN		= 16
PAT_FIRST	= 0x50

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld de,#msg_banner
	call puts

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
	cp #MODE10
	jr z,latch_ok
	ld de,#msg_latch
	call puts
	jp finish
latch_ok:
	ld hl,#bios_entries
	ld b,#N_BIOS_ENTRIES
table_loop:
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld a,(de)
	cp #0xc3
	jr nz,table_bad
	djnz table_loop
	jr part1
table_bad:
	ld de,#msg_table
	call puts
	jp finish

; ---- part 1: bank 7 is refused -----------------------------------------------
part1:
	ld de,#msg_part1
	call puts
	ld a,#7
	call EXT_SELMEM
	ld e,#REJECTED
	ld hl,#lbl_selmem7
	call check
	in a,(BANK_PORT)
	ld e,#MODE10
	ld hl,#lbl_selmem7_latch
	call check
	ld a,#7
	call EXT_SETBNK
	ld e,#REJECTED
	ld hl,#lbl_setbnk7
	call check
	ld bc,#0x0007			; C = source 7, B = destination 0
	call EXT_XMOVE
	ld e,#REJECTED
	ld hl,#lbl_xmove_src7
	call check
	ld bc,#0x0700			; C = source 0, B = destination 7
	call EXT_XMOVE
	ld e,#REJECTED
	ld hl,#lbl_xmove_dst7
	call check
	xor a
	call EXT_SETBNK
	ld e,#0
	ld hl,#lbl_setbnk0
	call check

; ---- part 2: bank changes from common memory ---------------------------------
	ld de,#msg_part2
	call puts
	ld hl,#core_start
	ld de,#CORE_ADDR
	ld bc,#core_end - core_start
	ldir
	ld (saved_sp),sp
	ld sp,#CSTACK
	di
	call CORE_ADDR
	ld sp,(saved_sp)
	ei

	ld a,(RES + 0)
	ld e,#0
	ld hl,#lbl_selmem5
	call check
	ld a,(RES + 1)
	ld e,#MODE10 | 5
	ld hl,#lbl_selmem5_m10
	call check
	ld a,(RES + 2)
	ld e,#MODE10
	ld hl,#lbl_selmem0_m10
	call check
	ld a,(RES + 3)
	ld e,#MODE11 | 5
	ld hl,#lbl_selmem5_m11
	call check
	ld a,(RES + 4)
	ld e,#MODE11
	ld hl,#lbl_selmem0_m11
	call check
	ld a,(RES + 5)
	ld e,#0
	ld hl,#lbl_xmove_ok
	call check
	ld a,(RES + 6)
	ld e,#MODE11
	ld hl,#lbl_move_latch
	call check
	ld hl,#PAT_DST
	ld b,#PAT_LEN
	ld c,#PAT_FIRST
	ld d,#0
move_cmp:
	ld a,(hl)
	cp c
	jr z,move_cmp_next
	inc d
move_cmp_next:
	inc hl
	inc c
	djnz move_cmp
	ld a,d
	ld e,#0
	ld hl,#lbl_move_data
	call check

; ---- part 3: disk reads in mode 11 -------------------------------------------
	ld de,#msg_part3
	call puts
	xor a
	call disk_test
	ld a,#1
	call disk_test

; ---- part 4: drive A read keeps the caller's interrupt state -----------------
	ld de,#msg_part4
	call puts
	call select_a
	di
	call BIOS_READ
	ld a,i				; with DI, P/V is IFF2 and reliable
	ld a,#0
	jp po,iff_off_read
	inc a
iff_off_read:
	ei
	ld e,#0
	ld hl,#lbl_iff_off
	call check

	call BIOS_READ
	ld a,i
	jp pe,iff_on
	ld a,i				; NMOS erratum: retry a false "off"
	jp pe,iff_on
	xor a
	jr iff_on_read
iff_on:
	ld a,#1
iff_on_read:
	ld e,#1
	ld hl,#lbl_iff_on
	call check

	; Leave the BIOS where CP/M expects it.
	call select_a
	ld bc,#0x0080
	call BIOS_SETDMA

	ld a,(fails)
	or a
	ld de,#msg_pass
	jr z,summary
	call hex
	ld de,#msg_fail_all
summary:
	call puts

finish:
	ld de,#msg_key
	call puts
	ld c,#BDOS_CONIN
	call BDOS
	jp 0				; warm boot: drives were selected behind ZSDOS

; A = drive.  Read track 0 sector 0 into BUF1 in mode 10 and into BUF2 in
; mode 11, and compare.  A drive SELDSK refuses is reported and skipped.
disk_test:
	ld (drive),a
	ld de,#msg_drive
	call puts
	ld a,(drive)
	add a,#'A'
	call conout
	call crlf
	ld a,(drive)
	ld c,a
	ld e,#0
	call BIOS_SELDSK
	ld a,h
	or l
	jr nz,disk_present
	ld de,#msg_nodrive
	jp puts
disk_present:
	call seek_record0
	ld bc,#BUF1
	call BIOS_SETDMA
	call BIOS_READ
	ld e,#0
	ld hl,#lbl_read_m10
	call check

	ld a,#MODE11
	out (BANK_PORT),a
	ld bc,#BUF2
	call BIOS_SETDMA
	call BIOS_READ
	ld b,a
	in a,(BANK_PORT)
	ld c,a
	ld a,#MODE10
	out (BANK_PORT),a

	push bc
	ld a,b
	ld e,#0
	ld hl,#lbl_read_m11
	call check
	pop bc
	ld a,c
	ld e,#MODE11
	ld hl,#lbl_read_latch
	call check

	ld hl,#BUF1
	ld de,#BUF2
	ld b,#128
	ld c,#0
disk_cmp:
	ld a,(de)
	cp (hl)
	jr z,disk_cmp_next
	inc c
disk_cmp_next:
	inc hl
	inc de
	djnz disk_cmp
	ld a,c
	ld e,#0
	ld hl,#lbl_read_same
	jp check

select_a:
	ld c,#0
	ld e,#0
	call BIOS_SELDSK
	call seek_record0
	ld bc,#BUF1
	jp BIOS_SETDMA

seek_record0:
	ld bc,#0
	call BIOS_SETTRK
	ld bc,#0
	jp BIOS_SETSEC

; A = got, E = want, HL = '$'-terminated label.  Prints only failures.
check:
	cp e
	ret z
	ld (got),a
	ld a,e
	ld (want),a
	ld a,(fails)
	inc a
	ld (fails),a
	push hl
	ld de,#msg_fail
	call puts
	pop de
	call puts
	ld de,#msg_got
	call puts
	ld a,(got)
	call hex
	ld de,#msg_want
	call puts
	ld a,(want)
	call hex
	jp crlf

; ---------------------------------------------------------------------------
; Copied to CORE_ADDR and run there with SP in common memory and interrupts
; disabled.  Relative jumps only; absolute addresses are BIOS entries, probe
; addresses and common memory.
core_start:
	; SELMEM in mode 10
	ld a,#5
	call EXT_SELMEM
	ld (RES + 0),a
	in a,(BANK_PORT)
	ld (RES + 1),a
	xor a
	call EXT_SELMEM
	in a,(BANK_PORT)
	ld (RES + 2),a

	; SELMEM in mode 11: the mode must survive
	ld a,#MODE11
	out (BANK_PORT),a
	ld a,#5
	call EXT_SELMEM
	in a,(BANK_PORT)
	ld (RES + 3),a
	xor a
	call EXT_SELMEM
	in a,(BANK_PORT)
	ld (RES + 4),a
	ld a,#MODE10
	out (BANK_PORT),a

	; pattern in bank 5, cleared destination in bank 0
	ld a,#MODE10 | 5
	out (BANK_PORT),a
	ld hl,#PAT_SRC
	ld b,#PAT_LEN
	ld a,#PAT_FIRST
core_fill:
	ld (hl),a
	inc hl
	inc a
	djnz core_fill
	ld a,#MODE10
	out (BANK_PORT),a
	ld hl,#PAT_DST
	ld b,#PAT_LEN
	xor a
core_clear:
	ld (hl),a
	inc hl
	djnz core_clear

	; cross-bank MOVE 5 -> 0, called in mode 11
	ld a,#MODE11
	out (BANK_PORT),a
	ld bc,#0x0005			; C = source 5, B = destination 0
	call EXT_XMOVE
	ld (RES + 5),a
	ld de,#PAT_SRC
	ld hl,#PAT_DST
	ld bc,#PAT_LEN
	call EXT_MOVE
	in a,(BANK_PORT)
	ld (RES + 6),a
	ld a,#MODE10
	out (BANK_PORT),a
	ret
core_end:

; ---------------------------------------------------------------------------
bios_entries:
	.dw BIOS_SELDSK, BIOS_SETTRK, BIOS_SETSEC, BIOS_SETDMA, BIOS_READ
	.dw EXT_MOVE, EXT_XMOVE, EXT_SELMEM, EXT_SETBNK
N_BIOS_ENTRIES	= (. - bios_entries) / 2

lbl_selmem7:		.ascii "SELMEM 7 refused$"
lbl_selmem7_latch:	.ascii "latch unchanged after SELMEM 7$"
lbl_setbnk7:		.ascii "SETBNK 7 refused$"
lbl_xmove_src7:		.ascii "XMOVE from bank 7 refused$"
lbl_xmove_dst7:		.ascii "XMOVE to bank 7 refused$"
lbl_setbnk0:		.ascii "SETBNK 0 accepted$"
lbl_selmem5:		.ascii "SELMEM 5 accepted$"
lbl_selmem5_m10:	.ascii "SELMEM 5 in mode 10: latch$"
lbl_selmem0_m10:	.ascii "SELMEM 0 in mode 10: latch$"
lbl_selmem5_m11:	.ascii "SELMEM 5 in mode 11: latch$"
lbl_selmem0_m11:	.ascii "SELMEM 0 in mode 11: latch$"
lbl_xmove_ok:		.ascii "XMOVE 5->0 accepted$"
lbl_move_latch:		.ascii "MOVE from mode 11: latch$"
lbl_move_data:		.ascii "MOVE 5->0: bytes wrong$"
lbl_read_m10:		.ascii "  READ mode 10 status$"
lbl_read_m11:		.ascii "  READ mode 11 status$"
lbl_read_latch:		.ascii "  READ mode 11: latch after$"
lbl_read_same:		.ascii "  mode 10/11 records: bytes differ$"
lbl_iff_off:		.ascii "READ with DI: interrupts on after$"
lbl_iff_on:		.ascii "READ with EI: interrupts on after$"

msg_banner:	.ascii "XING - banked OS Phase 1 steps 3-5"
		.db 13,10
		.ascii "$"
msg_tpa:	.ascii "TPA ends below C400h; cannot borrow C000h."
		.db 13,10
		.ascii "$"
msg_latch:	.ascii "latch is not 10h (mode 10, bank 0); not testing."
		.db 13,10
		.ascii "$"
msg_table:	.ascii "BIOS entry is not a JP: wrong BIOS for this tool."
		.db 13,10
		.ascii "$"
msg_part1:	.ascii "1 bank 7 refused"
		.db 13,10
		.ascii "$"
msg_part2:	.ascii "2 SELMEM / MOVE in modes 10 and 11"
		.db 13,10
		.ascii "$"
msg_part3:	.ascii "3 disk READ in mode 11"
		.db 13,10
		.ascii "$"
msg_part4:	.ascii "4 drive A READ keeps interrupt state"
		.db 13,10
		.ascii "$"
msg_drive:	.ascii " drive $"
msg_nodrive:	.ascii "  no drive, skipped"
		.db 13,10
		.ascii "$"
msg_fail:	.ascii " FAIL $"
msg_got:	.ascii ": got $"
msg_want:	.ascii " want $"
msg_pass:	.ascii "XING: PASS"
		.db 13,10
		.ascii "$"
msg_fail_all:	.ascii " failed - XING: FAIL"
		.db 13,10
		.ascii "$"
msg_key:	.ascii "press a key (warm boot)$"

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
drive:		.db 0
fails:		.db 0
got:		.db 0
want:		.db 0

		.ds 96
stack_top:
