; PADSTAT.COM -- Passive USB/F310 enumeration and report status.
;
; Reads HID_STATUS page 6 from the normal IOC firmware.  It performs no USB
; transaction itself and does not acknowledge an interrupt; every value is a
; snapshot maintained by the foreground TinyUSB callbacks.

	.module padstat
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F

	.include "ioc_levels.inc"

CMD_HID_STATUS	= 0x0d
RSP_HID_STATUS	= 0x8d
HID_PAGE_PAD	= 0x06
HID_PAD_LEN	= 26

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; A stale BIOS has a different IOCALL address/contract.
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jp nz,stale_bios

	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#1
	ld (tx_frame + 3),a
	ld a,#HID_PAGE_PAD
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,transport_error

	ld a,(rx_frame + 0)
	cp #RSP_HID_STATUS
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,bad_reply
	ld a,(rx_frame + 3)
	cp #HID_PAD_LEN
	jp nz,bad_reply
	ld a,(rx_frame + 4)
	cp #HID_PAGE_PAD
	jp nz,old_controller

	ld de,#msg_devices
	ld a,(rx_frame + 5)
	call say_byte
	ld de,#msg_mounts
	ld a,(rx_frame + 6)
	call say_byte
	ld de,#msg_unmounts
	ld a,(rx_frame + 7)
	call say_byte
	ld de,#msg_last_addr
	ld a,(rx_frame + 8)
	call say_byte
	ld de,#msg_last_vid
	ld hl,#(rx_frame + 9)
	call say_word
	ld de,#msg_last_pid
	ld hl,#(rx_frame + 11)
	call say_word
	ld de,#msg_hid_mounts
	ld a,(rx_frame + 13)
	call say_byte
	ld de,#msg_last_hid
	ld a,(rx_frame + 14)
	call say_byte
	ld de,#msg_last_proto
	ld a,(rx_frame + 29)
	call say_byte

	ld de,#msg_pad0
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 15)
	call print_pad

	ld de,#msg_pad1
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 22)
	call print_pad

	call print_verdict
	ret

; HL -> addr, instance, first arm, reports LE, last length, latch.
print_pad:
	ld a,(hl)
	ld (pad_addr),a
	inc hl
	ld a,(hl)
	ld (pad_inst),a
	inc hl
	ld a,(hl)
	ld (pad_arm),a
	inc hl
	ld a,(hl)
	ld (pad_reports),a
	inc hl
	ld a,(hl)
	ld (pad_reports + 1),a
	inc hl
	ld a,(hl)
	ld (pad_len),a
	inc hl
	ld a,(hl)
	ld (pad_latch),a

	ld de,#msg_pad_addr
	ld a,(pad_addr)
	call say_byte
	ld de,#msg_pad_inst
	ld a,(pad_inst)
	call say_byte
	ld de,#msg_pad_arm
	ld a,(pad_arm)
	call say_byte
	ld de,#msg_pad_reports
	ld hl,#pad_reports
	call say_word
	ld de,#msg_pad_len
	ld a,(pad_len)
	call say_byte
	ld de,#msg_pad_latch
	ld a,(pad_latch)
	call say_byte
	ret

print_verdict:
	ld a,(rx_frame + 15)		; pad 0 address
	or a
	jr nz,pad_bound
	ld a,(rx_frame + 22)		; pad 1 address
	or a
	jr nz,pad_bound

	; No bound slot.  Was the last configured USB device an F310 in D mode?
	ld a,(rx_frame + 10)		; VID high
	cp #0x04
	jr nz,not_direct_f310
	ld a,(rx_frame + 9)		; VID low
	cp #0x6d
	jr nz,not_direct_f310
	ld a,(rx_frame + 12)		; PID high
	cp #0xc2
	jr nz,not_direct_f310
	ld a,(rx_frame + 11)		; PID low
	cp #0x16
	jr nz,not_direct_f310
	ld de,#msg_seen_no_slot
	jr verdict

not_direct_f310:
	ld a,(rx_frame + 5)		; configured non-hub devices
	or a
	ld de,#msg_no_device
	jr z,verdict
	ld de,#msg_not_f310
	jr verdict

pad_bound:
	; Prefer pad 0 if occupied.  Point HL at its arm byte and DE at reports.
	ld a,(rx_frame + 15)
	or a
	jr z,bound_pad1
	ld a,(rx_frame + 17)
	ld hl,#(rx_frame + 18)
	jr check_bound
bound_pad1:
	ld a,(rx_frame + 24)
	ld hl,#(rx_frame + 25)
check_bound:
	cp #1
	ld de,#msg_arm_failed
	jr nz,verdict
	ld a,(hl)
	inc hl
	or (hl)
	ld de,#msg_wait_report
	jr z,verdict
	ld de,#msg_reports_ok

verdict:
	ld c,#BDOS_PRINT
	call BDOS
	ret

; DE = label, A = byte.  BDOS preserves no registers.
say_byte:
	push af
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ret

; DE = label, HL -> little-endian word.  Fetch both bytes before printing.
say_word:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ld a,h
	push hl
	call print_hex_byte
	pop hl
	ld a,l
	call print_hex_byte
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
	jr c,hex_out
	add a,#0x07
hex_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

transport_error:
	ld de,#msg_transport
	jr fatal
bad_reply:
	ld de,#msg_bad_reply
	jr fatal
old_controller:
	ld de,#msg_old_controller
	jr fatal
stale_bios:
	ld de,#msg_stale_bios
fatal:
	ld c,#BDOS_PRINT
	call BDOS
	ret

msg_banner:
	.ascii "PADSTAT - passive USB/F310 status"
	.db 13,10,'$'
msg_devices:	.db 13,10
	.ascii "  USB devices       : $"
msg_mounts:	.db 13,10
	.ascii "  generic mount cb  : $"
msg_unmounts:	.db 13,10
	.ascii "  generic unmount cb: $"
msg_last_addr:	.db 13,10
	.ascii "  highest live addr : $"
msg_last_vid:	.db 13,10
	.ascii "  highest live VID  : $"
msg_last_pid:	.db 13,10
	.ascii "  highest live PID  : $"
msg_hid_mounts:	.db 13,10
	.ascii "  HID mount calls   : $"
msg_last_hid:	.db 13,10
	.ascii "  last HID address  : $"
msg_last_proto:	.db 13,10
	.ascii "  last HID protocol : $"
msg_pad0:	.db 13,10,13,10
	.ascii "Controller 1"
	.db 13,10,'$'
msg_pad1:	.db 13,10,13,10
	.ascii "Controller 2"
	.db 13,10,'$'
msg_pad_addr:	.ascii "  address           : $"
msg_pad_inst:	.db 13,10
	.ascii "  HID instance      : $"
msg_pad_arm:	.db 13,10
	.ascii "  first report arm  : $"
msg_pad_reports:	.db 13,10
	.ascii "  reports received  : $"
msg_pad_len:	.db 13,10
	.ascii "  last report length: $"
msg_pad_latch:	.db 13,10
	.ascii "  decoded latch     : $"

msg_no_device:	.db 13,10,13,10
	.ascii "Result: no non-hub USB device has enumerated."
	.db 13,10,'$'
msg_not_f310:	.db 13,10,13,10
	.ascii "Result: USB device enumerated, but the latest device is not F310 D-mode 046D:C216."
	.db 13,10,'$'
msg_seen_no_slot:	.db 13,10,13,10
	.ascii "Result: F310 D-mode enumerated, but no controller slot was assigned."
	.db 13,10,'$'
msg_arm_failed:	.db 13,10,13,10
	.ascii "Result: F310 mounted; first interrupt-IN request failed."
	.db 13,10,'$'
msg_wait_report:	.db 13,10,13,10
	.ascii "Result: F310 mounted and armed; waiting for its first report."
	.db 13,10,'$'
msg_reports_ok:	.db 13,10,13,10
	.ascii "Result: F310 reports are reaching the latch decoder."
	.db 13,10,'$'
msg_transport:	.db 13,10
	.ascii "PADSTAT: IOC transport failure."
	.db 13,10,'$'
msg_bad_reply:	.db 13,10
	.ascii "PADSTAT: malformed HID_STATUS reply."
	.db 13,10,'$'
msg_old_controller:	.db 13,10
	.ascii "PADSTAT: IOC firmware lacks passive gamepad page 6 (need level 70)."
	.db 13,10,'$'
msg_stale_bios:	.db 13,10
	.ascii "PADSTAT: BIOS IOC transport level mismatch."
	.db 13,10,'$'

entry_sp:	.ds 2
pad_addr:	.ds 1
pad_inst:	.ds 1
pad_arm:	.ds 1
pad_reports:	.ds 2
pad_len:	.ds 1
pad_latch:	.ds 1
tx_frame:	.ds 32
rx_frame:	.ds 32
	.ds 160
stack_top:
