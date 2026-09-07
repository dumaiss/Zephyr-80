; IOC_DIAGCHK.COM — Verify the BIOS IOC link failure record without breaking
; the link.
;
; The record at CBIOS_IOC_DIAG_BASE is only written on a transport failure, and
; on this machine a transport failure normally means the IO Controller is gone.
; The PIC drives the host reset lines, so "stop the controller and keep running"
; is not a test that exists here: killing the IOC resets the Z80 with it.
;
; IOCBULK with a length of zero is the way in.  The length is checked at
; IOCBULK_BAD_LEN BEFORE /RTSA is asserted, so the request is rejected without a
; single byte reaching the wire and without a handshake to unwind.  The link is
; untouched and the machine keeps running, but the BIOS takes the same failure
; path it would take for a real Bulk rejection:
;
;   IOCBULK_BAD_LEN -> IOC_BULK_REJECT_INPUT -> ioc_bulk_diag_capture
;                   -> ioc_diag_capture_common
;
; That covers the whole shared body of the capture: STATUS, LANE, the RR0/RR1
; register reads, and the single 16-bit load/store that copies ioc_link_ready
; and ioc_rx_synced as a pair.
;
; It does NOT cover the command-lane entry, whose 16-bit store clears LANE and
; BULK_REASON together.  Reaching that needs a real command-lane failure.
;
; Expected result on a healthy machine:
;   IOCBULK returns 02h  (IOC_XPORT_BAD_FRAME)
;   status  02h          (the same code, recorded)
;   lane    01h          (bulk, SIO1/A)
;   stage   01h          (IOC_BULK_REASON_INPUT — invalid caller length)
;
; The record is left describing this synthetic rejection.  That is harmless: it
; is a last-failure record, and the next real failure overwrites it.

	.module ioc_diagchk
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09		; print '$'-terminated string at DE
IOCBULK		= 0xDA45	; BIOS extended entry: common-packet bulk receive

	.include "ioc_levels.inc"
	.include "ioc_diag_record.inc"

; What a correct capture must produce for this specific rejection.
EXPECT_STATUS	= 0x02		; IOC_XPORT_BAD_FRAME
EXPECT_LANE	= IOC_DIAG_LANE_BULK
EXPECT_STAGE	= IOC_BULK_REASON_INPUT

start:
	; Private stack.
	;
	; CP/M enters a .COM through CALL TBASE, on the CCP's own stack -- sixteen
	; bytes total, several of them already spent getting here.  The BIOS
	; transport nests roughly twenty-five bytes deep and runs with interrupts
	; enabled while it waits for the MCU, so calling it from here used to run
	; off the bottom of that stack and into the CCP's own code.  Nothing
	; repaired it: a .COM exits through RET, not a warm boot, so WBOOT's
	; restore_ccp_from_rom never ran and the next CCP command died.
	;
	; The BIOS shims for IOCALL/IOCBULK/IOCBULKW now switch stacks themselves,
	; so this is no longer the only thing standing between here and a wedged
	; machine -- but BDOS nesting and an interrupt frame still land on whatever
	; stack this program is running on, and sixteen bytes is not enough for
	; those either.
	;
	; Entered through CALL so every RET in the body below lands back here and
	; the CCP's stack pointer is put back exactly once.
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; The record's layout is published by the transport level, not by a
	; version byte inside the record.  A tool that decodes it without
	; checking is reading whatever the old layout left at those offsets.
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #IOC_DIAG_RECORD_MIN_XPORT_LEVEL
	jp c,stale_bios

	; Provoke the rejection.  HL must still be a real buffer: the length is
	; what is invalid, and nothing is written through HL on this path.
	ld hl,#rx_buf
	ld de,#0x0000
	call IOCBULK
	ld (iocbulk_rc),a

	ld de,#msg_rc
	ld a,(iocbulk_rc)
	call say_byte

	ld de,#msg_status
	ld a,(IOC_DIAG_STATUS)
	call say_byte
	ld de,#msg_lane
	ld a,(IOC_DIAG_LANE)
	call say_byte
	ld de,#msg_stage
	ld a,(IOC_DIAG_BULK_REASON)
	call say_byte
	ld de,#msg_rr0
	ld a,(IOC_DIAG_RR0)
	call say_byte
	ld de,#msg_rr1
	ld a,(IOC_DIAG_RR1)
	call say_byte
	ld de,#msg_ready
	ld a,(IOC_DIAG_READY)
	call say_byte
	ld de,#msg_synced
	ld a,(IOC_DIAG_SYNCED)
	call say_byte
	ld de,#msg_bsync
	ld a,(IOC_DIAG_BULK_SYNCED)
	call say_byte
	ld de,#msg_seq
	ld a,(IOC_DIAG_SEQ)
	call say_byte

	; Reserved bytes are published as reading zero.  They are .db 0 in the
	; BIOS rather than .ds precisely so that promise is true on a fresh
	; image; check it rather than trusting it.
	ld hl,#IOC_DIAG_RESERVED
	ld b,#4
