; IOC_SDBENCH.COM — measured raw SD-card read/write benchmark.
;
; This is the SD counterpart to IOC_BULK.COM.  It deliberately bypasses the
; four-slot record cache and uses the raw 512-byte commands, so every timed
; transfer reaches the card:
;
;   READ   CMD_SD_READ_BULK -> READY -> IOCBULK
;   WRITE  CMD_SD_WRITE_BULK -> READY -> IOCBULKW -> XFER_STATUS/DONE
;
; The controller's PROFILE counters provide the clock.  Firmware level 20
; moved that profiler from Timer1 (which the command link reconfigures as an
; SCK edge counter) to independent Timer3 and added a deferred reset request.
; Each phase therefore starts at zero and excludes the reset transaction.
;
; The read report separates CMD17/dispatch from the bulk lane.  The write
; report necessarily combines the inbound bulk phase and CMD24: the controller
; holds /CTSA until the card leaves write-busy, and the host cannot observe an
; intermediate boundary.  TOTAL is the active controller service time and
; excludes semantic buffer comparison and console output, matching BULK.COM.
;
; WARNING: writes LBA 00100000h (512 MiB offset) 128 times.  Test cards only.
; The block is not restored.  A final raw read verifies the last written ramp.

	.module ioc_sdbench
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONIN	= 0x01
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

IOCALL		= 0xDA3F
IOCBULK		= 0xDA45
IOCBULKW	= 0xDA48

ZBIOS_XPORT_LEVEL_ADDR = 0xDF7A
ZBIOS_XPORT_LEVEL      = 7
IOC_FW_LEVEL            = 62

CMD_PING		= 0x01
RSP_PING		= 0x81
CMD_SD_READ_BULK	= 0x05
RSP_SD_READ_BULK	= 0x85
CMD_XFER_STATUS		= 0x06
RSP_XFER_STATUS		= 0x86
CMD_SD_WRITE_BULK	= 0x07
RSP_SD_WRITE_BULK	= 0x87
CMD_PROFILE		= 0x0b
RSP_PROFILE		= 0x8b
PROFILE_RESET		= 0x01

BLOCK_SIZE	= 512
BENCH_COUNT	= 128		; 128 * 512 bytes = 64 KiB
RATE_NUMERATOR	= 64000		; 64 KiB * 1000 ms/s

; PROFILE words copied from reply bytes 4..15.
PROF_RX		= 0
PROF_DECODE	= 2
PROF_DISPATCH	= 4
PROF_SEND	= 6
PROF_BULK	= 8
PROF_TOTAL	= 10

start:
	; CP/M's return address lives on the CCP stack.  Keep it while using a
	; private stack large enough for nested transport and printing helpers.
	ld (entry_sp),sp
	ld sp,#stack_top

	ld de,#msg_banner
	call puts

	call check_level
	or a
	jr z,level_ok
	ld (fail_info),a
	ld de,#msg_level_fail
	call puts
	ld a,(fail_info)
	call print_hex_byte
	call crlf
	jp finish

level_ok:
	ld de,#msg_warning
	call puts
	ld c,#BDOS_CONIN
	call BDOS
	cp #'Y'
	jr z,confirmed
	cp #'y'
	jr z,confirmed
	ld de,#msg_cancelled
	call puts
	jp finish

confirmed:
	call crlf

	; Initialise the card and capture stable reference data before resetting the
	; read profile.  This keeps one-time ACMD41 initialisation out of the result.
	call do_read
	or a
	jp nz,operation_fail
	ld hl,#io_buf
	ld de,#ref_buf
	ld bc,#BLOCK_SIZE
	ldir

	ld a,#'P'
	ld (phase),a
	call profile_reset
	or a
	jp nz,operation_fail
	ld hl,#0
	ld (completed),hl
	ld a,#'R'
	ld (phase),a

read_loop:
	call do_read
	or a
	jp nz,operation_fail
	call verify_buffers
	or a
	jp nz,verify_fail
	call bump_completed
	jr c,read_loop

	ld hl,#read_profile
	call profile_get
	or a
	jp nz,operation_fail

	; The write pattern is a non-zero rotating ramp.  Zeros alone are not a
	; valid test because transmitter underrun fill on this link is 00h.
	call build_pattern
	ld a,#'P'
	ld (phase),a
	call profile_reset
	or a
	jp nz,operation_fail
	ld hl,#0
	ld (completed),hl
	ld a,#'W'
	ld (phase),a

write_loop:
	call do_write
	or a
	jp nz,operation_fail
	call bump_completed
	jr c,write_loop

	ld hl,#write_profile
	call profile_get
	or a
	jp nz,operation_fail

	; One untimed raw read proves that the last CMD24 reached the requested LBA
	; and that the card returns exactly what was sent.
	ld a,#'V'
	ld (phase),a
	call do_read
	or a
	jp nz,operation_fail
	call verify_buffers
	or a
	jp nz,verify_fail

	call report_results
	jp finish

; Increment the 16-bit transfer count.  Carry is set while another transfer is
; required and clear after BENCH_COUNT has completed.
bump_completed:
	ld hl,(completed)
	inc hl
	ld (completed),hl
	ld a,h
	or a
	jr nz,bc_done
	ld a,l
	cp #BENCH_COUNT
	jr c,bc_more
bc_done:
	or a				; clear carry
	ret
bc_more:
	scf
	ret

; ---------------------------------------------------------------------------
; Raw 512-byte read into io_buf.  Returns A=0 or records stage/info and A!=0.
; ---------------------------------------------------------------------------
do_read:
	call build_sd_request
	ld a,#CMD_SD_READ_BULK
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dr_class
	ld (fail_info),a
	ld a,#0x01
	jp set_failure
dr_class:
	ld a,(rx_frame + 0)
	cp #RSP_SD_READ_BULK
	jr z,dr_status
	ld (fail_info),a
	ld a,#0x02
	jp set_failure
dr_status:
	ld a,(rx_frame + 2)
	or a
	jr z,dr_metadata
	ld (fail_info),a
	ld a,#0x03
	jp set_failure
dr_metadata:
	ld a,(rx_frame + 3)
	cp #0x08
	jr nz,dr_meta_bad
	ld a,(rx_frame + 5)
	or a				; MCU -> Z80
	jr nz,dr_meta_bad
	ld a,(rx_frame + 6)
	or a				; 0200h bytes, low
	jr nz,dr_meta_bad
	ld a,(rx_frame + 7)
	cp #0x02
	jr nz,dr_meta_bad
	call check_lba_echo
	jr z,dr_bulk
	ld a,#0x05
	ld (fail_info),a
	ld a,#0x05
	jp set_failure
dr_meta_bad:
	ld (fail_info),a
	ld a,#0x04
	jp set_failure
dr_bulk:
	ld hl,#io_buf
	ld de,#BLOCK_SIZE
	call IOCBULK
	or a
	ret z
	ld (fail_info),a
	ld a,#0x06
	jp set_failure

; ---------------------------------------------------------------------------
; Raw 512-byte write from ref_buf, including mandatory DONE status.
; ---------------------------------------------------------------------------
do_write:
	call build_sd_request
	ld a,#CMD_SD_WRITE_BULK
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dw_class
	ld (fail_info),a
	ld a,#0x11
	jp set_failure
dw_class:
	ld a,(rx_frame + 0)
	cp #RSP_SD_WRITE_BULK
	jr z,dw_status
	ld (fail_info),a
	ld a,#0x12
	jp set_failure
dw_status:
	ld a,(rx_frame + 2)
	or a
	jr z,dw_metadata
	ld (fail_info),a
	ld a,#0x13
	jp set_failure
dw_metadata:
	ld a,(rx_frame + 3)
	cp #0x08
	jr nz,dw_meta_bad
	ld a,(rx_frame + 5)
	cp #0x01			; Z80 -> MCU
	jr nz,dw_meta_bad
	ld a,(rx_frame + 6)
	or a
	jr nz,dw_meta_bad
	ld a,(rx_frame + 7)
	cp #0x02
	jr nz,dw_meta_bad
	call check_lba_echo
	jr z,dw_bulk
	ld a,#0x05
	ld (fail_info),a
	ld a,#0x15
	jp set_failure
dw_meta_bad:
	ld (fail_info),a
	ld a,#0x14
	jp set_failure
dw_bulk:
	ld a,(rx_frame + 4)
	ld (ready_id),a
	ld hl,#ref_buf
	ld de,#BLOCK_SIZE
	call IOCBULKW
	or a
	jr z,dw_done
	ld (fail_info),a
	ld a,#0x16
	jp set_failure
dw_done:
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dw_done_class
	ld (fail_info),a
	ld a,#0x17
	jp set_failure
dw_done_class:
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jr z,dw_done_header_status
	ld (fail_info),a
	ld a,#0x18
	jp set_failure
dw_done_header_status:
	ld a,(rx_frame + 2)
	or a
	jr z,dw_done_id
	ld (fail_info),a
	ld a,#0x1b
	jp set_failure
dw_done_id:
	ld a,(rx_frame + 4)
	ld hl,#ready_id
	cp (hl)
	jr z,dw_done_status
	ld (fail_info),a
	ld a,#0x19
	jp set_failure
dw_done_status:
	ld a,(rx_frame + 5)
	or a
	ret z
	ld (fail_info),a
	ld a,#0x1a
	jp set_failure

; Common raw SD request: payload is the 32-bit LBA 00100000h.
build_sd_request:
	call zero_frames
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a
	ld hl,#scratch_lba
	ld de,#(tx_frame + 4)
	ld bc,#4
	ldir
	ret

; Z flag means READY bytes 8..11 echo the requested LBA exactly.
check_lba_echo:
	ld hl,#(rx_frame + 8)
	ld de,#scratch_lba
	ld b,#4
cle_loop:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz cle_loop
	xor a
	ret

set_failure:
	ld (fail_stage),a
	ld a,#1
	ret

; ---------------------------------------------------------------------------
; PROFILE reset/get.  Reset is applied after its reply completes in firmware.
; ---------------------------------------------------------------------------
profile_reset:
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 3),a
	ld a,#PROFILE_RESET
	ld (tx_frame + 4),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,pr_class
	ld (fail_info),a
	ld a,#0x21
	jp set_failure
pr_class:
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr z,pr_status
	ld (fail_info),a
	ld a,#0x22
	jp set_failure
pr_status:
	ld a,(rx_frame + 2)
	or a
	ret z
	ld (fail_info),a
	ld a,#0x23
	jp set_failure

; In: HL = 12-byte destination.  Captures six little-endian millisecond words.
profile_get:
	ld (profile_dest),hl
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,pg_class
	ld (fail_info),a
	ld a,#0x24
	jp set_failure
pg_class:
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr z,pg_status
	ld (fail_info),a
	ld a,#0x25
	jp set_failure
pg_status:
	ld a,(rx_frame + 2)
	or a
	jr z,pg_copy
	ld (fail_info),a
	ld a,#0x26
	jp set_failure
pg_copy:
	ld hl,#(rx_frame + 4)
	ld de,(profile_dest)
	ld bc,#12
	ldir
	xor a
	ret

; ---------------------------------------------------------------------------
; Integrity helpers.
; ---------------------------------------------------------------------------
build_pattern:
	ld hl,#ref_buf
	ld bc,#BLOCK_SIZE
	ld e,#0x5a
bp_loop:
	ld (hl),e
	inc hl
	inc e
	dec bc
	ld a,b
	or c
	jr nz,bp_loop
	ret

verify_buffers:
	ld hl,#ref_buf
	ld de,#io_buf
	ld bc,#BLOCK_SIZE
vb_loop:
	ld a,(de)
	cp (hl)
	jr nz,vb_bad
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,vb_loop
	xor a
	ret
vb_bad:
	ld (bad_got),a
	ld a,(hl)
	ld (bad_expected),a
	ld hl,#BLOCK_SIZE
	or a
	sbc hl,bc
	ld (bad_offset),hl
	ld a,#1
	ret

zero_frames:
	xor a
	ld hl,#tx_frame
	ld b,#32
zf_tx:
	ld (hl),a
	inc hl
	djnz zf_tx
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zf_rx:
	ld (hl),a
	inc hl
	djnz zf_rx
	ret

; E0 BIOS, E1 command transport/class, E2 controller firmware level.
check_level:
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jr nz,cl_bios
	call zero_frames
	ld a,#CMD_PING
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,cl_link
	ld a,(rx_frame + 0)
	cp #RSP_PING
	jr nz,cl_link
	ld a,(rx_frame + 20)
	cp #IOC_FW_LEVEL
	jr nz,cl_fw
	xor a
	ret
cl_bios:
	ld a,#0xe0
	ret
cl_link:
	ld a,#0xe1
	ret
cl_fw:
	ld a,#0xe2
	ret

; ---------------------------------------------------------------------------
; Report controller-side profiles and derived rates.
; ---------------------------------------------------------------------------
report_results:
	ld de,#msg_ok
	call puts

	ld de,#msg_read_head
	call puts
	ld hl,#(read_profile + PROF_RX)
	ld de,#msg_rx
	call say_ms
	ld hl,#(read_profile + PROF_DECODE)
	ld de,#msg_decode
	call say_ms
	ld hl,#(read_profile + PROF_DISPATCH)
	ld de,#msg_cmd17
	call say_ms
	ld hl,#(read_profile + PROF_SEND)
	ld de,#msg_ready
	call say_ms
	ld hl,#(read_profile + PROF_BULK)
	ld de,#msg_bulk_read
	call say_ms
	ld hl,#(read_profile + PROF_TOTAL)
	ld de,#msg_total
	call say_ms
	ld hl,#(read_profile + PROF_DISPATCH)
	ld de,#msg_card_read_rate
	call say_rate
	ld hl,#(read_profile + PROF_TOTAL)
	ld de,#msg_read_rate
	call say_rate

	ld de,#msg_write_head
	call puts
	ld hl,#(write_profile + PROF_RX)
	ld de,#msg_rx
	call say_ms
	ld hl,#(write_profile + PROF_DECODE)
	ld de,#msg_decode
	call say_ms
	ld hl,#(write_profile + PROF_DISPATCH)
	ld de,#msg_dispatch
	call say_ms
	ld hl,#(write_profile + PROF_SEND)
	ld de,#msg_replies
	call say_ms
	ld hl,#(write_profile + PROF_BULK)
	ld de,#msg_bulk_write
	call say_ms
	ld hl,#(write_profile + PROF_TOTAL)
	ld de,#msg_total
	call say_ms
	ld hl,#(write_profile + PROF_BULK)
	ld de,#msg_card_write_rate
	call say_rate
	ld hl,#(write_profile + PROF_TOTAL)
	ld de,#msg_write_rate
	call say_rate
	ret

; DE label, HL address of little-endian word.
say_ms:
	push hl
	call puts
	pop hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	ex de,hl
	call print_dec_word
	ld de,#msg_ms
	jp puts

say_rate:
	push hl
	call puts
	pop hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	call rate_from_ms
	call print_dec_word
	ld de,#msg_kib
	jp puts

; 64 * 1000 / ms -> integer KiB/s.  Input DE=ms, output HL=rate.
rate_from_ms:
	ld a,d
	or e
	jr z,rfm_zero
	ld hl,#RATE_NUMERATOR
	ld bc,#0
rfm_loop:
	or a
	sbc hl,de
	jr c,rfm_done
	inc bc
	jr rfm_loop
rfm_done:
	ld h,b
	ld l,c
	ret
rfm_zero:
	ld hl,#0
	ret

operation_fail:
	ld de,#msg_fail
	call puts
	ld a,(phase)
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ld de,#msg_stage
	call puts
	ld a,(fail_stage)
	call print_hex_byte
	ld de,#msg_info
	call puts
	ld a,(fail_info)
	call print_hex_byte
	ld de,#msg_after
	call puts
	ld hl,(completed)
	call print_dec_word
	ld de,#msg_transfers
	call puts
	jp finish

verify_fail:
	ld de,#msg_verify_fail
	call puts
	ld hl,(bad_offset)
	call print_dec_word
	ld de,#msg_expected
	call puts
	ld a,(bad_expected)
	call print_hex_byte
	ld de,#msg_got
	call puts
	ld a,(bad_got)
	call print_hex_byte
	call crlf
	jp finish

puts:
	ld c,#BDOS_PRINT
	jp BDOS

crlf:
	ld de,#msg_crlf
	jp puts

; Decimal 16-bit output.  Input HL=value; clobbers AF, BC, DE, HL.
print_dec_word:
	xor a
	ld (dec_started),a
	ld de,#10000
	call print_dec_digit
	ld de,#1000
	call print_dec_digit
	ld de,#100
	call print_dec_digit
	ld de,#10
	call print_dec_digit
	ld a,#1
	ld (dec_started),a
	ld de,#1
	jp print_dec_digit

print_dec_digit:
	ld b,#'0'
pdd_sub:
	or a
	sbc hl,de
	jr c,pdd_restore
	inc b
	jr pdd_sub
pdd_restore:
	add hl,de
	ld a,b
	cp #'0'
	jr nz,pdd_emit
	ld a,(dec_started)
	or a
	ret z
pdd_emit:
	ld a,#1
	ld (dec_started),a
	push bc
	push de
	push hl
	ld e,b
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop de
	pop bc
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
print_hex_nibble:
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

finish:
	ld sp,(entry_sp)
	ret

scratch_lba:
	.db 0x00,0x00,0x10,0x00	; LBA 00100000h = 512 MiB offset

msg_banner:
	.ascii "IOC SD BENCH - raw 128 x 512-byte read + write"
	.db 13,10,'$'
msg_warning:
	.ascii "WARNING: overwrites LBA 00100000h. Continue (Y/N)? $"
msg_cancelled:
	.db 13,10
	.ascii "cancelled"
	.db 13,10,'$'
msg_level_fail:
	.ascii "protocol level mismatch code 0x$"
msg_ok:
	.ascii "OK - 64 KiB read and 64 KiB write verified"
	.db 13,10,'$'
msg_read_head:
	.ascii "READ: 128 raw CMD17 transfers"
	.db 13,10,'$'
msg_write_head:
	.ascii "WRITE: 128 raw CMD24 transfers"
	.db 13,10,'$'
msg_rx:
	.ascii "  command receive     $"
msg_decode:
	.ascii "  command decode      $"
msg_cmd17:
	.ascii "  SD CMD17/dispatch   $"
msg_dispatch:
	.ascii "  command dispatch    $"
msg_ready:
	.ascii "  READY replies       $"
msg_replies:
	.ascii "  READY/DONE replies  $"
msg_bulk_read:
	.ascii "  IOCBULK phase       $"
msg_bulk_write:
	.ascii "  bulk + CMD24        $"
msg_total:
	.ascii "  active total        $"
msg_card_read_rate:
	.ascii "  card CMD17          $"
msg_read_rate:
	.ascii "  raw read path       $"
msg_card_write_rate:
	.ascii "  bulk + card write   $"
msg_write_rate:
	.ascii "  raw write path      $"
msg_ms:
	.ascii " ms"
	.db 13,10,'$'
msg_kib:
	.ascii " KiB/s"
	.db 13,10,'$'
msg_fail:
	.ascii "FAIL phase $"
msg_stage:
	.ascii " stage 0x$"
msg_info:
	.ascii " info 0x$"
msg_after:
	.ascii " after $"
msg_transfers:
	.ascii " transfers"
	.db 13,10,'$'
msg_verify_fail:
	.ascii "VERIFY FAIL offset $"
msg_expected:
	.ascii " expected 0x$"
msg_got:
	.ascii " got 0x$"
msg_crlf:
	.db 13,10,'$'

entry_sp:	.ds 2
completed:	.ds 2
profile_dest:	.ds 2
ready_id:	.ds 1
phase:		.ds 1
fail_stage:	.ds 1
fail_info:	.ds 1
dec_started:	.ds 1
bad_offset:	.ds 2
bad_expected:	.ds 1
bad_got:	.ds 1
read_profile:	.ds 12
write_profile:	.ds 12
tx_frame:	.ds 32
rx_frame:	.ds 32
ref_buf:	.ds 512
io_buf:		.ds 512
stack_space:	.ds 128
stack_top:
