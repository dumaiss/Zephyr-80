; IOC_SDSOAK.COM — write/read/verify soak test for the SD bulk transport.
;
;   SDSOAK          run without interrupt load
;   SDSOAK I        run with CTC interrupts at the default rate
;   SDSOAK I 20     run with CTC interrupts, time constant 20
;
; Two things this exists to catch that nothing so far could.
;
; 1. ADDRESSING.  Every test until now used LBA 0, which is the ONE address
;    where the SDHC block-addressed and SDSC byte-addressed paths compute the
;    same result (0 * 512 == 0).  block_addressed, the CCS bit from CMD58 and
;    the whole 32-bit LBA path were therefore untested.  The LBA table below
;    spans low, mid and high blocks, including past 65536 so the upper address
;    bytes are exercised, and every block carries its own LBA so a read that
;    returns the WRONG block fails loudly instead of passing silently.
;
; 2. INTERRUPT LATENCY.  The MCU is clock master and never waits mid-transfer:
;    it clocks a byte every 6 us reading, 24 us writing, whatever the Z80 is
;    doing.  So any host-side stall inside the INI/OUTI loop is unrecoverable.
;    On a read the SIO's 3-byte RX FIFO overflows and bytes are lost; on a
;    write the transmitter under-runs and streams fill.  Both corrupt data
;    rather than raising an error.  The read loop runs 5.6 us against a 6 us
;    budget -- about 7% headroom, less than one interrupt's latency.
;
;    The CTC gives a repeatable interrupt rate, which beats hammering the
;    keyboard.  The BIOS now masks interrupts only while each byte stream is
;    active, because the MCU clock cannot pause.  This mode therefore tests
;    the bounded blackout and recovery between transfers, not ISR tolerance
;    inside the INI/OUTI loop.
;
; NEVER test with all-zero data: zeros are indistinguishable from transmit
; underrun fill, which is exactly the failure that hid a de-shift bug for
; several rounds.  Every block here carries a non-zero header, so a block that
; reads back as all zeros is always a failure.
;
; WARNING: this writes to every LBA in the table.  Test cards only.

	.module ioc_sdsoak
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
BDOS_CONST	= 0x0b		; console status: A != 0 if a key is waiting
BDOS_CONIN	= 0x01
CMD_TAIL	= 0x0080	; CP/M command tail: length byte then text

IOCALL		= 0xDA3F
IOCBULK		= 0xDA45
IOCBULKW	= 0xDA48
	.include "ioc_levels.inc"
	.include "ioc_diag_record.inc"


CMD_PING		  = 0x01
RSP_PING		  = 0x81
CMD_SD_READ_BULK  = 0x05
RSP_SD_READ_BULK  = 0x85
CMD_XFER_STATUS	  = 0x06
RSP_XFER_STATUS	  = 0x86
CMD_SD_WRITE_BULK = 0x07
RSP_SD_WRITE_BULK = 0x87

PREAMBLE_0	= 0xa5
PREAMBLE_1	= 0x5a

BLOCK_SIZE	= 512
NUM_LBA		= 8
MAX_DETAIL	= 8		; detailed mismatch reports before counting only

; ---------------------------------------------------------------------------
; CTC interrupt load
;
; Channel 0, timer mode, prescaler 256, interrupt enabled.  Assuming a 10 MHz
; CTC clock: 10e6 / 256 = 39062.5 Hz, so the time constant is very nearly the
; period in milliseconds' reciprocal -- TC 39 gives ~1.0 ms, TC 20 ~0.5 ms,
; TC 4 ~0.1 ms.  If the CTC is fed something other than the CPU clock these
; scale accordingly; the rate is reported at startup so it can be checked
; against a stopwatch over a long run.
;
; The vector goes at DD00h.  With I = DDh the CPU reads its vector word from
; page DDh, and DD00h-DD0Fh is free space below the BIOS's own SIO entry at
; DD10h -- verified against the built image, not assumed.  A CTC base vector of
; 00h puts channel 0 at DD00h.
;
; ISR_PAD_LOOPS lengthens the ISR to emulate a real driver's.  Each iteration
; is 16 T-states.  Default 0 = the shortest useful ISR, about 60 T (6 us at
; 10 MHz), which a read can just absorb: the SIO's 3-byte RX FIFO buys about
; 18 us at 6 us/byte.  Raise it to find where that breaks -- that number is the
; interrupt budget the transport can actually tolerate, which is worth knowing
; before storage moves behind this.
; ---------------------------------------------------------------------------
CTC0_CTRL	= 0x40
CTC_VECTOR_BASE	= 0x00
CTC_VECTOR_ADDR	= 0xDD00
CTC_CONTROL	= 0xa7		; int on, timer, /256, TC follows, reset, control
CTC_STOP	= 0x03		; software reset, no interrupt
CTC_TC_DEFAULT	= 39		; ~1 ms at 10 MHz / 256
ISR_PAD_LOOPS	= 0

; ===========================================================================
start:
	; CP/M enters a .COM with the return address to the CCP already on its
	; stack.  Switching to a private stack therefore discards it, and a bare
	; RET at the end would pop two uninitialised bytes and jump there.  Save
	; the entry SP and put it back before returning.
	;
	; A private stack is worth having: the CCP's is shallow and this program
	; nests BDOS calls underneath an interrupt handler.
	ld (entry_sp),sp
	ld sp,#stack_top

	ld de,#msg_banner
	call puts
	call check_level
	or a
	jr z,protocol_ok
	push af
	ld de,#msg_protocol
	call puts
	pop af
	call print_hex_byte
	call crlf
	ld sp,(entry_sp)
	ret
protocol_ok:

	call parse_tail

	; Report the configuration, so a run's output says what produced it.
	ld de,#msg_cfg_int
	call puts
	ld a,(int_enable)
	or a
	jr z,cfg_no_int
	ld de,#msg_on
	call puts
	ld de,#msg_cfg_tc
	call puts
	ld a,(ctc_tc)
	call print_hex_byte
	call crlf
	call ctc_setup
	jr cfg_done
cfg_no_int:
	ld de,#msg_off
	call puts
	call crlf
cfg_done:
	ld de,#msg_hint
	call puts

	; Counters
	ld hl,#0
	ld (pass_count),hl
	ld (err_write),hl
	ld (err_read),hl
	ld (err_verify),hl
	ld (int_count),hl
	xor a
	ld (detail_count),a
	ld (fail_code),a
	ld (fail_info),a
	ld (fail_rr1),a
	ld (fail_rr0),a

; --- one pass over the whole LBA table -------------------------------------
pass_loop:
	xor a
	ld (lba_index),a

lba_loop:
	call load_lba			; cur_lba <- table[lba_index]
	call build_block		; ref_buf <- expected contents

	call do_write
	or a
	jr nz,lba_next			; write failed; already counted

	call do_read
	or a
	jr nz,lba_next			; read failed; already counted

	call verify

lba_next:
	; Abort on any keypress, so a long run can be stopped cleanly.
	ld c,#BDOS_CONST
	call BDOS
	or a
	jr nz,soak_done

	ld a,(lba_index)
	inc a
	ld (lba_index),a
	cp #NUM_LBA
	jr c,lba_loop

	ld hl,(pass_count)
	inc hl
	ld (pass_count),hl
	call report_pass
	jr pass_loop

soak_done:
	ld c,#BDOS_CONIN		; consume the key
	call BDOS

	; Stop the timer unconditionally.  Leaving it running with a vector
	; pointing into a TPA that the next program will overwrite is the one
	; way this test can take the machine down with it, so it is not made
	; conditional on how the run was configured.
	call ctc_stop

	ld de,#msg_stopped
	call puts
	call report_pass

	ld sp,(entry_sp)		; hand the CCP its stack back
	ret

; ---------------------------------------------------------------------------
; parse_tail — look for 'I' (interrupts on) and an optional decimal time
; constant.  Anything else is ignored, so a bare SDSOAK runs the plain soak.
; ---------------------------------------------------------------------------
parse_tail:
	xor a
	ld (int_enable),a
	ld a,#CTC_TC_DEFAULT
	ld (ctc_tc),a

	ld hl,#CMD_TAIL
	ld a,(hl)
	or a
	ret z				; empty tail
	ld b,a				; characters remaining
	inc hl
pt_scan:
	ld a,b
	or a
	ret z
	ld a,(hl)
	cp #'I
	jr z,pt_int
	cp #'i
	jr z,pt_int
	cp #0x30			; '0'
	jr c,pt_skip
	cp #0x3a			; past '9'
	jr nc,pt_skip
	call pt_number			; advances HL, decrements B
	jr pt_scan
pt_int:
	ld a,#1
	ld (int_enable),a
pt_skip:
	inc hl
	dec b
	jr pt_scan

; Parse a decimal number at HL into ctc_tc, advancing HL and decrementing B
; past the digits.  The accumulator lives in memory: an earlier version kept it
; in C and then did pop bc/push bc to preserve the caller's count, which
; silently destroyed it on the first digit.
;
; A result of zero is rejected and the default kept -- the CTC reads a time
; constant of 0 as 256, which is valid but would quietly mean 6.5 ms.
pt_number:
	xor a
	ld (tc_acc),a
pn_digit:
	ld a,(hl)
	cp #0x30
	jr c,pn_end
	cp #0x3a
	jr nc,pn_end
	sub #0x30
	ld e,a				; this digit
	ld a,(tc_acc)
	add a,a				; x2
	ld d,a
	add a,a				; x4
	add a,a				; x8
	add a,d				; x10
	add a,e
	ld (tc_acc),a
	inc hl
	dec b
	jr nz,pn_digit
pn_end:
	ld a,(tc_acc)
	or a
	ret z				; unusable; keep the default
	ld (ctc_tc),a
	ret

; ---------------------------------------------------------------------------
; CTC channel 0 as a periodic interrupt source.
; ---------------------------------------------------------------------------
ctc_setup:
	di
	; Install the ISR vector in the free part of the IM2 page.
	ld hl,#ctc_isr
	ld (CTC_VECTOR_ADDR),hl

	ld a,#CTC_VECTOR_BASE		; bit 0 = 0 -> this is a vector write
	out (CTC0_CTRL),a
	ld a,#CTC_CONTROL
	out (CTC0_CTRL),a
	ld a,(ctc_tc)
	out (CTC0_CTRL),a		; time constant starts the timer
	ei
	ret

ctc_stop:
	di
	ld a,#CTC_STOP
	out (CTC0_CTRL),a
	ei
	ret

; The interrupt itself.  Deliberately minimal by default: the point is the
; latency it injects into the transfer loops, not what it computes.  Every
; register it touches is saved -- the INI/OUTI loops own B, C, DE and HL, and
; corrupting any of them would look like a transport fault.
ctc_isr:
	push af
	push hl
	ld hl,(int_count)
	inc hl
	ld (int_count),hl
.if ISR_PAD_LOOPS
	ld a,#ISR_PAD_LOOPS
isr_pad:
	dec a				;  4
	jr nz,isr_pad			; 12
.endif
	pop hl
	pop af
	ei
	reti

; ---------------------------------------------------------------------------
; load_lba — cur_lba <- lba_table[lba_index]
; ---------------------------------------------------------------------------
load_lba:
	ld a,(lba_index)
	add a,a				; x4: entries are 4 bytes
	add a,a
	ld e,a
	ld d,#0
	ld hl,#lba_table
	add hl,de
	ld de,#cur_lba
	ld bc,#4
	ldir
	ret

; ---------------------------------------------------------------------------
; build_block — fill ref_buf with this block's expected contents.
;
; Bytes 0-7 are a header carrying the LBA, so a read that returns a different
; block is detected rather than silently accepted.  Bytes 8-511 are pattern.
; ---------------------------------------------------------------------------
build_block:
	; Pattern rotates per pass.  Compute it BEFORE the header is written --
	; an earlier version stored the previous pass's id into the block.
	ld a,(pass_count)
	and #0x03
	ld (pattern_id),a

	ld hl,#ref_buf
	ld (hl),#0x53			; 'S'
	inc hl
	ld (hl),#0x4b			; 'K'
	inc hl
	ld de,#cur_lba			; LBA, little-endian
	ld a,(de)
	ld (hl),a
	inc hl
	inc de
	ld a,(de)
	ld (hl),a
	inc hl
	inc de
	ld a,(de)
	ld (hl),a
	inc hl
	inc de
	ld a,(de)
	ld (hl),a
	inc hl
	ld a,(pattern_id)
	ld (hl),a
	inc hl
	ld a,(pass_count)
	ld (hl),a
	inc hl				; HL now at ref_buf + 8

	ld a,(pattern_id)
	ld bc,#(BLOCK_SIZE - 8)		; bytes remaining
	cp #1
	jr z,bp_ff
	cp #2
	jr z,bp_aa55
	cp #3
	jr z,bp_preamble

	; pattern 0: ramp seeded by the LBA low byte, so adjacent blocks differ
	ld a,(cur_lba)
	ld e,a
bp_ramp:
	ld (hl),e
	inc hl
	inc e
	dec bc
	ld a,b
	or c
	jr nz,bp_ramp
	ret

	; pattern 1: FFh runs -- the marking/idle level on this link
bp_ff:
	ld (hl),#0xff
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,bp_ff
	ret

	; pattern 2: AA/55 -- maximum transition density, worst case for the
	; 2 MHz bulk clock and any signal-integrity marginality
bp_aa55:
	ld e,#0xaa
bp_aa_loop:
	ld (hl),e
	inc hl
	ld a,e
	xor #0xff
	ld e,a
	dec bc
	ld a,b
	or c
	jr nz,bp_aa_loop
	ret

	; pattern 3: the alignment preamble itself, repeated.  This is the
	; adversarial case for find_bulk_start: if the search can false-lock on
	; an A5 5A inside the payload, this is what finds it.
bp_preamble:
	ld e,#PREAMBLE_0
bp_pre_loop:
	ld (hl),e
	inc hl
	ld a,e
	cp #PREAMBLE_0
	ld e,#PREAMBLE_1
	jr z,bp_pre_next
	ld e,#PREAMBLE_0
bp_pre_next:
	dec bc
	ld a,b
	or c
	jr nz,bp_pre_loop
	ret

; ---------------------------------------------------------------------------
; do_write — write ref_buf to cur_lba.  Returns A = 0 on success.
; Counts its own failures so callers only branch on the result.
; ---------------------------------------------------------------------------
do_write:
	call zero_frames
	ld a,#CMD_SD_WRITE_BULK
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a
	call copy_lba_to_frame

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dw_c2
	ld (fail_info),a		; keep IOCALL's own status
	ld a,#1
	jp dw_fail_n
dw_c2:
	ld a,(rx_frame + 0)
	cp #RSP_SD_WRITE_BULK
	jr z,dw_c3
	ld a,#2				; wrong reply class
	jp dw_fail_n
dw_c3:
	ld a,(rx_frame + 2)
	or a
	jr z,dw_c4
	ld a,#3				; MCU refused: READY status non-zero
	jp dw_fail_n
	; fall through is not possible; the echo check follows the status check
dw_c4:
	call check_lba_echo
	jr z,dw_arm
	ld a,#12			; MCU decoded a DIFFERENT LBA -- do not write
	jp dw_fail_n

; Does the MCU's READY reply quote back the LBA we asked for?  Z = yes.
;
; Cheap and worth it: a write to the wrong sector is the one failure this test
; cannot detect by reading back, because the read would go to the wrong sector
; too and agree with itself.
check_lba_echo:
	ld hl,#(rx_frame + 8)
	ld de,#cur_lba
	ld b,#4
cle_loop:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz cle_loop
	xor a				; Z set: match
	ret

dw_arm:
	; One BIOS call replaces the whole transmit phase: arming channel A, the
	; RTS handshake, the preamble, the OUTI loop, the CRC trailer, the
	; underrun check and the interrupt guard all live in IOCBULKW now.  This
	; program touches no SIO register.
	ld hl,#ref_buf
	ld de,#BLOCK_SIZE
	call IOCBULKW
	or a
	jr z,dw_sent
	ld (fail_info),a
	ld a,#6				; IOCBULKW failed
	jp dw_fail_n
dw_sent:

	; No /CTSA wait here.  IOCBULKW holds the lane until the MCU releases
	; /CTSA, which for a write is after the card commit, so by the time it
	; returns the command lane is already listening.

	; DONE is mandatory for a write: the card is only touched after the last
	; byte lands, so the status does not exist until now.
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dw_d2
	ld (fail_info),a		; IOCALL status: 01 send, 11 no reply,
	ld a,#8
	jp dw_fail_n
dw_d2:
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jr z,dw_d3
	ld a,#9				; wrong DONE reply class
	jp dw_fail_n
dw_d3:
	ld a,(rx_frame + 5)
	or a
	jr z,dw_good
	ld (fail_info),a		; the MCU's own status byte
	ld a,#10			; DONE reports the transfer failed
	jp dw_fail_n
dw_good:
	xor a
	ret

; Release RTS before reporting, so a failed write does not leave the lane
; asserted into the next attempt.  A holds the failure code.
dw_fail_n:
	ld (fail_code),a
	ld hl,(err_write)
	inc hl
	ld (err_write),hl
	ld de,#msg_ewrite
	call report_lba_err
	ld de,#msg_code
	call puts
	ld a,(fail_code)
	call print_hex_byte
	ld de,#msg_info
	call puts
	ld a,(fail_info)
	call print_hex_byte
	ld de,#msg_rr0
	call puts
	ld a,(fail_rr0)
	call print_hex_byte
	ld de,#msg_rr1
	call puts
	ld a,(fail_rr1)
	call print_hex_byte
	call crlf
	xor a
	ld (fail_info),a
	ld (fail_rr1),a
	ld a,#1
	ret

; ---------------------------------------------------------------------------
; do_read — read cur_lba into rd_buf.  Returns A = 0 on success.
; ---------------------------------------------------------------------------
do_read:
	call zero_frames
	ld a,#CMD_SD_READ_BULK
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a
	call copy_lba_to_frame

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,dr_c2
	ld (fail_info),a		; IOCALL's own status
	ld a,#1				; command IOCALL failed
	jr dr_fail_n
dr_c2:
	ld a,(rx_frame + 0)
	cp #RSP_SD_READ_BULK
	jr z,dr_c3
	ld (fail_info),a		; the class we actually got
	ld a,#2				; wrong reply class
	jr dr_fail_n
dr_c3:
	ld a,(rx_frame + 2)
	or a
	jr z,dr_c4
	ld (fail_info),a		; the MCU's SD status
	ld a,#3				; MCU refused the read
	jr dr_fail_n
dr_c4:
	call check_lba_echo
	jr z,dr_bulk
	ld a,#6				; MCU decoded a DIFFERENT LBA
	jr dr_fail_n

dr_bulk:
	; IOCBULK owns the whole SIO1/A handshake; we touch no SIO registers.
	; Payload length only.  IOCBULK carries and verifies the CRC trailer
	; itself now, so the buffer and the count are both payload-sized.
	ld hl,#rd_buf
	ld a,(rx_frame + 6)
	ld e,a
	ld a,(rx_frame + 7)
	ld d,a
	call IOCBULK
	or a
	jr z,dr_good
	ld (fail_info),a		; IOCBULK status: 01 timeout, 02 bad len,
	ld a,#4				; 03 /CTSA stuck
	jr dr_fail_n

dr_good:
	xor a
	ret

dr_fail_n:
	ld (fail_code),a
	ld hl,(err_read)
	inc hl
	ld (err_read),hl
	ld de,#msg_eread
	call report_lba_err
	ld de,#msg_code
	call puts
	ld a,(fail_code)
	call print_hex_byte
	ld de,#msg_info
	call puts
	ld a,(fail_info)
	call print_hex_byte
	ld de,#msg_rr0
	call puts
	ld a,(fail_rr0)
	call print_hex_byte
	ld de,#msg_rr1
	call puts
	ld a,(fail_rr1)
	call print_hex_byte
	call crlf
	ld a,(fail_code)
	cp #4				; IOCBULK failure, not READY/SD metadata
	call z,report_bulk_transport_diag
	xor a
	ld (fail_info),a
	ld (fail_rr1),a
	ld a,#1
	ret

; ---------------------------------------------------------------------------
; verify — compare rd_buf against ref_buf, all 512 bytes.
; ---------------------------------------------------------------------------
verify:
	ld hl,#ref_buf
	ld de,#rd_buf
	ld bc,#BLOCK_SIZE
vf_loop:
	ld a,(de)
	cp (hl)
	jr nz,vf_bad
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,vf_loop
	ret

vf_bad:
	; HL/DE point at the offending byte; BC counts what was left.
	push hl
	push de
	push bc
	ld hl,(err_verify)
	inc hl
	ld (err_verify),hl
	pop bc
	pop de
	pop hl

	; Offset = BLOCK_SIZE - BC
	push hl
	push de
	ld hl,#BLOCK_SIZE
	scf
	ccf
	sbc hl,bc
	ld (bad_offset),hl
	pop de
	pop hl

	ld a,(de)
	ld (bad_got),a
	ld a,(hl)
	ld (bad_exp),a

	; Only the first few get a detailed line; after that just count, so a
	; systematic failure does not bury the summary in output.
	ld a,(detail_count)
	cp #MAX_DETAIL
	ret nc
	inc a
	ld (detail_count),a

	ld de,#msg_everify
	call report_lba_err

	; Which pattern was in flight.  Pattern 3 is the repeated A5 5A, the
	; adversarial case for find_bulk_start -- if mismatches cluster there,
	; the preamble can false-lock inside payload data and that is a design
	; fault, not a timing one.
	ld de,#msg_pat
	call puts
	ld a,(ref_buf + 6)
	call print_hex_byte

	ld de,#msg_at
	call puts
	ld hl,(bad_offset)
	call print_hex_word
	ld de,#msg_exp
	call puts
	ld a,(bad_exp)
	call print_hex_byte
	ld de,#msg_got
	call puts
	ld a,(bad_got)
	call print_hex_byte
	call crlf
	ret

; ---------------------------------------------------------------------------
; Reporting helpers
; ---------------------------------------------------------------------------
; Print "<msg> lba=xxxxxxxx" with no newline terminator of its own.
report_lba_err:
	call puts
	ld de,#msg_lba
	call puts
	ld hl,#(cur_lba + 3)		; print big-endian for readability
	ld b,#4
rle_loop:
	push bc
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	dec hl
	pop bc
	djnz rle_loop
	ret				; caller decides whether a newline follows

report_pass:
	ld de,#msg_pass
	call puts
	ld hl,(pass_count)
	call print_hex_word
	ld de,#msg_wr
	call puts
	ld hl,(err_write)
	call print_hex_word
	ld de,#msg_rd
	call puts
	ld hl,(err_read)
	call print_hex_word
	ld de,#msg_vf
	call puts
	ld hl,(err_verify)
	call print_hex_word
	ld a,(int_enable)
	or a
	jr z,rp_done
	ld de,#msg_ints
	call puts
	ld hl,(int_count)
	call print_hex_word
rp_done:
	call crlf
	ret

; Fixed-RAM trace captured by IOCBULK before it returns a transport error.
report_bulk_transport_diag:
	ld de,#msg_bulk_diag_reason
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_REASON)
	call print_hex_byte
	ld de,#msg_bulk_diag_rr
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_RR0)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_RR1)
	call print_hex_byte
	ld de,#msg_bulk_diag_sync
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_SYNCED)
	call print_hex_byte
	ld de,#msg_bulk_diag_xfer
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_TYPE)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_BULK_SEQ)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_BULK_STATUS)
	call print_hex_byte
	ret

; B bytes at HL, prefixed with spaces.
dump_bytes:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz dump_bytes
	ret

copy_lba_to_frame:
	ld hl,#cur_lba
	ld de,#(tx_frame + 4)
	ld bc,#4
	ldir
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

; Refuse a long destructive soak unless both ends advertise this wire format.
; A = 0 on match; E0 BIOS, E1 PING transport/class, E2 controller level.
check_level:
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jr nz,check_level_bios
	call zero_frames
	ld a,#CMD_PING
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,check_level_link
	ld a,(rx_frame + 0)
	cp #RSP_PING
	jr nz,check_level_link
	ld a,(rx_frame + 20)
	cp #IOC_FW_LEVEL
	jr nz,check_level_fw
	xor a
	ret
check_level_bios:
	ld a,#0xe0
	ret
check_level_link:
	ld a,#0xe1
	ret
check_level_fw:
	ld a,#0xe2
	ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
; Low, mid and high blocks.  65536 and above exercise the upper LBA bytes and
; the block-vs-byte addressing decision, which LBA 0 cannot distinguish.
lba_table:
	.db 0x00, 0x00, 0x00, 0x00	; 0
	.db 0x01, 0x00, 0x00, 0x00	; 1
	.db 0x02, 0x00, 0x00, 0x00	; 2
	.db 0xff, 0x00, 0x00, 0x00	; 255
	.db 0x00, 0x01, 0x00, 0x00	; 256
	.db 0x00, 0x10, 0x00, 0x00	; 4096
	.db 0x00, 0x00, 0x01, 0x00	; 65536   -- 32 MB, upper byte
	.db 0x00, 0x00, 0x10, 0x00	; 1048576 -- 512 MB

msg_banner:
	.ascii "IOC SD SOAK - write/read/verify"
	.db 0x0d, 0x0a, '$'
msg_protocol:
	.ascii "protocol level mismatch code "
	.db '$'
msg_hint:
	.ascii "any key stops.  counts are hex."
	.db 0x0d, 0x0a, '$'
msg_cfg_int:
	.ascii "CTC interrupt load: "
	.db '$'
msg_cfg_tc:
	.ascii " TC=0x"
	.db '$'
msg_on:
	.ascii "ON"
	.db '$'
msg_off:
	.ascii "OFF"
	.db '$'
msg_pass:
	.ascii "pass "
	.db '$'
msg_wr:
	.ascii "  wr-err "
	.db '$'
msg_rd:
	.ascii "  rd-err "
	.db '$'
msg_vf:
	.ascii "  vfy-err "
	.db '$'
msg_ints:
	.ascii "  ints "
	.db '$'
msg_ewrite:
	.ascii "WRITE FAIL"
	.db '$'
msg_eread:
	.ascii "READ FAIL"
	.db '$'
msg_everify:
	.ascii "MISMATCH"
	.db '$'
msg_code:
	.ascii " code="
	.db '$'
msg_rr0:
	.ascii " rr0="
	.db '$'
msg_rr1:
	.ascii " rr1="
	.db '$'
msg_info:
	.ascii " info="
	.db '$'
msg_bulk_diag_reason:
	.ascii "  bulk reason="
	.db '$'
msg_bulk_diag_rr:
	.ascii " rr="
	.db '$'
msg_bulk_diag_sync:
	.ascii " bsync="
	.db '$'
msg_bulk_diag_xfer:
	.ascii " xfer(type/seq/status)="
	.db '$'
msg_lba:
	.ascii " lba="
	.db '$'
msg_pat:
	.ascii " pat "
	.db '$'
msg_at:
	.ascii " at "
	.db '$'
msg_exp:
	.ascii " exp "
	.db '$'
msg_got:
	.ascii " got "
	.db '$'
msg_stopped:
	.ascii "stopped."
	.db 0x0d, 0x0a, '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'


puts:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ret

crlf:
	push hl
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ret

print_hex_word:
	ld a,h
	push hl
	call print_hex_byte
	pop hl
	ld a,l
	; fall through

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
	push hl
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ret

entry_sp:	.ds 2
int_enable:	.ds 1
tc_acc:		.ds 1
ctc_tc:		.ds 1
lba_index:	.ds 1
pattern_id:	.ds 1
detail_count:	.ds 1
fail_code:	.ds 1
fail_info:	.ds 1
fail_rr1:	.ds 1
fail_rr0:	.ds 1
bad_exp:	.ds 1
bad_got:	.ds 1
bad_offset:	.ds 2
pass_count:	.ds 2
err_write:	.ds 2
err_read:	.ds 2
err_verify:	.ds 2
int_count:	.ds 2
cur_lba:	.ds 4
tx_frame:	.ds 32
rx_frame:	.ds 32
ref_buf:	.ds BLOCK_SIZE
rd_buf:		.ds BLOCK_SIZE
	.ds 192				; BDOS nesting plus an ISR frame
stack_top:
