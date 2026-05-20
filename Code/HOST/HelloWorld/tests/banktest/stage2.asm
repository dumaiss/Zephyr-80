; Zephyr-80 monitor-launched SRAM banking test, stage 2.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; This stage is linked for 1000h but embedded into the stage 1 image. Stage 1
; copies it to hidden low SRAM and jumps here only after ROM_DIS=1. With ROM
; disabled, 0000h-1FFFh is common RAM forced to SRAM bank 0, so this code, its
; data, and its stack survive while the banked area is switched.
;
; The monitor ROM copy currently occupies the lower part of SRAM bank 0. Stage 2
; deliberately lives at 1000h so it does not overwrite that copy; on return the
; monitor continues running from RAM with ROM_DIS still set.

	.module banktest_stage2
	.area CODE (ABS)

STAGE2_ADDR		= 0x1000
STAGE2_STACK		= 0x1ffe
STAGE2_SAVED_SP		= 0x1300
BANK_TEST_ADDR		= 0x6000
BANK_PATTERN_BASE	= 0xa0

SIOB_DATA		= 0x22
SIOB_CTRL		= 0x23
SIO_RR0_TX_EMPTY	= 0x04

BANK_CTRL_PORT		= 0x00
BANK_BITS_MASK		= 0x07
ROM_DIS_BIT		= 0x08
BANK_CTRL_ROM_ON	= 0x00

	.org STAGE2_ADDR

stage2_start:
	ld sp,#STAGE2_STACK

	ld hl,#msg_stage2
	call sio_puts
	ld hl,#msg_testing
	call sio_puts

	call write_bank_patterns
	call verify_bank_patterns
	jr c,stage2_fail

	ld hl,#msg_pass
	call sio_puts
	jr stage2_return

stage2_fail:
	ld hl,#msg_fail
	call sio_puts
	ld hl,#msg_fail_bank
	call sio_puts
	ld a,(fail_bank)
	call print_hex_byte
	ld hl,#msg_fail_value
	call sio_puts
	ld a,(fail_value)
	call print_hex_byte
	call print_crlf

stage2_return:
	; Select bank 0 and keep ROM disabled. The monitor's ROM image was copied
	; into bank-0 SRAM before ROM_DIS was set, so returning now resumes the
	; monitor from RAM at the go_return address pushed by the G command.
	xor a
	call select_bank_rom_off

	ld sp,(STAGE2_SAVED_SP)
	ret

write_bank_patterns:
	ld d,#0x00
write_bank_loop:
	ld a,d
	call select_bank_rom_off
	ld a,d
	add a,#BANK_PATTERN_BASE
	ld (BANK_TEST_ADDR),a
	inc d
	ld a,d
	cp #0x08
	jr nz,write_bank_loop
	ret

verify_bank_patterns:
	ld d,#0x00
verify_bank_loop:
	ld a,d
	call select_bank_rom_off
	ld a,(BANK_TEST_ADDR)
	ld (fail_value),a
	ld e,a
	ld a,d
	add a,#BANK_PATTERN_BASE
	cp e
	jr nz,verify_bank_fail
	inc d
	ld a,d
	cp #0x08
	jr nz,verify_bank_loop
	or a
	ret

verify_bank_fail:
	ld a,d
	ld (fail_bank),a
	scf
	ret

; Input: A = bank number, ROM disabled.
select_bank_rom_off:
	and #BANK_BITS_MASK
	or #ROM_DIS_BIT
	call write_bank_control
	ret

; Input: A = complete bank latch byte.
write_bank_control:
	ld c,#BANK_CTRL_PORT
	ld b,#0x00
	out (c),a
	ret

sio_puts:
	ld a,(hl)
	or a
	ret z
	call sio_putc
	inc hl
	jr sio_puts

sio_putc:
	push af
sio_putc_wait:
	in a,(SIOB_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,sio_putc_wait
	pop af
	out (SIOB_DATA),a
	ret

print_crlf:
	ld a,#0x0d
	call sio_putc
	ld a,#0x0a
	call sio_putc
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call print_hex_nibble
	pop af
	call print_hex_nibble
	ret

print_hex_nibble:
	and #0x0f
	cp #0x0a
	jr c,print_hex_digit
	add a,#0x37
	jr print_hex_emit
print_hex_digit:
	add a,#0x30
print_hex_emit:
	call sio_putc
	ret

msg_stage2:
	.ascii /Stage2 running from common RAM/
	.db 0x0d,0x0a,0
msg_testing:
	.ascii /Testing banks.../
	.db 0x0d,0x0a,0
msg_pass:
	.ascii /PASS/
	.db 0x0d,0x0a,0
msg_fail:
	.ascii /FAIL/
	.db 0x0d,0x0a,0
msg_fail_bank:
	.ascii /Bank /
	.db 0
msg_fail_value:
	.ascii / value /
	.db 0

	.org STAGE2_SAVED_SP
saved_sp_shadow:
	.dw 0
fail_bank:
	.db 0
fail_value:
	.db 0
