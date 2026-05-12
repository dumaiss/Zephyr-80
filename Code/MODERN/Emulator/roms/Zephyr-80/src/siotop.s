; Phase 7 Zephyr SIO topology test
;
; Source format: SDCC/ASxxxx Z80 assembly, assembled with sdasz80.
; This targets the experimental zephyr_siotop MAME machine and validates the
; behavioral four-channel SIO topology.

	.module siotop
	.optsdcc -mz80

	.area _CODE

	.globl reset

EXTA_STAT	= 0x30
EXTA_DATA	= 0x31
EXTB_STAT	= 0x32
EXTB_DATA	= 0x33

INTA_STAT	= 0x34
INTA_DATA	= 0x35
INTB_STAT	= 0x36
INTB_DATA	= 0x37

reset:
	di
	ld	sp, #0xffff

	ld	hl, #msg_boot
	call	exta_puts

	in	a, (#EXTA_STAT)
	bit	3, a
	jp	Z, fail

	in	a, (#EXTB_STAT)
	bit	3, a
	jp	Z, fail

	in	a, (#INTA_STAT)
	bit	2, a
	jp	Z, fail

	in	a, (#INTB_STAT)
	bit	2, a
	jp	Z, fail

	ld	hl, #expected_exta
	call	check_exta

	ld	hl, #expected_extb
	call	check_extb

	ld	hl, #expected_inta
	call	check_inta

	ld	hl, #expected_intb
	call	check_intb

	ld	hl, #msg_pass
	call	exta_puts

done:
	halt
	jr	done

exta_putc:
	push	af
exta_wait_tx:
	in	a, (#EXTA_STAT)
	bit	0, a
	jr	Z, exta_wait_tx
	pop	af
	out	(#EXTA_DATA), a
	ret

exta_getc:
	in	a, (#EXTA_STAT)
	bit	1, a
	jr	Z, exta_getc
	in	a, (#EXTA_DATA)
	ret

exta_puts:
	ld	a, (hl)
	or	a, a
	ret	Z
	call	exta_putc
	inc	hl
	jr	exta_puts

check_exta:
	ld	a, (hl)
	or	a, a
	ret	Z
	push	hl
	call	exta_getc
	pop	hl
	cp	(hl)
	jp	NZ, fail
	call	exta_putc
	inc	hl
	jr	check_exta

extb_putc:
	push	af
extb_wait_tx:
	in	a, (#EXTB_STAT)
	bit	0, a
	jr	Z, extb_wait_tx
	pop	af
	out	(#EXTB_DATA), a
	ret

extb_getc:
	in	a, (#EXTB_STAT)
	bit	1, a
	jr	Z, extb_getc
	in	a, (#EXTB_DATA)
	ret

check_extb:
	ld	a, (hl)
	or	a, a
	ret	Z
	push	hl
	call	extb_getc
	pop	hl
	cp	(hl)
	jp	NZ, fail
	call	extb_putc
	inc	hl
	jr	check_extb

inta_putc:
	push	af
inta_wait_tx:
	in	a, (#INTA_STAT)
	bit	0, a
	jr	Z, inta_wait_tx
	pop	af
	out	(#INTA_DATA), a
	ret

inta_getc:
	in	a, (#INTA_STAT)
	bit	1, a
	jr	Z, inta_getc
	in	a, (#INTA_DATA)
	ret

check_inta:
	ld	a, (hl)
	or	a, a
	ret	Z
	push	hl
	call	inta_getc
	pop	hl
	cp	(hl)
	jp	NZ, fail
	call	inta_putc
	inc	hl
	jr	check_inta

intb_putc:
	push	af
intb_wait_tx:
	in	a, (#INTB_STAT)
	bit	0, a
	jr	Z, intb_wait_tx
	pop	af
	out	(#INTB_DATA), a
	ret

intb_getc:
	in	a, (#INTB_STAT)
	bit	1, a
	jr	Z, intb_getc
	in	a, (#INTB_DATA)
	ret

check_intb:
	ld	a, (hl)
	or	a, a
	ret	Z
	push	hl
	call	intb_getc
	pop	hl
	cp	(hl)
	jp	NZ, fail
	call	intb_putc
	inc	hl
	jr	check_intb

fail:
	ld	hl, #msg_fail
	call	exta_puts

fail_loop:
	halt
	jr	fail_loop

msg_boot:
	.ascii	"Zephyr SIO topology test start"
	.db	0x0a, 0x00

msg_pass:
	.db	0x0a
	.ascii	"PASS"
	.db	0x0a, 0x00

msg_fail:
	.db	0x0a
	.ascii	"FAIL"
	.db	0x0a, 0x00

expected_exta:
	.ascii	"extA"
	.db	0x0d, 0x00

expected_extb:
	.ascii	"extB"
	.db	0x0d, 0x00

expected_inta:
	.ascii	"intA"
	.db	0x0d, 0x00

expected_intb:
	.ascii	"intB"
	.db	0x0d, 0x00