chk_reserved:
	ld a,(hl)
	or a
	jr nz,fail_reserved
	inc hl
	djnz chk_reserved

	; Verdict.  Each mismatch names the field so a failure says which part of
	; the capture did not run, not merely that something is wrong.
	ld a,(iocbulk_rc)
	cp #EXPECT_STATUS
	jr nz,fail_rc
	ld a,(IOC_DIAG_STATUS)
	cp #EXPECT_STATUS
	jr nz,fail_status
	ld a,(IOC_DIAG_LANE)
	cp #EXPECT_LANE
	jr nz,fail_lane
	ld a,(IOC_DIAG_BULK_REASON)
	cp #EXPECT_STAGE
	jr nz,fail_stage

	ld de,#msg_pass
	jp say_and_exit

fail_rc:
	ld de,#msg_fail_rc
	jp say_and_exit
fail_status:
	ld de,#msg_fail_status
	jp say_and_exit
fail_lane:
	ld de,#msg_fail_lane
	jp say_and_exit
fail_stage:
	ld de,#msg_fail_stage
	jp say_and_exit
fail_reserved:
	ld de,#msg_fail_reserved
	jp say_and_exit

stale_bios:
	ld de,#msg_stale_bios
say_and_exit:
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print the label at DE then the byte in A.
say_byte:
	push af
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ret

; Print the byte in A as two uppercase hex digits via BDOS CONOUT (fn 2).
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
	add a,#0x30		; bias to '0'
	cp #0x3a		; past '9'?
	jr c,phx_out
	add a,#0x07		; shift into 'A'-'F'
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

msg_banner:
	.ascii "IOC DIAGCHK - zero-length IOCBULK, nothing reaches the wire"
	.db 13,10,'$'
msg_rc:		.ascii "  IOCBULK returned      : $"
msg_status:	.db 13,10
		.ascii "  record status         : $"
msg_lane:	.db 13,10
		.ascii "  .. lane (00=cmd 01=blk): $"
msg_stage:	.db 13,10
		.ascii "  .. bulk reject stage  : $"
msg_rr0:	.db 13,10
		.ascii "  .. RR0 (b4=hunting)   : $"
msg_rr1:	.db 13,10
		.ascii "  .. RR1 (rx errors)    : $"
msg_ready:	.db 13,10
		.ascii "  .. ioc_link_ready     : $"
msg_synced:	.db 13,10
		.ascii "  .. ioc_rx_synced      : $"
msg_bsync:	.db 13,10
		.ascii "  .. bulk ever synced   : $"
msg_seq:	.db 13,10
		.ascii "  .. transaction seq    : $"

msg_pass:
	.db 13,10
	.ascii "PASS - capture ran on the Bulk lane and recorded this rejection."
	.db 13,10
	.ascii "  Not covered: the command-lane entry, which needs a real"
	.db 13,10
	.ascii "  command failure to reach."
	.db 13,10,'$'
msg_fail_rc:
	.db 13,10
	.ascii "FAIL - IOCBULK did not reject a zero length with 02h."
	.db 13,10,'$'
msg_fail_status:
	.db 13,10
	.ascii "FAIL - status not recorded; capture did not run."
	.db 13,10,'$'
msg_fail_lane:
	.db 13,10
	.ascii "FAIL - lane wrong; bulk entry did not set it."
	.db 13,10,'$'
msg_fail_stage:
	.db 13,10
	.ascii "FAIL - reject stage wrong; reason not stored."
	.db 13,10,'$'
msg_fail_reserved:
	.db 13,10
	.ascii "FAIL - reserved bytes are not zero; contract is false."
	.db 13,10,'$'
msg_stale_bios:
	.ascii " - BIOS transport level below "
	.db ZBIOS_XPORT_LEVEL_HEX_HI,ZBIOS_XPORT_LEVEL_HEX_LO
	.ascii "; record layout unknown, not decoding."
	.db 13,10,'$'

iocbulk_rc:	.ds 1
rx_buf:		.ds 8

; Private stack, and the CCP stack pointer parked while it is in use.
; Reserved, not emitted: the .COM image ends at the last byte above.
entry_sp:	.ds 2
	.ds 128				; BDOS nesting plus an interrupt frame
stack_top:
