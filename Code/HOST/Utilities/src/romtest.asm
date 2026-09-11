; ROMTEST.COM — prove the executable-ROM service gate on hardware.
;
; Phase 2 of ../CPM2.2/docs/Zephyr80_Executable_ROM_Service_Architecture.md.
; The architecture moves bulky BIOS code into ROM and calls it through a
; resident gate that briefly replaces the low 48 KiB with a ROM page.  Nothing
; about that is observable from a memory map or a decoder equation; it either
; works on the machine or it does not.  These four checks are what "works"
; means, in the order they have to hold:
;
;   IDENT      The gate reached ROM page 4 and returned.  Until this passes,
;              nothing else is meaningful.
;   ECHO       Arguments survive in both directions.  Registers cross two latch
;              writes and a memory-map change.
;   WRITE_SIG  A service wrote this program's buffer -- memory the service
;              cannot read, from a source this program cannot see.  This is the
;              property the whole architecture leans on: shadow mode replaces
;              reads only, so a disk read can deliver a sector straight to a
;              caller's DMA address with no staging buffer.
;   LATCH      The banking latch came back byte-identical.  A gate that leaves
;              the latch wrong does not fail here; it fails later, somewhere
;              else, as a machine that has quietly changed memory map.
;
; The gate is called at its absolute address because it has no BIOS jump table
; entry yet -- the extended table is full, and the entry would land on the boot
; code.  So the prologue is verified before the call: a stale address here would
; otherwise mean jumping into whatever occupies F883h in a different build, with
; interrupts about to be disabled and the memory map about to change.  Checking
; three bytes costs nothing and turns a crash into a message.
;
; Rebuild this whenever the gate moves.  It will move: when the console is
; ROM-resident and the resident base is rebased to DC00h, the gate belongs in
; core BIOS with the rest of the resident infrastructure.

	.module romtest
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

BANK_PORT	= 0x00

; Gate entry, and the first three bytes expected there: LD (FE0Ch),A.
ROM_GATE	= 0xf883
GATE_SIG0	= 0x32
GATE_SIG1	= 0x0c
GATE_SIG2	= 0xfe

ROMSVC_IDENT	= 0x00
ROMSVC_ECHO	= 0x01
ROMSVC_WRITE_SIG = 0x02
ROMSVC_SPIN	= 0x03
SPIN_UNITS	= 250			; ms per call
SPIN_CALLS	= 4			; ~1 second in total
ROMSVC_MAGIC	= 0x5a
ROMSVC_SIGLEN	= 16

ECHO_IN		= 0x1234		; arbitrary; ECHO must return this + 1

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	; ---- gate prologue ----
	ld de,#msg_gate
	call puts
	ld a,(ROM_GATE)
	cp #GATE_SIG0
	jr nz,gate_bad
	ld a,(ROM_GATE + 1)
	cp #GATE_SIG1
	jr nz,gate_bad
	ld a,(ROM_GATE + 2)
	cp #GATE_SIG2
	jr nz,gate_bad
	call pass
	jr do_ident

gate_bad:
	call fail
	ld de,#msg_gate_stale
	jp puts			; every later test would call into it blind

	; ---- IDENT ----
do_ident:
	ld de,#msg_ident
	call puts
	in a,(BANK_PORT)
	ld (latch_before),a
	ld a,#ROMSVC_IDENT
	call ROM_GATE
	ld (ident_got),a
	in a,(BANK_PORT)
	ld (latch_after),a
	ld a,(ident_got)
	cp #ROMSVC_MAGIC
	jr nz,ident_fail
	call pass
	jr do_echo
ident_fail:
	call fail
	ld de,#msg_got
	call puts
	ld a,(ident_got)
	call print_hex_byte
	call crlf

	; ---- ECHO ----
do_echo:
	ld de,#msg_echo
	call puts
	ld hl,#ECHO_IN
	ld a,#ROMSVC_ECHO
	call ROM_GATE
	ld de,#(ECHO_IN + 1)
	or a
	sbc hl,de
	ld a,h
	or l
	jr nz,echo_fail
	call pass
	jr do_write
echo_fail:
	call fail

	; ---- WRITE_SIG ----
do_write:
	ld de,#msg_write
	call puts
	ld hl,#sigbuf
	ld de,#sigbuf
	ld bc,#ROMSVC_SIGLEN
	ld (hl),#0x00		; clear, so a no-op service cannot pass
	inc de
	dec bc
	ldir
	ld de,#sigbuf
	ld a,#ROMSVC_WRITE_SIG
	call ROM_GATE

	ld hl,#sigbuf
	ld de,#expect_sig
	ld b,#ROMSVC_SIGLEN
write_cmp:
	ld a,(de)
	cp (hl)
	jr nz,write_fail
	inc hl
	inc de
	djnz write_cmp
	call pass
	jr do_latch
write_fail:
	call fail
	ld de,#msg_got
	call puts
	ld de,#sigbuf
	call puts_n		; prints ROMSVC_SIGLEN bytes, printable or dot
	call crlf

	; ---- LATCH ----
do_latch:
	ld de,#msg_latch
	call puts
	ld a,(latch_before)
	ld b,a
	ld a,(latch_after)
	cp b
	jr nz,latch_fail
	call pass
	jr do_vector
latch_fail:
	call fail
	ld de,#msg_latch_detail
	call puts
	ld a,(latch_before)
	call print_hex_byte
	ld a,#'>'
	call conout
	ld a,(latch_after)
	call print_hex_byte
	call crlf

	; ---- interrupt policy ----
	;
	; The gate leaves interrupts enabled when the IM2 vector page is in the
	; common window, because the handler it points at is still mapped while
	; ROM is.  Below C0h the table is in the TPA, which is ROM for the
	; duration, and the gate has no choice but to disable.  Report which
	; case this machine is in: it decides whether a long service is safe.
do_vector:
	ld de,#msg_vector
	call puts
	ld a,i
	ld (vec_page),a
	call print_hex_byte
	ld a,#' '
	call conout
	ld a,(vec_page)
	cp #0xc0
	jr c,vector_low
	ld de,#msg_vector_ei
	call puts
	jr do_spin
vector_low:
	ld de,#msg_vector_di
	call puts

	; ---- long service ----
	;
	; Phase 2's services returned in microseconds, which says nothing about
	; whether interrupts survive a REAL one: the console's cost is the V9958
	; command wait, and a whole-screen fill blocks for milliseconds.  This
	; holds the machine inside ROM for about a second.  If the serial receive
	; path still collects what is typed during that time, interrupts are
	; being taken with ROM mapped over the low 48 KiB -- which is the whole
	; question this phase turns on.
do_spin:
	ld de,#msg_spin
	call puts
	ld b,#SPIN_CALLS
spin_loop:
	push bc
	ld b,#SPIN_UNITS
	ld a,#ROMSVC_SPIN
	call ROM_GATE
	pop bc
	djnz spin_loop
	ld de,#msg_spin_done
	call puts
	ret

; ---------------------------------------------------------------------------
pass:
	ld de,#msg_pass
	jp puts

fail:
	ld de,#msg_fail
	jp puts

crlf:
	ld de,#msg_crlf
	jp puts

; Print ROMSVC_SIGLEN bytes from (DE), substituting '.' for anything outside
; printable ASCII -- a failed write is usually zeros or ROM filler.
puts_n:
	ld b,#ROMSVC_SIGLEN
puts_n_loop:
	ld a,(de)
	inc de
	cp #0x20
	jr c,puts_n_dot
	cp #0x7f
	jr c,puts_n_out
puts_n_dot:
	ld a,#'.'
puts_n_out:
	push bc
	push de
	call conout
	pop de
	pop bc
	djnz puts_n_loop
	ret

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

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call print_hex_nibble
	pop af
print_hex_nibble:
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	jp conout

expect_sig:	.ascii "ZEPHYR80 ROMSVC1"

msg_banner:
	.ascii "ROMTEST: executable-ROM service gate"
	.db 13,10,'$'
msg_gate:	.ascii "  gate prologue at F883h   $"
msg_ident:	.ascii "  IDENT     returns 5Ah    $"
msg_echo:	.ascii "  ECHO      HL crosses     $"
msg_write:	.ascii "  WRITE_SIG ROM to low RAM $"
msg_latch:	.ascii "  LATCH     restored       $"
msg_pass:	.ascii "PASS"
		.db 13,10,'$'
msg_fail:	.ascii "FAIL"
		.db 13,10,'$'
msg_got:	.ascii "            got            $"
msg_crlf:	.db 13,10,'$'
msg_gate_stale:
	.ascii "  The gate is not at F883h in this firmware.  Rebuild ROMTEST"
	.db 13,10
	.ascii "  against the current symbol map; no service was called."
	.db 13,10,'$'
msg_latch_detail:
	.ascii "            before>after   $"
msg_vector:	.ascii "  IM2 vector page I =      $"
msg_vector_ei:
	.ascii "common: services keep EI"
	.db 13,10,'$'
msg_vector_di:
	.ascii "in TPA: services forced DI"
	.db 13,10,'$'
msg_spin:
	.db 13,10
	.ascii "  Holding the machine inside a ROM service for ~1s."
	.db 13,10
	.ascii "  Type on the serial terminal NOW; the characters should"
	.db 13,10
	.ascii "  appear after this line rather than being lost."
	.db 13,10,'$'
msg_spin_done:
	.ascii "  spin done."
	.db 13,10,'$'

vec_page:	.db 0

latch_before:	.db 0
latch_after:	.db 0
ident_got:	.db 0
sigbuf:		.ds 16

entry_sp:	.ds 2
	.ds 64
stack_top:
