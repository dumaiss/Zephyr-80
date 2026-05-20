; Zephyr-80 monitor-launched SRAM banking test, stage 1.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Load from the monitor with:
;   L
;   G 8000
;
; Stage 1 runs at 8000h while ROM_DIS=0. In the default memory mode, reads from
; 0000h-5FFFh return ROM but writes in the same range go to SRAM underneath ROM.
; This stage copies ROM into that hidden SRAM, copies the embedded stage 2 image
; to 1000h, enables all-RAM mode by setting ROM_DIS, and jumps to stage 2.
; Stage 2 leaves ROM disabled when it returns so the monitor continues running
; from the SRAM copy.

	.module banktest
	.area CODE (ABS)

LOAD_ADDR		= 0x8000
STAGE2_ADDR		= 0x1000
STAGE2_SAVED_SP		= 0x1300
ROM_COPY_START		= 0x0000
ROM_COPY_LEN		= 0x6000
STAGE1_STACK		= 0x7ffe

SIOB_DATA		= 0x22
SIOB_CTRL		= 0x23
SIO_RR0_TX_EMPTY	= 0x04

; Bank latch layout found in HDL/schematic:
; - IO_DECODER.pld selects the memory-bank latch for writes in port block 00h.
; - CPU_AddressDecoding.kicad_sch documents "Write byte to port 0x00".
; - D0-D2 select SRAM A18-A16.
; - D3 is ROM_DIS.
; RAM_SHADOW is an input to MEM_DECODER.pld, but no software-controlled latch bit
; was found for it here. This test leaves it unchanged and assumes reset default
; RAM_SHADOW=0.
BANK_CTRL_PORT		= 0x00
BANK_BITS_MASK		= 0x07
ROM_DIS_BIT		= 0x08
BANK_CTRL_ROM_ON	= 0x00

	.globl start
	.org LOAD_ADDR

start:
	di
	ld (stage1_saved_sp),sp
	ld sp,#STAGE1_STACK

	xor a
	call select_bank_rom_on

	ld hl,#msg_banner
	call sio_puts
	ld hl,#msg_copy_rom
	call sio_puts

	ld hl,#ROM_COPY_START
	ld bc,#ROM_COPY_LEN
copy_rom_loop:
	ld a,(hl)
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,copy_rom_loop

	ld hl,#msg_copy_stage2
	call sio_puts

	ld hl,#stage2_blob
	ld de,#STAGE2_ADDR
	ld bc,#stage2_blob_end-stage2_blob
	ldir

	ld hl,(stage1_saved_sp)
	ld (STAGE2_SAVED_SP),hl

	ld hl,#msg_rom_off
	call sio_puts

	xor a
	call select_bank_rom_off
	jp STAGE2_ADDR

; Input: A = bank number, ROM enabled.
select_bank_rom_on:
	and #BANK_BITS_MASK
	call write_bank_control
	ret

; Input: A = bank number, ROM disabled.
select_bank_rom_off:
	and #BANK_BITS_MASK
	or #ROM_DIS_BIT
	call write_bank_control
	ret

; Input: A = complete bank latch byte.
; Z80 OUT (C),A drives the full 16-bit I/O address as B:C, so B is cleared
; immediately before the output.
write_bank_control:
	ld c,#BANK_CTRL_PORT
	ld b,#0x00
	out (c),a
	ret

; Print NUL-terminated string at HL.
sio_puts:
	ld a,(hl)
	or a
	ret z
	call sio_putc
	inc hl
	jr sio_puts

; Write A to SIO channel B after RR0 TX-empty is set.
sio_putc:
	push af
sio_putc_wait:
	in a,(SIOB_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,sio_putc_wait
	pop af
	out (SIOB_DATA),a
	ret

msg_banner:
	.ascii /Zephyr-80 banking test/
	.db 0x0d,0x0a,0
msg_copy_rom:
	.ascii /Copying ROM shadow.../
	.db 0x0d,0x0a,0
msg_copy_stage2:
	.ascii /Copying stage2.../
	.db 0x0d,0x0a,0
msg_rom_off:
	.ascii /Switching ROM off.../
	.db 0x0d,0x0a,0

stage1_saved_sp:
	.dw 0

	.include "stage2_blob.inc"
