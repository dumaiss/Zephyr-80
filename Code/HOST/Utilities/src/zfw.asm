; ZFW.COM -- Milestone 5, checkpoint 1: native writable file-content exercise.
;
; Drives the function-218 native file API (../../CPM2.2/src/cbios_fat_layout.asm)
; through the writable primitives the IO Controller gained in FS2 v1: create,
; open-for-update, write, sync, truncate and the error paths around them.  It
; deliberately does NOT test delete/rename/mkdir/rmdir; those primitives do not
; exist yet, which is also why the test file is left behind on purpose.
;
; Usage: select the FAT-backed drive, optionally ZCD into a subdirectory, then
; run ZFW.  Everything happens in the native current directory of that drive,
; in a file named ZFWTEST.TMP.  The file is rewritten on every run, so the
; program is safe to repeat and needs no cleanup step.
;
; The point of the checkpoint is the dangerous half of Milestone 5: Z80->MCU
; bulk write commit, short/oversized transfer rejection, writable-handle
; invalidation, handle-pool exhaustion, and ZSDOS software write protection.
; Every check reports its own status byte so a failure names one primitive.
;
; A FAIL line prints the ZN_ status byte verbatim (42 = exists, 44 = read-only,
; 48 = no handle, 4A = range, 4D = unknown write completion, ...), or one of
; this program's own codes: E1 = the call should have failed and did not,
; E2 = a size or transfer count was wrong, E3 = file content did not read back,
; E4 = an unexpected handle was issued.

	.module zfw
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
BDOS_WRITE_PROTECT = 28
BDOS_GET_RO = 29
BDOS_GET_FLAGS = 100		; ZSDOS Get Flags
BDOS_SET_FLAGS = 101		; ZSDOS Set Flags
ZSDOS_FLAG_RO_ENABLE = 0x04	; FLAGS bit 2, "Read-Only Enable"
BDOS_RESET_DISK = 13
BDOS_SELECT = 14
FAT_DRIVE_RO_BIT = 0x08		; D: in the ZSDOS read-only vector
BDOS_RESET_DRIVE = 37
FCB1 = 0x005c
FAT_FCB_DRIVE = 4			; D:, one-based as FCB1 stores it
FAT_DRIVE_BIT = 0x0008			; function 37 vector bit for D:

; This program's own failure codes, chosen above the ZN_ status range.
ERR_UNEXPECTED = 0xe1
ERR_VALUE      = 0xe2
ERR_DATA       = 0xe3
ERR_HANDLE     = 0xe4

CHUNK = 512				; FS2 v1 transfer ceiling

; Raw FS2 capability query, sent through IOCALL rather than function 218: the
; native API has no op that reports controller capabilities, and asking is the
; only way to tell a Milestone-5 controller from one that predates it.  The
; writable commands were added WITHOUT bumping IOC_FW_LEVEL, so the usual level
; check cannot see the difference -- and a controller that does not admit
; CMD_FS2_OPEN_RW drops the frame instead of refusing it.
CMD_FS2_CAPS = 0x30
RSP_FS2_CAPS = 0xb0
IOC_OFF_CMD = 0
IOC_OFF_STATUS = 2
IOC_OFF_LEN = 3
IOC_OFF_PAYLOAD = 4
IOC_FRAME_BYTES = 32
FS2_CAP_WRITE = 0x40			; in the low byte of the capability word

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call validate_drive
	jr z,check_controller
	ld de,#txt_drive
	jp finish_print
; Refusing here costs one frame and saves the alternative: issuing a write
; command the controller never admits, and waiting for a reply that is not
; coming.
check_controller:
	call check_caps
	or a
	jr z,run_tests
	cp #1
	jr nz,no_write_cap
	ld de,#txt_no_fs2
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(caps_status)
	call print_hex
	ld de,#txt_crlf
	jp finish_print
no_write_cap:
	ld de,#txt_no_write
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(caps_flags + 1)
	call print_hex
	ld a,(caps_flags)
	call print_hex
	ld de,#txt_crlf
	jp finish_print
run_tests:
	ld de,#txt_banner
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#test_table
	ld (tbl_ptr),hl
next_test:
	ld hl,(tbl_ptr)
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld a,e
	or d
	jp z,summary
	push hl
	ld c,#BDOS_PRINT
	call BDOS			; DE = padded test name
	pop hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld (tbl_ptr),hl
	ld (call_vec),de
	call do_call
	call report
	jr next_test

do_call:
	ld hl,(call_vec)
	jp (hl)

; A = 0 passes; anything else is the failure code to show.
report:
	or a
	jr nz,report_fail
	ld hl,#pass_count
	inc (hl)
	ld de,#txt_ok
	ld c,#BDOS_PRINT
	jp BDOS
report_fail:
	push af
	ld hl,#fail_count
	inc (hl)
	ld de,#txt_fail
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	push af
	call print_hex
	pop af
	; A bare code names the primitive but not the discrepancy.  A wrong count
	; and a wrong byte are different bugs, and which one it is decides where
	; to look next, so print what was actually seen.
	cp #ERR_VALUE
	jr z,report_value
	cp #ERR_DATA
	jr z,report_data
report_fail_end:
	ld de,#txt_crlf
	ld c,#BDOS_PRINT
	jp BDOS
report_value:
	ld de,#txt_got
	call print_str
	ld hl,(v_got)
	call print_hex16
	ld de,#txt_want
	call print_str
	ld hl,(v_want)
	call print_hex16
	jr report_fail_end
report_data:
	ld de,#txt_at
	call print_str
	ld hl,(v_got)
	call print_hex16
	ld de,#txt_got
	call print_str
	ld a,(v_gotb)
	call print_hex
	ld de,#txt_want
	call print_str
	ld a,(v_wantb)
	call print_hex
	jr report_fail_end

print_str:
	ld c,#BDOS_PRINT
	jp BDOS

print_hex16:
	ld a,h
	push hl
	call print_hex
	pop hl
	ld a,l
	jp print_hex

summary:
	ld de,#txt_passed
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(pass_count)
	call print_dec
	ld de,#txt_failed
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_count)
	call print_dec
	ld de,#txt_crlf
	ld a,(wp_stuck)
	or a
	jr z,finish_print
	ld de,#txt_wp_stuck
finish_print:
	ld c,#BDOS_PRINT
	call BDOS
	; ZCPR invokes transients with CALL 0100h.  Restore that entry stack and
	; return so ZCPR performs its normal post-program cleanup.
	ld sp,(entry_sp)
	ret

; The native service is specific to the FAT-backed drive.  Unlike ZCD there is
; no explicit-drive form: every operation here is relative to that drive's
; native current directory, so it must actually be the current drive.
validate_drive:
	ld c,#BDOS_GET_DRIVE
	call BDOS
	inc a				; BDOS is zero-based; FCB drives are one-based
	cp #FAT_FCB_DRIVE
	ret

; Out: A = 0 writable controller, 1 no usable CAPS reply, 2 no write support.
check_caps:
	ld hl,#tx_frame
	ld b,#IOC_FRAME_BYTES
	call zero_frame
	ld hl,#rx_frame
	ld b,#IOC_FRAME_BYTES
	call zero_frame
	ld a,#CMD_FS2_CAPS
	ld (tx_frame + IOC_OFF_CMD),a
	xor a
	ld (tx_frame + IOC_OFF_LEN),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	ld (caps_status),a
	or a
	jr nz,check_caps_link
	ld a,(rx_frame + IOC_OFF_CMD)
	cp #RSP_FS2_CAPS
	jr nz,check_caps_link
	ld a,(rx_frame + IOC_OFF_STATUS)
	ld (caps_status),a
	or a
	jr nz,check_caps_link
	ld hl,(rx_frame + IOC_OFF_PAYLOAD + 2)
	ld (caps_flags),hl
	ld a,l
	and #FS2_CAP_WRITE
	jr z,check_caps_read_only
	xor a
	ret
check_caps_link:
	ld a,#1
	ret
check_caps_read_only:
	ld a,#2
	ret

zero_frame:
	xor a
zero_frame_loop:
	ld (hl),a
	inc hl
	djnz zero_frame_loop
	ret

; ---------------------------------------------------------------------------
; Descriptor helpers.  zb_native clobbers BC, DE and HL, so every helper takes
; its arguments through scratch memory and reloads after the call.
; ---------------------------------------------------------------------------

op_begin:
	push bc
	ld hl,#desc
	ld b,#ZN_DESC_BYTES
	xor a
op_begin_loop:
	ld (hl),a
	inc hl
	djnz op_begin_loop
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	pop bc
	ret

; A = operation.  Out: A = ZN_STATUS, flags set from it.
do_op:
	ld (desc + ZN_OP),a
	ld de,#desc
	jp zb_native

set_name_test:
	push bc
	ld hl,#name_test
	ld de,#desc + ZN_NAME
	ld bc,#11
	ldir
	pop bc
	ret

; A = open mode.
open_mode:
	ld (t_handle),a
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_FLAGS),a
	call set_name_test
	ld a,#ZN_OPEN
	jp do_op

; A = handle.
close_handle:
	ld (t_handle),a
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_HANDLE),a
	ld a,#ZN_CLOSE
	jp do_op

; A = handle.
sync_op:
	ld (t_handle),a
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_HANDLE),a
	ld a,#ZN_SYNC
	jp do_op

; A = handle, HL = byte offset.
seek_to:
	ld (t_handle),a
	ld (t_pos),hl
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_HANDLE),a
	ld hl,(t_pos)
	ld (desc + ZN_POSITION),hl
	ld a,#ZN_SEEK
	jp do_op

; A = handle, HL = requested size.
truncate_to:
	ld (t_handle),a
	ld (t_pos),hl
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_HANDLE),a
	ld hl,(t_pos)
	ld (desc + ZN_POSITION),hl
	ld a,#ZN_TRUNCATE
	jp do_op

; A = handle, HL = buffer, BC = length.
write_op:
	ld (t_handle),a
	ld (t_buf),hl
	ld (t_len),bc
	ld a,#ZN_WRITE
	jr transfer_op
; A = handle, HL = buffer, BC = length.
read_op:
	ld (t_handle),a
	ld (t_buf),hl
	ld (t_len),bc
	ld a,#ZN_READ
transfer_op:
	ld (t_op),a
	call op_begin
	ld a,(t_handle)
	ld (desc + ZN_HANDLE),a
	ld hl,(t_buf)
	ld (desc + ZN_BUFFER),hl
	ld hl,(t_len)
	ld (desc + ZN_LENGTH),hl
	ld a,(t_op)
	jp do_op

; ---------------------------------------------------------------------------
; Checks.  Each returns A = 0 on success, or a failure code.
; ---------------------------------------------------------------------------

; HL and DE must match.
cmp_hl_de:
	ld (v_got),hl
	ld (v_want),de
	ld a,h
	cp d
	jr nz,cmp_hl_de_bad
	ld a,l
	cp e
	jr nz,cmp_hl_de_bad
	xor a
	ret
cmp_hl_de_bad:
	ld a,#ERR_VALUE
	or a
	ret

; ZN_RESULT must equal HL.
check_result:
	ex de,hl
	ld hl,(desc + ZN_RESULT)
	jr cmp_hl_de

; ZN_POSITION must equal HL, with a zero high half.
check_position:
	ex de,hl
	ld hl,(desc + ZN_POSITION + 2)
	ld a,h
	or l
	jr nz,cmp_hl_de_bad
	ld hl,(desc + ZN_POSITION)
	jr cmp_hl_de

; STAT the test file; its size must equal HL.
check_stat_size:
	ld (t_expect),hl
	call op_begin
	call set_name_test
	ld a,#ZN_STAT
	call do_op
	ret nz
	ld hl,(t_expect)
	jr check_position

; HL = expected, DE = actual, BC = length.
cmp_block:
	ld (v_len),bc
cmp_block_loop:
	ld a,(de)
	cp (hl)
	jr nz,cmp_block_bad
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,cmp_block_loop
	xor a
	ret
cmp_block_bad:
	ld a,(de)
	ld (v_gotb),a
	ld a,(hl)
	ld (v_wantb),a
	ld hl,(v_len)
	or a
	sbc hl,bc			; offset of the first differing byte
	ld (v_got),hl
	ld a,#ERR_DATA
	or a
	ret

; HL = destination, BC = count, A = non-zero seed.  A maximal-length 8-bit
; sequence, so a transfer served from the wrong offset does not still compare
; equal the way a counting pattern can.
fill_pattern:
	ld (hl),a
	inc hl
	add a,a
	jr nc,fill_pattern_next
	xor #0x1d
fill_pattern_next:
	dec bc
	ld d,a
	ld a,b
	or c
	ld a,d
	jr nz,fill_pattern
	ret

print_hex:
	push af
	rra
	rra
	rra
	rra
	call print_nibble
	pop af
print_nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

print_dec:
	ld b,#0
print_dec_tens:
	cp #10
	jr c,print_dec_out
	sub #10
	inc b
	jr print_dec_tens
print_dec_out:
	ld c,a
	ld a,b
	add a,#'0'
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	ld a,c
	add a,#'0'
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

; ---------------------------------------------------------------------------
; Tests, in execution order.
; ---------------------------------------------------------------------------

; Function 218 must exist before any result below means anything.  An
; unimplemented BDOS function returns A = 0; the real service rejects handle 0.
t_api:
	call op_begin
	ld a,#ZN_TELL
	call do_op
	cp #ZN_ERR_NO_HANDLE
	jr z,t_api_ok
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_api_ok:
	xor a
	ret

; First ever run creates the file; later runs find it.  Either outcome leaves
; ZFWTEST.TMP existing, which is what every later test assumes.
t_create_new:
	ld a,#ZN_OPEN_CREATE_NEW
	call open_mode
	jr z,t_create_new_fresh
	cp #ZN_ERR_EXISTS
	ret nz
	xor a
	ret
t_create_new_fresh:
	ld a,(desc + ZN_HANDLE)
	jp close_handle

t_create_dup:
	ld a,#ZN_OPEN_CREATE_NEW
	call open_mode
	jr nz,t_create_dup_check
	ld a,(desc + ZN_HANDLE)
	call close_handle
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_create_dup_check:
	cp #ZN_ERR_EXISTS
	ret nz
	xor a
	ret

; CREATE_ALWAYS must hand back a zero-length file whatever the previous run
; left behind, so the rest of the run starts from a known size.
t_create_always:
	ld a,#ZN_OPEN_CREATE_ALWAYS
	call open_mode
	ret nz
	ld a,(desc + ZN_HANDLE)
	ld (h_main),a
	or a
	jr z,t_create_always_handle
	cp #3
	jr nc,t_create_always_handle
	ld hl,#0
	jp check_position
t_create_always_handle:
	ld a,#ERR_HANDLE
	or a
	ret

; A short write: smaller than the 512-byte staging buffer and not a multiple
; of any block size.
t_write_100:
	ld hl,#srcbuf
	ld bc,#100
	ld a,#0x01
	call fill_pattern
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#100
	call write_op
	ret nz
	ld hl,#100
	jp check_result

; The host tracks the file position itself and sends it as an explicit offset.
; If its idea of the position is wrong, every later read asks for the wrong
; place, so confirm it before trusting any read result.
t_tell_100:
	ld a,(h_main)
	call op_begin
	ld (desc + ZN_HANDLE),a
	ld a,#ZN_TELL
	call do_op
	ret nz
	ld hl,#100
	jp check_position

t_sync:
	ld a,(h_main)
	jp sync_op

t_stat_100:
	ld hl,#100
	jp check_stat_size

; Run twice from the test table: once before any STAT has been issued, and
; once after.  STAT opens a SECOND controller handle on a file this program
; already holds open for writing, and FF_FS_LOCK is 0 on the controller, so
; FatFs does nothing to prevent that.  Two runs of one check say whether a
; read is broken by itself or only once a duplicate open has happened.
t_read_100:
	ld a,(h_main)
	ld hl,#0
	call seek_to
	ret nz
	ld a,(h_main)
	ld hl,#dstbuf
	ld bc,#100
	call read_op
	ret nz
	ld hl,#100
	call check_result
	ret nz
	ld hl,#srcbuf
	ld bc,#100
	ld a,#0x01
	call fill_pattern
	ld hl,#srcbuf
	ld de,#dstbuf
	ld bc,#100
	jp cmp_block

; Exactly the FS2 chunk ceiling, from offset zero.
t_write_512:
	ld hl,#srcbuf
	ld bc,#CHUNK
	ld a,#0x01
	call fill_pattern
	ld a,(h_main)
	ld hl,#0
	call seek_to
	ret nz
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#CHUNK
	call write_op
	ret nz
	ld hl,#CHUNK
	jp check_result

; A second full chunk, from the position the first write left behind: this is
; the multi-transfer commit path, not a single oversized request.
t_write_1024:
	ld hl,#srcbuf
	ld bc,#CHUNK
	ld a,#0x8d
	call fill_pattern
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#CHUNK
	call write_op
	ret nz
	ld hl,#CHUNK
	jp check_result

t_stat_1024:
	ld a,(h_main)
	call sync_op
	ret nz
	ld hl,#1024
	jp check_stat_size

t_read_1024:
	ld a,(h_main)
	ld hl,#0
	call seek_to
	ret nz
	ld a,#0x01
	call read_chunk_verify
	ret nz
	ld a,#0x8d
read_chunk_verify:
	ld (t_seed),a
	ld a,(h_main)
	ld hl,#dstbuf
	ld bc,#CHUNK
	call read_op
	ret nz
	ld hl,#CHUNK
	call check_result
	ret nz
	ld hl,#srcbuf
	ld bc,#CHUNK
	ld a,(t_seed)
	call fill_pattern
	ld hl,#srcbuf
	ld de,#dstbuf
	ld bc,#CHUNK
	jp cmp_block

; Overwrite in place across the 512-byte boundary the two writes created.
t_overwrite:
	ld hl,#srcbuf
	ld bc,#24
	ld a,#0x5a
	call fill_pattern
	ld a,(h_main)
	ld hl,#500
	call seek_to
	ret nz
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#24
	call write_op
	ret nz
	ld hl,#24
	call check_result
	ret nz
	ld a,(h_main)
	ld hl,#500
	call seek_to
	ret nz
	ld a,(h_main)
	ld hl,#dstbuf
	ld bc,#24
	call read_op
	ret nz
	ld hl,#24
	call check_result
	ret nz
	ld hl,#srcbuf
	ld bc,#24
	ld a,#0x5a
	call fill_pattern
	ld hl,#srcbuf
	ld de,#dstbuf
	ld bc,#24
	jp cmp_block

t_truncate_256:
	ld a,(h_main)
	ld hl,#256
	call truncate_to
	ret nz
	ld a,(h_main)
	call sync_op
	ret nz
	ld hl,#256
	jp check_stat_size

; Truncate is also the extend path: seeking past the end of a writable file
; allocates, so the size must grow rather than stay at 256.
t_extend_2048:
	ld a,(h_main)
	ld hl,#2048
	call truncate_to
	ret nz
	ld a,(h_main)
	call sync_op
	ret nz
	ld hl,#2048
	jp check_stat_size

t_write_zero:
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#0
	call write_op
	jr nz,t_write_zero_check
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_write_zero_check:
	cp #ZN_ERR_RANGE
	ret nz
	xor a
	ret

; One byte over the staging buffer must be refused, not truncated silently.
t_write_over:
	ld a,(h_main)
	ld hl,#srcbuf
	ld bc,#(CHUNK + 1)
	call write_op
	jr nz,t_write_over_check
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_write_over_check:
	cp #ZN_ERR_RANGE
	ret nz
	xor a
	ret

t_bad_handle:
	ld a,#3
	ld hl,#srcbuf
	ld bc,#16
	call write_op
	jr nz,t_bad_handle_check
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_bad_handle_check:
	cp #ZN_ERR_NO_HANDLE
	ret nz
	xor a
	ret

; A handle opened read-only must refuse a write even though the drive is
; writable and the file was created by this same program.
t_ro_write:
	ld a,(h_main)
	call close_handle
	ret nz
	ld a,#ZN_OPEN_READ
	call open_mode
	ret nz
	ld a,(desc + ZN_HANDLE)
	ld (h_ro),a
	ld hl,#srcbuf
	ld bc,#16
	ld a,(h_ro)
	call write_op
	jr nz,t_ro_write_check
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_ro_write_check:
	cp #ZN_ERR_READ_ONLY
	ret nz
	xor a
	ret

; Every other read in this program runs on a handle opened for writing.  This
; one does not, and it is the only check that separates "native READ is broken"
; from "native READ is broken on a write-mode handle".  Bytes 0-99 still hold
; the seed-01 pattern from the 512-byte write: the truncate to 256 kept them.
t_read_ro:
	ld a,(h_ro)
	ld hl,#0
	call seek_to
	ret nz
	ld a,(h_ro)
	ld hl,#dstbuf
	ld bc,#100
	call read_op
	ret nz
	ld hl,#100
	call check_result
	ret nz
	ld hl,#srcbuf
	ld bc,#100
	ld a,#0x01
	call fill_pattern
	ld hl,#srcbuf
	ld de,#dstbuf
	ld bc,#100
	jp cmp_block

; Two slots exist.  The third open must be refused cleanly rather than
; evicting or corrupting one of the live handles.
t_exhaust:
	ld a,#ZN_OPEN_READ
	call open_mode
	ret nz
	ld a,(desc + ZN_HANDLE)
	ld (h_ro2),a
	ld a,#ZN_OPEN_READ
	call open_mode
	jr nz,t_exhaust_check
	ld a,(desc + ZN_HANDLE)
	call close_handle
	ld a,#ERR_UNEXPECTED
	or a
	jr t_exhaust_release
t_exhaust_check:
	cp #ZN_ERR_NO_HANDLE
	jr z,t_exhaust_ok
	jr t_exhaust_release
t_exhaust_ok:
	xor a
t_exhaust_release:
	push af
	ld a,(h_ro2)
	call close_handle
	pop af
	ret

t_close:
	ld a,(h_ro)
	jp close_handle

; Out: HL = the ZSDOS software read-only vector, recorded for reporting.
ro_vector:
	ld c,#BDOS_GET_RO
	call BDOS
	ld (v_got),hl
	ret

; A = 0 when ZSDOS itself says D: is protected.
check_ro_set:
	call ro_vector
	push hl
	ld hl,#FAT_DRIVE_RO_BIT
	ld (v_want),hl
	pop hl
	ld a,l
	and #FAT_DRIVE_RO_BIT
	jr z,check_ro_set_bad
	xor a				; AND leaves the bit in A; 0 is the pass code
	ret
check_ro_set_bad:
	ld a,#ERR_VALUE
	or a
	ret

; A = 0 when ZSDOS itself says D: is writable again.
check_ro_clear:
	call ro_vector
	push hl
	ld hl,#0
	ld (v_want),hl
	pop hl
	ld a,l
	and #FAT_DRIVE_RO_BIT
	ret z
	ld a,#ERR_VALUE
	or a
	ret

; Does ZSDOS agree that the drive is protected?  This separates "the backend
; is refusing correctly" from "the backend's mirror of the vector is stale",
; which look identical from a rejected write.
t_wp_vector:
	jp check_ro_set

; Clearing it again needs one ZSDOS detail.  Its FLAGS bit 2, "Read-Only
; Enable", is set in this build (zsdos.lib: FLGBITS = 01101101B), and CMND37
; -- which serves BOTH function 13 and function 37 -- tests that bit and skips
; the DSKWP clear entirely when it is set:
;
;	LD	A,(FLAGS)
;	BIT	2,A		; Test hard R/O enabled
;	JR	NZ,UNWPT1	; If enabled
;	LD	HL,DSKWP	; Get drive W/P vector
;	CALL	ANDDEM		; Reset W/P stat only of requested drvs
;
; So neither reset function clears software write protection here, and neither
; does a warm boot.  That is ZSDOS working as configured, not a fault.  Drop
; the bit just long enough for function 37 to do its job, then put the user's
; configuration back exactly as it was.
t_wp_clear:
	ld c,#BDOS_GET_FLAGS
	call BDOS
	ld (saved_flags),a
	and #(~ZSDOS_FLAG_RO_ENABLE & 0xff)
	ld e,a
	ld c,#BDOS_SET_FLAGS
	call BDOS
	ld de,#FAT_DRIVE_BIT
	ld c,#BDOS_RESET_DRIVE
	call BDOS
	ld a,(saved_flags)
	ld e,a
	ld c,#BDOS_SET_FLAGS
	call BDOS
	jp check_ro_clear

; ZSDOS software write protection is an OS-level concept the FAT backend has
; to honour on its own, because these writes never reach ZSDOS.  Function 28
; also resets FAT context, so this runs last, with no handle open.
t_write_protect:
	ld c,#BDOS_WRITE_PROTECT
	call BDOS
	ld a,#ZN_OPEN_CREATE_ALWAYS
	call open_mode
	jr nz,t_wp_check
	ld a,(desc + ZN_HANDLE)
	call close_handle
	ld a,#ERR_UNEXPECTED
	ret
t_wp_check:
	cp #ZN_ERR_READ_ONLY
	ret nz
	xor a
	ret

; Proves the release above actually worked: if it did not, every later write in
; this session would fail for a reason that has nothing to do with the write.
t_wp_cleared:
	ld a,#ZN_OPEN_CREATE_ALWAYS
	call open_mode
	jr z,t_wp_cleared_ok
	push af
	ld a,#1
	ld (wp_stuck),a
	pop af
	ret
t_wp_cleared_ok:
	ld a,(desc + ZN_HANDLE)
	jp close_handle

; ---------------------------------------------------------------------------

test_table:
	.dw n_api,           t_api
	.dw n_create_new,    t_create_new
	.dw n_create_dup,    t_create_dup
	.dw n_create_always, t_create_always
	.dw n_write_100,     t_write_100
	.dw n_tell_100,      t_tell_100
	.dw n_read_early,    t_read_100
	.dw n_sync,          t_sync
	.dw n_stat_100,      t_stat_100
	.dw n_read_100,      t_read_100
	.dw n_write_512,     t_write_512
	.dw n_write_1024,    t_write_1024
	.dw n_stat_1024,     t_stat_1024
	.dw n_read_1024,     t_read_1024
	.dw n_overwrite,     t_overwrite
	.dw n_truncate_256,  t_truncate_256
	.dw n_extend_2048,   t_extend_2048
	.dw n_write_zero,    t_write_zero
	.dw n_write_over,    t_write_over
	.dw n_bad_handle,    t_bad_handle
	.dw n_ro_write,      t_ro_write
	.dw n_read_ro,       t_read_ro
	.dw n_exhaust,       t_exhaust
	.dw n_close,         t_close
	.dw n_write_protect, t_write_protect
	.dw n_wp_vector,     t_wp_vector
	.dw n_wp_clear,      t_wp_clear
	.dw n_wp_cleared,    t_wp_cleared
	.dw 0,               0

n_api:           .ascii "native api        $"
n_create_new:    .ascii "create new        $"
n_create_dup:    .ascii "create new twice  $"
n_create_always: .ascii "create always     $"
n_write_100:     .ascii "write 100         $"
n_tell_100:      .ascii "tell after write  $"
n_read_early:    .ascii "read back (nostat)$"
n_sync:          .ascii "sync              $"
n_stat_100:      .ascii "stat 100          $"
n_read_100:      .ascii "read back 100     $"
n_write_512:     .ascii "write 512         $"
n_write_1024:    .ascii "write 512 again   $"
n_stat_1024:     .ascii "stat 1024         $"
n_read_1024:     .ascii "read back 1024    $"
n_overwrite:     .ascii "overwrite at 500  $"
n_truncate_256:  .ascii "truncate to 256   $"
n_extend_2048:   .ascii "extend to 2048    $"
n_write_zero:    .ascii "write length 0    $"
n_write_over:    .ascii "write length 513  $"
n_bad_handle:    .ascii "write bad handle  $"
n_ro_write:      .ascii "write ro handle   $"
n_read_ro:       .ascii "read ro handle    $"
n_exhaust:       .ascii "handle exhaustion $"
n_close:         .ascii "close             $"
n_write_protect: .ascii "write protected   $"
n_wp_vector:     .ascii "zsdos ro vector   $"
n_wp_clear:      .ascii "clear protection  $"
n_wp_cleared:    .ascii "protection clear  $"

txt_banner:   .ascii "ZFW: native writable file tests on ZFWTEST.TMP\r\n$"
txt_ok:       .ascii "ok\r\n$"
txt_fail:     .ascii "FAIL $"
txt_got:      .ascii " got=$"
txt_want:     .ascii " want=$"
txt_at:       .ascii " at=$"
txt_passed:   .ascii "passed $"
txt_failed:   .ascii "  failed $"
txt_crlf:     .ascii "\r\n$"
txt_drive:    .ascii "ZFW must run on the FAT-backed drive\r\n$"
txt_no_fs2:   .ascii "No FS2 capability reply from the controller: $"
txt_no_write: .ascii "Controller firmware has no FS2 write support; reflash it. caps=$"
txt_wp_stuck: .ascii "\r\nWARNING: D: left write protected. Warm boot does NOT clear\r\nthis; power cycle to recover.\r\n$"

name_test:    .ascii "ZFWTEST TMP"

entry_sp:   .dw 0
tbl_ptr:    .dw 0
call_vec:   .dw 0
t_buf:      .dw 0
t_len:      .dw 0
t_pos:      .dw 0
t_expect:   .dw 0
t_handle:   .db 0
t_op:       .db 0
t_seed:     .db 0
h_main:     .db 0
h_ro:       .db 0
h_ro2:      .db 0
pass_count: .db 0
fail_count: .db 0
wp_stuck:   .db 0
caps_flags: .dw 0
saved_flags: .db 0
v_got:      .dw 0
v_want:     .dw 0
v_len:      .dw 0
v_gotb:     .db 0
v_wantb:    .db 0
caps_status: .db 0
desc:       .ds 32
tx_frame:   .ds IOC_FRAME_BYTES
rx_frame:   .ds IOC_FRAME_BYTES
srcbuf:     .ds CHUNK
dstbuf:     .ds CHUNK
	.ds 128
stack_top:

	.include "zbdos.inc"
