; IOC_SDBENCH.COM — what storage actually costs a program on this machine.
;
; Three measurements, at three different depths of the same stack.  Which one
; you want depends on what you are about to design.
;
;   SDBENCH [d:]name        BDOS sequential read of a CP/M file.
;                           The path an ordinary program takes.  READ ONLY.
;   SDBENCH name /S         IO Controller FS bulk read of /SHARED/name at
;                           128, 256 and 512 bytes per transaction.  READ ONLY.
;   SDBENCH                 raw 512-byte card read and write, no filesystem.
;                           DESTRUCTIVE — see the warning below.
;
;   /C                      with /S: re-read a 2 KiB window so every transfer
;                           after the first lap is a controller cache hit and
;                           the card is out of the measurement.
;   /N                      run without the counter: correctness, no timing.
;
; ---------------------------------------------------------------------------
; THE POINT OF SEPARATING THEM
; ---------------------------------------------------------------------------
;
; The raw mode is the oldest of the three and measures the card and the link
; with the filesystem taken out of the way, timed by the controller's own
; millisecond counters.  It answers "how fast is this card".
;
; The two file modes answer the question a resource or streaming library
; actually has to be designed against: what does a READ COST THE PROGRAM, from
; the call it makes down to the card and back.  They are timed on the Z80, by
; the CTC, because that is where the program experiences the cost.
;
; They also report the distribution, not just the mean.  A streamer that has to
; hold a frame rate does not care what a read costs on average; it cares what
; the worst one costs, and how often the worst one happens.  That is what the
; histogram is for, and it is the reason this program does not stop at a
; throughput figure.
;
; ---------------------------------------------------------------------------
; WHAT IS NOT MEASURED, AND WILL NOT BE
; ---------------------------------------------------------------------------
;
; There is no 1024-byte or larger row, and there is no "512-byte BDOS read".
; CP/M 2.2's sequential read moves one 128-byte record per call and the
; controller's FS chunk maximum is 512 bytes.  Four calls grouped behind a
; bigger buffer are four transactions; labelling them as one larger transfer
; would misreport the only number this program exists to produce.  See
; sdbench_file.inc for what each mode really does on the wire.
;
; ---------------------------------------------------------------------------
; WARNING, raw mode only
; ---------------------------------------------------------------------------
;
; Raw mode writes LBA 00100000h (512 MiB offset) 128 times and does not restore
; it.  Test cards only.  It prompts first.  The two file modes never write
; anything and never prompt.
;
; Raw mode deliberately bypasses the controller's record cache and uses the raw
; 512-byte commands, so every timed transfer reaches the card:
;
;   READ   CMD_SD_READ_BULK -> READY -> IOCBULK
;   WRITE  CMD_SD_WRITE_BULK -> READY -> IOCBULKW -> XFER_STATUS/DONE
;
; The controller's PROFILE counters provide its clock.  Firmware level 20 moved
; that profiler from Timer1 (which the command link reconfigures as an SCK edge
; counter) to independent Timer3 and added a deferred reset request, so each
; phase starts at zero and excludes the reset transaction.  PROFILE is served
; only by a diagnostic controller build.
;
; The read report separates CMD17/dispatch from the bulk lane.  The write report
; necessarily combines the inbound bulk phase and CMD24: the controller holds
; /CTSA until the card leaves write-busy, and the host cannot observe an
; intermediate boundary.  TOTAL is the active controller service time and
; excludes semantic buffer comparison and console output, matching BULK.COM.
; A final raw read verifies the last written ramp.

	.module ioc_sdbench
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONIN	= 0x01
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09


	.include "ioc_levels.inc"
	; IOC failure-record field offsets: SDBENCH reads the parallel
	; hardware-CRC tally the BIOS leaves in the reserved bytes.
	.include "ioc_diag_record.inc"

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

	; The command tail is parsed before anything else because it lives at
	; 0080h, which is also the default DMA buffer: the first record read lands
	; on top of it.  This is the only moment the switches still exist.
	call parse_tail
	or a
	jp nz,finish

	ld a,(mode)
	or a
	jr z,mode_raw

	; A file mode needs Zephyr BDOS function 200 for the timer, so the BIOS
	; has to be a Zephyr BIOS.  It does not need the controller firmware to be
	; any particular level: BDOS mode speaks no IOC protocol at all, and
	; refusing to measure good hardware over a level it never uses would be
	; nothing but obstruction.
	call zb_xport_level
	cp #ZBIOS_XPORT_LEVEL
	jr z,mode_file
	ld (fail_info),a
	ld de,#msg_bios_level
	call puts
	ld a,(fail_info)
	call print_hex_byte
	call crlf
	jp finish
mode_file:
	ld a,(mode)
	cp #2
	jp z,bench_fs
	; STORAGE_PROFILE host experiment.
	cp #3
	jp z,bench_hit
	jp bench_bdos

	; Raw mode speaks the protocol, so it checks the controller too.
mode_raw:
	ld de,#msg_raw_head
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
	; Ask whether this controller implements the diagnostic surface BEFORE
	; asking the operator to sacrifice a card to it.  A normal build answers
	; RSP_UNKNOWN_COMMAND to CMD_PROFILE, and to the raw block commands this
	; mode is built on; going ahead would prompt for a destructive run that
	; could not have produced a number either way.
	call raw_probe
	or a
	jr z,raw_available
	ld de,#msg_normal_build
	call puts
	jp finish

raw_available:
	ld de,#msg_warning
	call puts
	ld c,#BDOS_CONIN
	call BDOS
	cp #'Y'
	jp z,confirmed
	cp #'y'
	jp z,confirmed
	ld de,#msg_cancelled
	call puts
	jp finish

; Does this controller serve the diagnostic command surface?
; Out: A = 0 yes, or the link failed and the ordinary path will report it;
;      A = 1 the controller rejected CMD_PROFILE as an unknown class.
raw_probe:
	call zero_frames
	ld a,#CMD_PROFILE
	ld (tx_frame + 0),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,raw_probe_ok		; a transport fault is not a build answer
	ld a,(rx_frame + 0)
	cp #RSP_PROFILE
	jr z,raw_probe_ok
	ld a,#1
	ret
raw_probe_ok:
	xor a
	ret

; ---------------------------------------------------------------------------
; Command tail.
;
; A name selects a file mode; no name at all selects the raw card benchmark,
; which is what this program used to be and still is when asked for nothing.
; Out: A = 0 to continue, non-zero when the tail was rejected and said so.
; ---------------------------------------------------------------------------
parse_tail:
	xor a
	ld (mode),a
	ld (no_timer),a

	; /N runs the pass with the counter never started.  It measures nothing;
	; it exists so a failure can be told apart from a timing artefact in one
	; run, without rebuilding anything.
	ld a,#'N'
	call opt_find
	jr c,tail_mode
	ld a,#1
	ld (no_timer),a

tail_mode:
	xor a
	ld (fs_cached),a
	ld a,#'C'
	call opt_find
	jr c,tail_want_s
	ld a,#1
	ld (fs_cached),a
tail_want_s:
	ld a,#'S'
	call opt_find
	ld a,#0
	jr c,tail_have_s
	inc a
tail_have_s:
	ld (want_fs),a

	; FCB1 holds eleven spaces when the CCP was given no name.  It holds the
	; switch when the CCP was given only a switch: `SDBENCH /S` parses "/S" as
	; the file name, and no CP/M name can begin with a slash, so that is how a
	; missing name is told from a real one.
	ld a,(FCB1 + 1)
	cp #' '
	jr z,tail_no_name
	cp #'/'
	jr nz,tail_named

tail_no_name:
	; Falling through to the raw card benchmark here would answer a request to
	; read a file with a prompt to overwrite a card.  It prompts, so nothing
	; would be lost by accident -- but being asked an unrelated destructive
	; question is not an answer, and the raw mode is reached by asking for
	; nothing at all, never by asking for something that was not understood.
	ld a,(want_fs)
	or a
	jr z,tail_done
	ld de,#msg_no_name
	call puts
	ld a,#1
	ret

tail_named:
	ld a,#1
	ld (mode),a
	ld a,(want_fs)
	or a
	jr z,tail_done
	ld a,#2
	ld (mode),a
tail_done:
	; STORAGE_PROFILE options are validated before reaching raw mode.
	jp sp_parse_options

; Find /<letter> in the command tail, folding case.
; In:  A = the letter, upper case.
; Out: carry set = absent.  Carry clear = found, HL -> the character after it,
;      which may be one past the end of the tail: check opt_end before reading.
opt_find:
	ld (opt_want),a
	ld a,(TAIL)
	or a
	jr z,opt_none
	ld c,a
	ld b,#0
	ld hl,#TAIL + 1
	push hl
	add hl,bc
	ld (opt_end),hl
	pop hl
opt_loop:
	call opt_at_end
	jr nc,opt_none
	ld a,(hl)
	inc hl
	cp #'/'
	jr nz,opt_loop
	call opt_at_end
	jr nc,opt_none
	ld a,(hl)
	inc hl
	and #0xdf			; fold case
	ld c,a
	ld a,(opt_want)
	cp c
	jr nz,opt_loop
	or a				; clears carry
	ret
opt_none:
	scf
	ret

; Carry set = HL is still inside the tail.  Preserves HL.
opt_at_end:
	push hl
	ld de,(opt_end)
	or a
	sbc hl,de
	pop hl
	ret

; Decimal number at HL, bounded by opt_end.  Out: A = value, or 0 for no digits.
; A three-digit value above 255 wraps; the caller rejects the range it cares
; about, and the only value this parses is a CTC time constant of 1 to 255.
opt_number:
	ld c,#0
	ld b,#0
opt_num_loop:
	call opt_at_end
	jr nc,opt_num_done
	ld a,(hl)
	sub #'0'
	jr c,opt_num_done
	cp #10
	jr nc,opt_num_done
	ld e,a
	ld a,c
	add a,a
	ld c,a				; c = v * 2
	add a,a
	add a,a				; a = v * 8
	add a,c				; a = v * 10
	add a,e
	ld c,a
	inc hl
	inc b
	jr opt_num_loop
opt_num_done:
	ld a,b
	or a
	ret z				; no digits at all
	ld a,c
	ret

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
	call zb_xport_level
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
	.ascii "Zephyr-80 SD Benchmark (timer fix r5: 1.6us ticks)"
	.db 13,10,'$'
msg_normal_build:
	.ascii "This controller runs NORMAL firmware. A normal build does not"
	.db 13,10
	.ascii "implement CMD_PROFILE, CMD_BULK_TEST or the raw 512-byte SD"
	.db 13,10
	.ascii "commands, so raw mode and BULK.COM cannot run on it and report"
	.db 13,10
	.ascii "an unknown class rather than a fault. Either reflash with"
	.db 13,10
	.ascii "IOC_PROFILE=diagnostic, or use the file modes below: they time"
	.db 13,10
	.ascii "on the Z80 and need none of those commands."
	.db 13,10
	.ascii "  SDBENCH [d:]FILE      BDOS 128-byte records"
	.db 13,10
	.ascii "  SDBENCH FILE /S       FS bulk at 128, 256 and 512 bytes"
	.db 13,10,'$'
msg_raw_head:
	.ascii "Raw card: 128 x 512-byte read + write, no filesystem"
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

; ---------------------------------------------------------------------------
; File-mode text.
; ---------------------------------------------------------------------------
msg_bios_level:
	.ascii "not a Zephyr BIOS, or transport level 0x$"
msg_no_name:
	.ascii "/S needs the name of a file in /SHARED/"
	.db 13,10,'$'
msg_no_file:
	.ascii "file not found"
	.db 13,10,'$'
msg_empty:
	.ascii "file is empty: nothing to measure"
	.db 13,10,'$'
msg_too_big:
	.ascii "file is over 4 MiB; the throughput arithmetic does not reach"
	.db 13,10,'$'
msg_no_timer:
	.ascii "CTC counter not running; 1 = channel 3, 2 = channel 1: $"
msg_file:
	.ascii "File:   $"
msg_shared:
	.ascii "File:   /SHARED/$"
msg_size:
	.ascii "  Size: $"
msg_size_recs:
	.ascii " bytes in $"
msg_size_tail:
	.ascii " records"
	.db 13,10,'$'
msg_size_bytes:
	.ascii " bytes"
	.db 13,10,'$'
msg_timer:
	.ascii "Timer:  CTC3+CTC1 polled, no interrupt, 1 tick = $"
msg_timer_us:
	.ascii " us, range 104 ms per read"
	.db 13,10,'$'
msg_timer_off:
	.ascii "Timer:  none (/N). Correctness only; every time below reads zero."
	.db 13,10,'$'
msg_reading:
	.ascii "Reading. No output until the pass ends; a key stops it."
	.db 13,10,'$'
msg_bdos_head:
	.db 13,10
	.ascii "BDOS sequential read, 128-byte records"
	.db 13,10,'$'
msg_pass:
	.db 13,10
	.ascii "IOC FS bulk read, $"
msg_pass_tail:
	.ascii "-byte transactions$"
msg_pass_cached:
	.ascii ", 2 KiB window held in the controller cache (no card)$"
msg_too_small:
	.ascii "/C needs a file of at least 2048 bytes"
	.db 13,10,'$'
msg_read_err:
	.ascii "BDOS read failed, code 0x$"
msg_aborted:
	.ascii "stopped at the keyboard; the figures below cover what was read"
	.db 13,10,'$'
msg_short:
	.ascii "PREMATURE EOF: read $"
msg_short_of:
	.ascii " of $"
msg_fs_fail:
	.ascii "FS read failed, stage 0x$"

msg_r_bytes:
	.ascii "  bytes $"
msg_r_time:
	.ascii "  time $"
msg_r_ms_sp:
	.ascii " ms $"
msg_r_bps:
	.ascii " B/s $"
msg_r_kib:
	.ascii " KiB/s"
	.db 13,10,'$'
msg_r_reads:
	.ascii "  reads $"
msg_r_min:
	.ascii "  min $"
msg_r_avg:
	.ascii "  avg $"
msg_r_max:
	.ascii "  max $"
msg_r_ms:
	.ascii " ms"
	.db 13,10,'$'
msg_r_hist:
	.ascii "  ms  $"
msg_r_bad:
	.ascii "  DISCARDED unmeasurable samples: $"
msg_deblock:
	.ascii "  deblock line: hits $"
msg_deblock_miss:
	.ascii " misses $"

; Eight labels, each its own $-terminated string, walked in order beside the
; eight counters.  The bucket edges are computed from the time constant in use,
; so these describe the intent; the resolution line above says how coarse the
; nearest tick boundary really is.
msg_hist_labels:
	.ascii "<1:$"
	.ascii "1-2:$"
	.ascii "2-5:$"
	.ascii "5-10:$"
	.ascii "10-20:$"
	.ascii "20-50:$"
	.ascii "50-100:$"
	.ascii ">=100:$"

msg_table_head:
	.db 13,10
	.ascii "Transaction    Throughput      Avg lat    Max lat"
	.db 13,10
	.ascii "-------------------------------------------------"
	.db 13,10,'$'
msg_table_lead:
	.ascii "FS bulk  $"
msg_table_b:
	.ascii " B  $"
msg_table_kib:
	.ascii " KiB/s $"
msg_table_ms:
	.ascii " ms$"

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
mode:		.ds 1
want_fs:	.ds 1
no_timer:	.ds 1
opt_want:	.ds 1
opt_end:	.ds 2
stack_space:	.ds 192			; BDOS nesting under an interrupt frame
stack_top:

	.include "sdbench_time.inc"
	.include "sdbench_file.inc"
	; STORAGE_PROFILE: removable benchmark extensions.
	.include "sdbench_hit.inc"
	.include "sdbench_profile.inc"
	.include "zbdos.inc"
