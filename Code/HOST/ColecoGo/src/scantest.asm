; SCANTEST.COM -- standalone harness for the ColecoGo cartridge I/O scanner.
;
; CPU:       Z80
; Assembler: SDCC / ASxxxx sdasz80
; Entry:     CP/M transient-program origin 0100h
;
; This is test-only code. It runs the same cartscan.inc and cartpatch.inc the
; loader uses, against the same buffer addresses, under an ordinary CP/M that
; needs none of the Zephyr BDOS extensions. It takes over no hardware and
; returns to CP/M normally.
;
;     A>SCANTEST GAME.ROM
;
; It loads the image, applies the scan and any GAME.PAT manifest, prints the
; same report the loader prints, and writes SCANTEST.OUT: the 4096-byte
; visited bitmap followed by the adapted image. tools/test_cartscan.py
; compares both against the reference model in tools/scan_cartridge.py, so a
; divergence in the instruction decoder fails the build rather than waiting
; for hardware.

	.module scantest
	.area CODE (ABS)
	.org 0x0100

BDOS			= 0x0005
BDOS_CONOUT		= 0x02
BDOS_PRINT		= 0x09
BDOS_OPEN		= 0x0f
BDOS_CLOSE		= 0x10
BDOS_DELETE		= 0x13
BDOS_READ_SEQ		= 0x14
BDOS_WRITE_SEQ		= 0x15
BDOS_MAKE		= 0x16
BDOS_SET_DMA		= 0x1a
BDOS_FILE_SIZE		= 0x23

DEFAULT_FCB		= 0x005c
DEFAULT_DMA		= 0x0080
FCB_NAME_BYTES		= 12
FCB_BYTES		= 36
FCB_R0			= 33
FCB_R1			= 34
FCB_R2			= 35

; The harness mirrors the loader's buffer addresses exactly, so the scanner
; sees the arithmetic it will see in production.
CART_BUFFER		= 0x3800
CART_BYTES		= 0x8000
CART_MAX_RECORDS	= CART_BYTES / 128
PRIVATE_STACK_TOP	= 0xbc00
SCAN_BITMAP		= 0xbc00
SCAN_WORKLIST		= 0xcc00
PATCH_BUFFER		= 0xd400

ZEPHYR_VDP_DATA_PORT	= 0xa0
ZEPHYR_SOUND_PORT	= 0xe0

start:
	ld (entry_sp),sp
	ld sp,#PRIVATE_STACK_TOP

	ld de,#msg_banner
	call puts

	ld a,(DEFAULT_FCB + 1)
	cp #' '
	jp z,error_usage
	ld hl,#DEFAULT_FCB
	ld de,#cart_fcb_name
	ld bc,#FCB_NAME_BYTES
	ldir

	call validate_cart_file
	call fill_cart_buffer
	call load_cart_file

	call compute_cart_crc
	call scan_cart_io
	call report_cart_scan
	call apply_cart_patch_file

	call dump_results

	ld de,#DEFAULT_DMA
	ld c,#BDOS_SET_DMA
	call BDOS
	ld sp,(entry_sp)
	ret

; Determine the record-rounded length of the requested image.
validate_cart_file:
	ld hl,#cart_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_cart_open
	call compute_work_file_size
	ld a,(work_fcb + FCB_R2)
	or a
	jp nz,error_cart_size
	ld hl,(work_fcb + FCB_R0)
	ld a,h
	or l
	jp z,error_cart_size
	ld a,h
	cp #0x01
	jr c,validate_cart_size_ok
	jp nz,error_cart_size
	ld a,l
	or a
	jp nz,error_cart_size
validate_cart_size_ok:
	ld (cart_records),hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld (cart_byte_count),hl
	call close_work_fcb
	jp z,error_cart_close
	ret

; Unused image space takes the same FFh fill the loader applies.
fill_cart_buffer:
	ld hl,#CART_BUFFER
	ld (hl),#0xff
	ld de,#(CART_BUFFER + 1)
	ld bc,#(CART_BYTES - 1)
	ldir
	ret

load_cart_file:
	ld hl,#cart_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_cart_open
	ld hl,#CART_BUFFER
	ld (load_ptr),hl
	ld hl,(cart_records)
	ld (records_left),hl
	ld hl,#error_cart_read
	ld (read_error_target),hl
	call read_exact_records
	call close_work_fcb
	jp z,error_cart_close
	ret

; Dump the visited bitmap and the adapted image to the console as hex.
;
; The console is the only host channel this harness trusts: emulated
; sequential disk writes were observed to drop and reorder records, which
; would have made a mismatch look like a scanner fault. tools/test_cartscan.py
; parses what is printed here.
dump_results:
	ld de,#msg_bitmap
	call puts
	ld hl,#SCAN_BITMAP
	ld bc,#0x1000
	call dump_hex
	ld de,#msg_image
	call puts
	ld hl,#CART_BUFFER
	ld bc,(cart_byte_count)
	call dump_hex
	ld de,#msg_end
	jp puts

; Inputs: HL = source, BC = byte count. Emits 32 bytes per line.
dump_hex:
	ld a,b
	or c
	jr nz,dump_hex_more
	ld a,(dump_hex_column)
	or a
	ret z
	jp dump_newline
dump_hex_more:
	ld a,(hl)
	call put_hex_byte
	inc hl
	dec bc
	ld a,(dump_hex_column)
	inc a
	ld (dump_hex_column),a
	cp #32
	jr nz,dump_hex
	call dump_newline
	jr dump_hex

dump_newline:
	xor a
	ld (dump_hex_column),a
	ld a,#0x0d
	call putc
	ld a,#0x0a
	jp putc

; Inputs: A = the byte to print as two hex digits. Preserves BC, DE, HL.
put_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call put_hex_digit
	pop af
; Inputs: A = a value whose low nibble is printed.
put_hex_digit:
	and #0x0f
	add a,#'0'
	cp #('9' + 1)
	jr c,put_hex_emit
	add a,#('a' - '9' - 1)
put_hex_emit:
	jp putc

; ---------------------------------------------------------------------------
; CP/M helpers, matching the loader's behavior and names so the shared
; includes bind to the same contracts.
; ---------------------------------------------------------------------------

init_work_fcb:
	ld de,#work_fcb
	ld bc,#FCB_NAME_BYTES
	ldir
	xor a
	ld b,#(FCB_BYTES - FCB_NAME_BYTES)
init_work_fcb_clear_loop:
	ld (de),a
	inc de
	djnz init_work_fcb_clear_loop
	ret

open_work_fcb:
	ld de,#work_fcb
	ld c,#BDOS_OPEN
	call BDOS
	cp #0xff
	ret

close_work_fcb:
	ld de,#work_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	cp #0xff
	ret

compute_work_file_size:
	ld de,#work_fcb
	ld c,#BDOS_FILE_SIZE
	call BDOS
	ret

read_exact_records:
	ld hl,(records_left)
	ld a,h
	or l
	ret z
	ld de,(load_ptr)
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#work_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	or a
	jr z,read_exact_record_ok
	ld hl,(read_error_target)
	jp (hl)
read_exact_record_ok:
	ld hl,(load_ptr)
	ld de,#128
	add hl,de
	ld (load_ptr),hl
	ld hl,(records_left)
	dec hl
	ld (records_left),hl
	jr read_exact_records

puts:
	ld c,#BDOS_PRINT
	call BDOS
	ret

error_usage:
	ld de,#msg_usage
	jr exit_error
error_cart_open:
	ld de,#msg_cart_open
	jr exit_error
error_cart_size:
	call close_work_fcb
	ld de,#msg_cart_size
	jr exit_error
error_cart_close:
	ld de,#msg_cart_close
	jr exit_error
error_cart_read:
	call close_work_fcb
	ld de,#msg_cart_read
	jr exit_error
exit_error:
	call puts
	ld de,#DEFAULT_DMA
	ld c,#BDOS_SET_DMA
	call BDOS
	ld sp,(entry_sp)
	ret

.include "cartscan.inc"
.include "cartpatch.inc"

; ---------------------------------------------------------------------------
; Harness data.
; ---------------------------------------------------------------------------

cart_fcb_name:
	.ds FCB_NAME_BYTES
work_fcb:
	.ds FCB_BYTES

entry_sp:
	.dw 0
cart_records:
	.dw 0
cart_byte_count:
	.dw 0
cart_crc16:
	.dw 0
load_ptr:
	.dw 0
records_left:
	.dw 0
read_error_target:
	.dw 0
scan_wl_ptr:
	.dw 0
scan_vdp_count:
	.dw 0
scan_snd_count:
	.dw 0
scan_ind_count:
	.dw 0
scan_overflow:
	.db 0
scan_scanned:
	.db 0
print_u16_started:
	.db 0
dump_hex_column:
	.db 0

msg_banner:
	.ascii "SCANTEST - ColecoGo cartridge scanner harness\r\n$"
msg_bitmap:
	.ascii "BITMAP\r\n$"
msg_image:
	.ascii "IMAGE\r\n$"
msg_end:
	.ascii "END\r\n$"
msg_usage:
	.ascii "Error: use SCANTEST GAME.ROM\r\n$"
msg_cart_open:
	.ascii "Error: cannot open the requested cartridge image.\r\n$"
msg_cart_size:
	.ascii "Error: cartridge must occupy 1 through 256 CP/M records.\r\n$"
msg_cart_close:
	.ascii "Error: cannot close the cartridge image.\r\n$"
msg_cart_read:
	.ascii "Error: failed while reading the cartridge.\r\n$"

program_end:
