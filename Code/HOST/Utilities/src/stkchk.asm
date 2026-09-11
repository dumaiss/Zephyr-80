; STKCHK.COM — report how deep the BIOS private stacks actually go.
;
; The Zephyr BIOS runs three private stacks in the 384-byte window at
; FE80h-FFFFh.  They are disjoint runs, not nested frames on one stack, so each
; has a fixed ceiling and a fixed floor:
;
;   FFF0h  boot / warm-boot     grows down toward FF80h   112 bytes
;   FF80h  console and storage  grows down toward FF00h   128 bytes
;   FF00h  IOCALL / IOCBULK     grows down toward FEC0h    64 bytes
;   FEC0h  ROM service gate     grows down toward FE80h    64 bytes
;
; The last two were one 128-byte run until the ROM service gate needed a stack
; of its own: a ROM service cannot run on a caller's stack, because that stack
; is usually in the TPA and shadow mode turns reads of it into ROM.  The split
; was made on the measurement below rather than on a guess -- the transport
; stack was using 16 bytes of its 128.
;
; Nothing has ever measured them.  That was tolerable while the resident BIOS
; had room to spare; it is not tolerable under the executable-ROM plan, which
; leaves roughly 300 bytes of margin at a DC00h resident base.  A stack window
; that turns out to be short would consume that margin and move the boundary.
;
; How it works: cold boot paints FE80h-FFEFh with CBIOS_STACK_FILL_BYTE (A5h)
; before any stack pointer is set.  Stack use overwrites it from the top
; downward.  The lowest address in each run that no longer holds A5h is that
; stack's high-water mark.
;
; Two properties of the measurement worth knowing when reading the output:
;
;   It UNDERSTATES.  A frame byte that happens to equal A5h reads as untouched.
;   The true depth is therefore at least what is reported, never less.
;
;   It is CUMULATIVE since cold boot.  Warm boot does not repaint, so the marks
;   accumulate across every program run since power-on.  To measure a specific
;   workload, cold boot, run it, then run this.  To measure the BIOS at rest,
;   cold boot and run this first.
;
; Reads memory and calls only BDOS console output.  No IO Controller traffic, so
; it reports when the link is dead.

	.module stkchk
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

FILL		= 0xa5

STACK_GUARD	= 0xfe80		; CBIOS_STACK_GUARD
GATE_TOP	= 0xfec0		; CBIOS_ROM_GATE_STACK_TOP
XPORT_TOP	= 0xff00		; CBIOS_XPORT_STACK_TOP
CONSOLE_TOP	= 0xff80		; CBIOS_CONSOLE_STACK_TOP
BOOT_TOP	= 0xfff0		; CBIOS_STACK_TOP

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	; Each row: floor in HL, ceiling in DE.
	ld de,#msg_row_boot
	call puts
	ld hl,#CONSOLE_TOP		; boot stack floor
	ld de,#BOOT_TOP
	call report

	ld de,#msg_row_console
	call puts
	ld hl,#XPORT_TOP
	ld de,#CONSOLE_TOP
	call report

	ld de,#msg_row_xport
	call puts
	ld hl,#GATE_TOP
	ld de,#XPORT_TOP
	call report

	ld de,#msg_row_gate
	call puts
	ld hl,#STACK_GUARD
	ld de,#GATE_TOP
	call report

	; The fill is laid down by cold boot.  If the whole window still holds
	; it, either nothing has run yet or this firmware predates the probe --
	; and those two look identical from here, so say so rather than report
	; three zeros as though they were measurements.
	ld a,(total_used)
	or a
	jr nz,main_guard
	ld de,#msg_no_marks
	call puts

main_guard:
	; The guard byte is the floor of the lowest run.  If it is gone, some
	; stack has already left its window and everything above is suspect.
	ld a,(STACK_GUARD)
	cp #FILL
	ld de,#msg_guard_ok
	jr z,main_guard_out
	ld de,#msg_guard_bad
main_guard_out:
	call puts
	ret

; ---------------------------------------------------------------------------
; report — print used/capacity for one stack run.
;
; In:  HL = floor (lowest address the run may reach)
;      DE = ceiling (stack top; the first push writes ceiling-1)
; Out: prints "nnn of nnn bytes" and a newline.
; Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
report:
	ld (r_floor),hl
	ld (r_ceil),de

	; Scan upward from the floor.  The first byte that no longer holds the
	; fill is the deepest this stack has ever reached.  Stopping at the
	; ceiling means the run was never entered at all.
report_scan:
	ld a,h
	cp d
	jr nz,report_test
	ld a,l
	cp e
	jr z,report_found
report_test:
	ld a,(hl)
	cp #FILL
	jr nz,report_found
	inc hl
	jr report_scan

report_found:
	ld (r_deep),hl

	; used = ceiling - deepest.  Accumulate it first: main reads the total
	; only to tell "every run clean" apart from "no fill anywhere", which
	; are different answers and must not print the same.
	call r_used
	ld a,l
	ld hl,#total_used
	add a,(hl)
	ld (hl),a

	call r_used
	ld a,l
	call print_dec_byte

	ld de,#msg_of
	call puts

	; capacity = ceiling - floor
	ld hl,(r_ceil)
	ld de,(r_floor)
	or a
	sbc hl,de
	ld a,l
	call print_dec_byte

	ld de,#msg_bytes
	jp puts

; HL = ceiling - deepest.
r_used:
	ld hl,(r_ceil)
	ld de,(r_deep)
	or a
	sbc hl,de
	ret

r_floor:	.ds 2
r_ceil:		.ds 2
r_deep:		.ds 2

; ---------------------------------------------------------------------------
; Output helpers
; ---------------------------------------------------------------------------
puts:
	push hl
	push bc
	ld c,#BDOS_PRINT
	call BDOS
	pop bc
	pop hl
	ret

conout:
	push hl
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	pop hl
	ret

; Three-digit decimal, leading zeros suppressed to spaces so the columns line
; up.  Values here never exceed 255.
print_dec_byte:
	ld h,#0				; H = "a digit has been printed"
	ld b,#100
	call pdb_digit
	ld b,#10
	call pdb_digit
	add a,#0x30
	jp conout

pdb_digit:
	ld c,#0
pdb_loop:
	cp b
	jr c,pdb_done
	sub b
	inc c
	jr pdb_loop
pdb_done:
	push af
	ld a,c
	or a
	jr nz,pdb_show
	ld a,h
	or a
	jr nz,pdb_show
	ld a,#' '
	call conout
	pop af
	ret
pdb_show:
	ld h,#1
	ld a,c
	add a,#0x30
	call conout
	pop af
	ret

msg_banner:
	.ascii "STKCHK: BIOS private stack high-water, since cold boot"
	.db 13,10
	.ascii "  (understates: a frame byte equal to A5h reads as unused)"
	.db 13,10,'$'

msg_row_boot:	.ascii "  boot    FFF0h  $"
msg_row_console:.ascii "  console FF80h  $"
msg_row_xport:	.ascii "  xport   FF00h  $"
msg_row_gate:	.ascii "  romgate FEC0h  $"
msg_of:		.ascii " of $"
msg_bytes:	.db 13,10,'$'

msg_no_marks:
	.ascii "  no fill found anywhere: firmware predates the stack probe,"
	.db 13,10
	.ascii "  or cold boot did not paint the window.  Figures above are"
	.db 13,10
	.ascii "  not measurements."
	.db 13,10,'$'

msg_guard_ok:
	.ascii "  guard   FE80h  intact"
	.db 13,10,'$'
msg_guard_bad:
	.ascii "  guard   FE80h  VIOLATED - a stack has left its window"
	.db 13,10,'$'

total_used:	.db 0

entry_sp:	.ds 2
	.ds 64
stack_top:
