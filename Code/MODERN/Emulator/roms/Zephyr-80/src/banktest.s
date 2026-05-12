; Zephyr-80 MAME bank/serial proof ROM
;
; Source format: SDCC/ASxxxx Z80 assembly, assembled with sdasz80.
; This ROM targets the experimental zephyr_banktst MAME machine.  It uses the
; Phase 5 behavioral polling serial device, not a real UART or Z80 SIO.

	.module banktest
	.optsdcc -mz80

	.area _CODE

	.globl start

SER_STATUS	= 0x20
SER_DATA	= 0x21
BANK_LOW	= 0x10
BANK_MID	= 0x11
BANK_HIGH	= 0x12
MID_RAM		= 0x80

start:
	ld	sp, #0xffff
	ld	hl, #msg_boot
	call	serial_puts

	ld	b, #0x68	; h
	call	expect_char
	ld	b, #0x65	; e
	call	expect_char
	ld	b, #0x6c	; l
	call	expect_char
	ld	b, #0x70	; p
	call	expect_char
	ld	b, #0x0d
	call	expect_char

	call	check_rx_empty
	ld	hl, #msg_newline
	call	serial_puts

	call	test_high_ram_banks
	call	test_mid_ram_banks

	ld	hl, #msg_pass
	call	serial_puts
	jr	halt_loop

fail:
	ld	hl, #msg_fail
	call	serial_puts

halt_loop:
	halt
	jr	halt_loop

; A = character to send.
serial_putc:
	push	af
wait_tx:
	in	a, (#SER_STATUS)
	bit	0, a
	jr	Z, wait_tx
	pop	af
	out	(#SER_DATA), a
	ret

; HL = zero-terminated string.
serial_puts:
	ld	a, (hl)
	or	a, a
	ret	Z
	call	serial_putc
	inc	hl
	jr	serial_puts

; Returns received character in A.
serial_getc:
wait_rx:
	in	a, (#SER_STATUS)
	bit	1, a
	jr	Z, wait_rx
	in	a, (#SER_DATA)
	ret

; B = expected character.  The received character is echoed.
expect_char:
	call	serial_getc
	call	serial_putc
	cp	b
	ret	Z
	jp	fail

check_rx_empty:
	in	a, (#SER_STATUS)
	bit	1, a
	ret	Z
	jp	fail

test_high_ram_banks:
	ld	a, #0x00
	out	(#BANK_HIGH), a
	ld	hl, #0x8000
	ld	(hl), #0x12

	ld	a, #0x01
	out	(#BANK_HIGH), a
	ld	hl, #0x8000
	ld	(hl), #0x34

	ld	a, #0x00
	out	(#BANK_HIGH), a
	ld	hl, #0x8000
	ld	a, (hl)
	cp	#0x12
	jr	NZ, fail

	ld	a, #0x01
	out	(#BANK_HIGH), a
	ld	hl, #0x8000
	ld	a, (hl)
	cp	#0x34
	jr	NZ, fail

	ld	a, #0x00
	out	(#BANK_HIGH), a
	ret

test_mid_ram_banks:
	ld	a, #(MID_RAM + 0x00)
	out	(#BANK_MID), a
	ld	hl, #0x4000
	ld	(hl), #0x56

	ld	a, #(MID_RAM + 0x01)
	out	(#BANK_MID), a
	ld	hl, #0x4000
	ld	(hl), #0x78

	ld	a, #(MID_RAM + 0x00)
	out	(#BANK_MID), a
	ld	hl, #0x4000
	ld	a, (hl)
	cp	#0x56
	jp	NZ, fail

	ld	a, #(MID_RAM + 0x01)
	out	(#BANK_MID), a
	ld	hl, #0x4000
	ld	a, (hl)
	cp	#0x78
	jp	NZ, fail

	; Restore reset-compatible middle ROM bank selection.
	ld	a, #0x01
	out	(#BANK_MID), a
	ret

msg_boot:
	.ascii	"Zephyr bank/serial test"
	.db	0x0d, 0x0a
	.ascii	"> "
	.db	0x00

msg_newline:
	.db	0x0d, 0x0a, 0x00

msg_pass:
	.ascii	"PASS"
	.db	0x0d, 0x0a, 0x00

msg_fail:
	.ascii	"FAIL"
	.db	0x0d, 0x0a, 0x00
