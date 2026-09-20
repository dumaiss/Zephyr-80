; sdbench_file.inc — the two file-level read benchmarks.
;
; ---------------------------------------------------------------------------
; WHAT EACH ONE ACTUALLY MEASURES
; ---------------------------------------------------------------------------
;
; BDOS mode is the path an ordinary CP/M program takes, end to end:
;
;   BDOS 20 -> BIOS READ -> CMD_SD_READ_REC -> READY -> 128 bytes on the bulk
;   lane -> the controller's block cache -> the card
;
; The unit is one 128-byte CP/M record and there is no way to ask for more.
; CP/M 2.2's sequential read is one record per call, so four calls are four
; transactions, NOT one 512-byte transfer, and this program never labels them as
; one.  A buffer larger than 128 bytes changes nothing below the BDOS call; it
; only saves the caller its own copying, which is not what is being measured
; here.
;
; FS mode is the controller's FAT service on the /SHARED/ folder:
;
;   CMD_FS_READ(handle, offset, len) -> READY -> len bytes on the bulk lane
;
; That length is a real one.  The controller does a single f_read of exactly len
; bytes into its chunk buffer BEFORE it answers READY, and the bulk phase then
; carries that many bytes in one transfer.  128, 256 and 512 here are genuine
; transaction sizes and are reported as such.
;
; 1024 and above are not offered and cannot be: IOC_FS_CHUNK_MAX is 512 and the
; controller answers IOC_STATUS_FS_RANGE to anything larger.  A 1024-byte row
; would have to be four 256-byte transactions wearing a bigger label, which is
; the one thing this benchmark exists to avoid.
;
; ---------------------------------------------------------------------------
; THE TWO MODES DO NOT READ THE SAME FILE
; ---------------------------------------------------------------------------
;
; BDOS mode reads a file inside a CP/M volume; FS mode reads a file in /SHARED/
; on the FAT card.  Same card, same cache, different files.  The rows are
; comparable as transport measurements and are not two views of one file.
;
; ---------------------------------------------------------------------------
; THE CACHE IS IN THE MEASUREMENT, AND IT BELONGS THERE
; ---------------------------------------------------------------------------
;
; The controller keeps eight 512-byte slots in front of the card, LRU, and both
; paths above go through it -- FatFs shares it rather than keeping its own.  So
; in BDOS mode one record in four misses and reaches the card and three hit
; SRAM, which is why the latency histogram is bimodal and why the mean is a poor
; guide to what a streaming reader must survive.  That IS the application-visible
; path; it is not a distortion of it.
;
; What would be a distortion is re-reading something small enough to still be
; resident.  Eight slots is 4 KiB, so any file of a few hundred KiB read forward
; once cannot be served from it: by the time the end arrives the beginning is
; long evicted.  That is the whole methodology -- there is no host-side way to
; invalidate the controller's cache, and this program does not pretend to have
; one.  Use a large file.

BDOS_CONST	= 0x0b
BDOS_OPEN	= 0x0f
BDOS_CLOSE	= 0x10
BDOS_READ_SEQ	= 0x14
BDOS_DMA	= 0x1a
BDOS_FILESIZE	= 0x23
BDOS_CURDSK	= 0x19

FCB1		= 0x005c
TAIL		= 0x0080

CMD_FS_OPEN	= 0x22
RSP_FS_OPEN	= 0xa2
CMD_FS_READ	= 0x23
RSP_FS_READ	= 0xa3
CMD_FS_CLOSE	= 0x25
RSP_FS_CLOSE	= 0xa5
FS_MODE_READ	= 0x00

RECORD_SIZE	= 128

; /C re-reads one small window so that every transaction after the first lap is
; served from the controller's eight-slot cache and NEVER REACHES THE CARD.
;
; That is the one experiment the size sweep cannot do for itself.  A cost that
; rises linearly with the chunk fits "the link moves N bytes per second" and
; "the card delivers a 512-byte block every M milliseconds" equally well,
; because three of every four 128-byte reads hit the cache and the fourth pays
; for a whole block either way.  Pinning the data in cache removes the card from
; the measurement, and the two explanations stop agreeing:
;
;   /C about the same as /S   the link and the protocol are the bottleneck
;   /C much faster than /S    the card is
;
; 2 KiB is four blocks, comfortably inside the eight the controller keeps, with
; room for the FAT and directory sectors FatFs shares that cache with.
FS_CACHE_WINDOW	= 2048
FS_CACHE_TOTAL	= 65536
CONST_EVERY	= 1024		; records between console checks, outside timing

; The largest file these routines will measure.  Throughput is bytes * 1000 / ms
; and that product has to stay inside 32 bits.  A CP/M 2.2 file can reach 8 MiB,
; so this is a real limit and is checked rather than assumed.
MAX_BYTES_HI	= 0x40		; 4 MiB, tested against the high two bytes

; ===========================================================================
; BDOS sequential read
; ===========================================================================
bench_bdos:
	call fb_make_fcb
	ld de,#fb_fcb
	ld c,#BDOS_OPEN
	call BDOS
	inc a				; FFh -> 00h
	jp z,fb_no_file

	; The record count comes from the directory, not from reading to the end,
	; so a premature EOF below is detectable rather than simply "the file was
	; shorter than we thought".
	ld de,#fb_fcb
	ld c,#BDOS_FILESIZE
	call BDOS
	ld hl,(fb_fcb + 33)		; r0, r1
	ld (fb_records),hl
	ld a,(fb_fcb + 35)		; r2
	ld (fb_records + 2),a
	xor a
	ld (fb_records + 3),a

	; Function 35 is a directory operation and leaves the FCB's sequential
	; position wherever it pleases.  Build a clean one and open again rather
	; than reason about which fields survived.
	call fb_make_fcb
	ld de,#fb_fcb
	ld c,#BDOS_OPEN
	call BDOS

	; bytes = records * 128, and the answer has to fit the arithmetic.
	ld hl,#fb_records
	call n_load_acc
	call n_acc_is_zero
	jp z,fb_empty
	ld bc,#RECORD_SIZE
	call n_mul16
	ld hl,#fb_bytes
	call n_store_acc
	ld a,(fb_bytes + 3)
	or a
	jr nz,fb_too_big
	ld a,(fb_bytes + 2)
	cp #MAX_BYTES_HI
	jr c,fb_size_ok
fb_too_big:
	ld de,#msg_too_big
	call puts
	jp finish
fb_size_ok:
	call fb_say_file

	call tk_start
	or a
	jp nz,fb_no_timer
	call fb_say_timer

	call pass_reset
	ld de,#io_buf
	ld c,#BDOS_DMA
	call BDOS
	ld hl,#0
	ld (fb_done),hl
	ld (fb_done + 2),hl
	ld hl,#CONST_EVERY
	ld (fb_countdown),hl
	xor a
	ld (fb_sum),a
	ld (fb_abort),a
	ld de,#msg_reading
	call puts

fb_loop:
	call tk_read
	ld hl,#fb_t0
	call n_store_acc

	ld de,#fb_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	ld (fb_status),a

	call tk_read
	ld hl,#fb_t0
	call n_load_arg
	call n_sub

	ld a,(fb_status)
	or a
	jr nz,fb_ended			; a failed or EOF call is not a sample

	call pass_latency		; acc32 (ticks) -> HL, clamped
	call pass_sample

	; Prove the record actually landed in our buffer.  One byte per record is
	; too cheap to measure and is outside the timed window in any case; a
	; full checksum would cost about a tenth of a read and buy nothing, since
	; this benchmark measures transport and not the media.
	ld a,(io_buf)
	ld hl,#fb_sum
	add a,(hl)
	ld (hl),a

	ld hl,(fb_done)
	inc hl
	ld (fb_done),hl
	ld a,h
	or l
	jr nz,fb_no_carry
	ld hl,(fb_done + 2)
	inc hl
	ld (fb_done + 2),hl
fb_no_carry:
	ld hl,(fb_countdown)
	dec hl
	ld (fb_countdown),hl
	ld a,h
	or l
	jr nz,fb_loop
	ld hl,#CONST_EVERY
	ld (fb_countdown),hl
	; Console traffic is IOC traffic, so it is kept well away from the timed
	; window and rare enough not to matter to the card.
	ld c,#BDOS_CONST
	call BDOS
	or a
	jr z,fb_loop
	ld c,#BDOS_CONIN
	call BDOS
	ld a,#1
	ld (fb_abort),a
	jr fb_report

fb_ended:
	ld a,(fb_status)
	cp #1
	jr z,fb_report			; end of file, the ordinary way out
	ld de,#msg_read_err
	call puts
	ld a,(fb_status)
	call print_hex_byte
	call crlf

fb_report:
	call tk_stop
	ld de,#fb_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	call crlf

	ld a,(fb_abort)
	or a
	jr z,fb_check_count
	ld de,#msg_aborted
	call puts
	jr fb_print

	; Reading fewer records than the directory promised is the failure this
	; count exists to catch: it looks exactly like a fast run.
fb_check_count:
	ld hl,#fb_done
	call n_load_acc
	ld hl,#fb_records
	call n_load_arg
	call n_cmp
	jr z,fb_print
	ld de,#msg_short
	call puts
	ld hl,#fb_done
	call n_load_acc
	call print_dec32
	ld de,#msg_short_of
	call puts
	ld hl,#fb_records
	call n_load_acc
	call print_dec32
	call crlf

fb_print:
	; Report the bytes actually read, not the bytes the directory promised.
	ld hl,#fb_done
	call n_load_acc
	ld bc,#RECORD_SIZE
	call n_mul16
	ld hl,#p_bytes
	call n_store_acc
	ld de,#msg_bdos_head
	call puts
	call pass_report

	; The BIOS's 512-byte deblock line keeps a hit/miss tally in the IOC
	; failure record's reserved bytes -- common memory, because a transient
	; runs in latch mode 10 where bank 7 is not visible.  Thousands of reads
	; just happened, so this is the sample worth printing.
	;
	; Four consecutive CP/M records share one 512-byte block, so a clean
	; sequential pass should show misses at about a quarter of the reads.
	; Substantially more than that means something is defeating the line.
	call zb_diag_iy
	ld de,#msg_deblock
	call puts
	ld l,IOC_DIAG_RESERVED + 0(iy)
	ld h,IOC_DIAG_RESERVED + 1(iy)
	call n_acc_from_hl
	call print_dec32
	ld de,#msg_deblock_miss
	call puts
	ld l,IOC_DIAG_RESERVED + 2(iy)
	ld h,IOC_DIAG_RESERVED + 3(iy)
	call n_acc_from_hl
	call print_dec32
	call crlf
	jp finish

; A clean FCB from the one the CCP parsed: drive and name, everything else zero.
fb_make_fcb:
	ld hl,#FCB1
	ld de,#fb_fcb
	ld bc,#12
	ldir
	ld hl,#fb_fcb + 12
	ld b,#24
	xor a
fb_clear:
	ld (hl),a
	inc hl
	djnz fb_clear
	ret

fb_no_file:
	ld de,#msg_no_file
	call puts
	jp finish

fb_empty:
	ld de,#msg_empty
	call puts
	jp finish

; tk_start returns 1 or 2 when a channel is programmed but not counting.  A
; dead counter reads as a constant, which is indistinguishable from "no time
; passed" -- it would report an infinitely fast disk rather than a fault.
fb_no_timer:
	ld (fail_info),a
	ld de,#msg_no_timer
	call puts
	ld a,(fail_info)
	add a,#'0'
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	call crlf
	jp finish

; "File: B:TEST.DAT" then the size, from the FCB the CCP parsed.
fb_say_file:
	ld de,#msg_file
	call puts
	; Name the drive even when the command line did not.  Which drive this was
	; decides what the numbers mean -- A: may be the ROM volume on this build,
	; and measuring flash is not measuring an SD card -- so the report must
	; never leave it to be inferred from the prompt the user has since lost.
	ld a,(fb_fcb)
	or a
	jr nz,fb_drive_named
	ld c,#BDOS_CURDSK
	call BDOS
	inc a				; 0-based to the FCB's 1-based
fb_drive_named:
	add a,#'A' - 1
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ld e,#':'
	ld c,#BDOS_CONOUT
	call BDOS
fb_say_name:
	ld hl,#fb_fcb + 1
	ld b,#8
	call fb_say_field
	ld e,#'.'
	ld c,#BDOS_CONOUT
	call BDOS
	ld hl,#fb_fcb + 9
	ld b,#3
	call fb_say_field
	ld de,#msg_size
	call puts
	ld hl,#fb_bytes
	call n_load_acc
	call print_dec32
	ld de,#msg_size_recs
	call puts
	ld hl,#fb_records
	call n_load_acc
	call print_dec32
	ld de,#msg_size_tail
	call puts
	ret

; B characters from HL, trailing spaces dropped.  The name is 8.3 padded.
fb_say_field:
	push hl
	push bc
	ld a,(hl)
	and #0x7f			; the type bytes carry the attribute flags
	cp #' '
	jr z,fb_field_done
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	pop hl
	inc hl
	djnz fb_say_field
	ret
fb_field_done:
	pop bc
	pop hl
	ret

; The clock line, and the ceiling, printed with every run rather than left in
; the documentation: a reader who sees a maximum of 6.55 ms has to be able to
; tell a slow read from a saturated counter.
fb_say_timer:
	ld a,(no_timer)
	or a
	jr z,fb_timer_on
	ld de,#msg_timer_off
	jp puts
fb_timer_on:
	ld de,#msg_timer
	call puts
	; One tick is ctc_tc * 1.6 us, to two decimals, which is exact.
	ld a,(ctc_tc)
	ld l,a
	ld h,#0
	call n_acc_from_hl
	ld bc,#160
	call n_mul16
	call print_x100
	ld de,#msg_timer_us
	jp puts

; ===========================================================================
; IO Controller FS bulk read, /SHARED/<name>
; ===========================================================================
bench_fs:
	call fs_open
	or a
	jp nz,fs_failed

	ld hl,(rx_frame + 5)		; IOC_OFF_FS_OPEN_SIZE
	ld (fs_size),hl
	ld hl,(rx_frame + 7)
	ld (fs_size + 2),hl
	ld a,(rx_frame + 4)		; IOC_OFF_FS_OPEN_HANDLE
	ld (fs_handle),a

	ld hl,#fs_size
	call n_load_acc
	call n_acc_is_zero
	jp z,fs_empty
	ld a,(fs_size + 3)
	or a
	jr nz,fs_big
	ld a,(fs_size + 2)
	cp #MAX_BYTES_HI
	jr c,fs_size_ok
fs_big:
	ld de,#msg_too_big
	call puts
	call fs_close
	jp finish
	; A window that runs off the end of the file would read short and measure
	; nothing useful.
	ld a,(fs_cached)
	or a
	jp z,fs_size_ok
	ld hl,#fs_size
	call n_load_acc
	ld hl,#fs_cache_window
	call n_load_arg
	call n_cmp
	jr c,fs_too_small
	jr fs_size_ok
fs_too_small:
	ld de,#msg_too_small
	call puts
	call fs_close
	jp finish
fs_size_ok:
	call fs_say_file

	call tk_start
	or a
	jp nz,fs_no_timer
	call fb_say_timer

	; 128, 256 and 512 in turn.  One handle serves all three: FS_READ carries
	; its own offset, so a pass is a seek back to zero and nothing more.
	ld hl,#fs_sizes
	ld (fs_size_p),hl
	xor a
	ld (fs_row),a
fs_next_size:
	ld hl,(fs_size_p)
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	ld a,h
	or l
	jr z,fs_all_done
	ld (fs_chunk),hl
	call fs_one_pass
	or a
	jr nz,fs_pass_failed
	ld hl,(fs_size_p)
	inc hl
	inc hl
	ld (fs_size_p),hl
	ld a,(fs_row)
	inc a
	ld (fs_row),a
	jr fs_next_size

fs_all_done:
	call tk_stop
	call fs_close
	call fs_table
	jp finish

fs_pass_failed:
	call tk_stop
	call fs_close
	jp fs_failed

; One complete forward pass at (fs_chunk) bytes per transaction.
; Out: A = 0 on success.
fs_one_pass:
	call pass_reset
	ld a,(fs_cached)
	or a
	jr z,fs_whole_file
	ld hl,#fs_cache_total
	call n_load_acc
	jr fs_set_left
fs_whole_file:
	ld hl,#fs_size
	call n_load_acc
fs_set_left:
	ld hl,#fs_left
	call n_store_acc
	ld hl,#0
	ld (fs_off),hl
	ld (fs_off + 2),hl
	ld (fs_got),hl
	ld (fs_got + 2),hl
	xor a
	ld (fb_sum),a

	ld de,#msg_pass
	call puts
	ld hl,(fs_chunk)
	call print_dec_word
	ld de,#msg_pass_tail
	call puts
	ld a,(fs_cached)
	or a
	jr z,fs_head_done
	ld de,#msg_pass_cached
	call puts
fs_head_done:
	call crlf
	; STORAGE_PROFILE begin: outside transfer timing and console-free.
	call sp_begin
	or a
	ret nz

fs_pass_loop:
	ld hl,#fs_left
	call n_load_acc
	call n_acc_is_zero
	jp z,fs_pass_ok

	; len = min(chunk, left)
	ld hl,(fs_chunk)
	call n_acc_from_hl
	ld hl,#fs_left
	call n_load_arg
	call n_cmp			; carry = chunk < left
	jr c,fs_len_set
	ld hl,(fs_left)			; the tail is shorter than a chunk
	ld (fs_len),hl
	jr fs_len_done
fs_len_set:
	ld hl,(fs_chunk)
	ld (fs_len),hl
fs_len_done:

	call tk_read
	ld hl,#fb_t0
	call n_store_acc

	call fs_read_once

	push af
	call tk_read
	ld hl,#fb_t0
	call n_load_arg
	call n_sub
	pop af
	or a
	ret nz

	call pass_latency
	call pass_sample

	ld a,(ref_buf)
	ld hl,#fb_sum
	add a,(hl)
	ld (hl),a

	; offset += len, got += len, left -= len
	ld hl,(fs_len)
	ld (fs_len32),hl
	ld hl,#0
	ld (fs_len32 + 2),hl
	ld hl,#fs_off
	ld de,#fs_len32
	call n_add_to
	ld hl,#fs_got
	ld de,#fs_len32
	call n_add_to
	ld hl,#fs_left
	ld de,#fs_len32
	call n_sub_from

	; In cached mode the offset laps the window instead of walking the file,
	; so the same few blocks are asked for over and over.
	ld a,(fs_cached)
	or a
	jp z,fs_pass_loop
	ld hl,(fs_off)
	ld de,#FS_CACHE_WINDOW
	or a
	sbc hl,de
	jp c,fs_pass_loop
	ld hl,#0
	ld (fs_off),hl
	ld (fs_off + 2),hl
	jp fs_pass_loop

fs_pass_ok:
	; STORAGE_PROFILE end: snapshot before any reporting/console traffic.
	call sp_end
	or a
	ret nz
	ld hl,#fs_got
	call n_load_acc
	ld hl,#p_bytes
	call n_store_acc
	call pass_report
	call sp_report
	call fs_store_row
	xor a
	ret

; One CMD_FS_READ plus its bulk phase: the whole of what an application-visible
; bulk read costs.  Out: A = 0 on success.
fs_read_once:
	ld a,#0x50
	ld (fs_stage),a
	call zero_frames
	ld a,#CMD_FS_READ
	ld (tx_frame + 0),a
	ld a,#7				; handle + 32-bit offset + 16-bit length
	ld (tx_frame + 3),a
	ld a,(fs_handle)
	ld (tx_frame + 4),a
	ld hl,(fs_off)
	ld (tx_frame + 5),hl
	ld hl,(fs_off + 2)
	ld (tx_frame + 7),hl
	ld hl,(fs_len)
	ld (tx_frame + 9),hl
	ld a,#RSP_FS_READ
	call fs_xact
	or a				; set_failure does not set the flags
	ret nz

	; READY's length is the promise the bulk phase keeps.  A short one before
	; the end of the file is a premature EOF, and reading the promised length
	; instead of the requested one is what keeps the two in step.
	ld hl,(rx_frame + 6)		; IOC_OFF_READY_LEN
	ld a,h
	or l
	jr z,fs_short
	ld de,(fs_len)
	or a
	sbc hl,de
	jr z,fs_len_agreed
fs_short:
	ld a,(rx_frame + 6)		; how short it actually was
	ld (fail_info),a
	ld a,#0x32
	jp set_failure
fs_len_agreed:
	ld a,(rx_frame + 5)		; IOC_OFF_READY_DIRECTION, MCU -> Z80
	or a
	jr nz,fs_bad_dir

	ld hl,#ref_buf
	ld de,(fs_len)
	call IOCBULK
	or a
	ret z
	ld (fail_info),a
	ld a,#0x31
	jp set_failure

fs_bad_dir:
	ld (fail_info),a
	ld a,#0x33
	jp set_failure

fs_open:
	ld a,#0x40
	ld (fs_stage),a
	call zero_frames
	ld a,#CMD_FS_OPEN
	ld (tx_frame + 0),a
	ld a,#12			; mode + the packed 8.3 name
	ld (tx_frame + 3),a
	ld a,#FS_MODE_READ
	ld (tx_frame + 4),a
	; The CCP has already parsed the argument into FCB1, and that is byte for
	; byte the packed name the controller wants.  No parsing happens here.
	ld hl,#FCB1 + 1
	ld de,#tx_frame + 5
	ld bc,#11
	ldir
	ld a,#RSP_FS_OPEN
	jp fs_xact

fs_close:
	ld a,#0x60
	ld (fs_stage),a
	call zero_frames
	ld a,#CMD_FS_CLOSE
	ld (tx_frame + 0),a
	ld a,#5
	ld (tx_frame + 3),a
	ld a,(fs_handle)
	ld (tx_frame + 4),a
	; The size field only ever truncates, and only a handle opened for writing.
	; Zero is correct and inert for a read handle.
	ld a,#RSP_FS_CLOSE
	jp fs_xact

; One command transaction: send, check the class, check the status.
;
; In:  A = expected response class, fs_stage = the caller's stage base.
; Out: A = 0, or fail_stage/fail_info set.
;
; The stage base is per caller because the three FS commands fail for entirely
; different reasons and a shared code cannot say which one went quiet.  A
; transport failure on OPEN means the controller is not serving CMD_FS_* at all;
; the same failure on READ means the link broke mid-run.  Those need different
; answers, so they get different numbers: 41/42/43 open, 51/52/53 read,
; 61/62/63 close, in each case transport / wrong class / controller status.
fs_xact:
	ld (fs_exp),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr z,fs_xact_class
	ld (fail_info),a
	ld a,#1
	jp fs_xact_fail
fs_xact_class:
	ld a,(rx_frame + 0)
	ld hl,#fs_exp
	cp (hl)
	jr z,fs_xact_status
	ld (fail_info),a
	ld a,#2
	jp fs_xact_fail
fs_xact_status:
	ld a,(rx_frame + 2)
	or a
	ret z
	ld (fail_info),a
	ld a,#3
fs_xact_fail:
	ld hl,#fs_stage
	add a,(hl)
	jp set_failure

fs_say_file:
	ld de,#msg_shared
	call puts
	ld hl,#FCB1 + 1
	ld b,#8
	call fb_say_field
	ld e,#'.'
	ld c,#BDOS_CONOUT
	call BDOS
	ld hl,#FCB1 + 9
	ld b,#3
	call fb_say_field
	ld de,#msg_size
	call puts
	ld hl,#fs_size
	call n_load_acc
	call print_dec32
	ld de,#msg_size_bytes
	call puts
	ret

fs_empty:
	ld de,#msg_empty
	call puts
	call fs_close
	jp finish

fs_no_timer:
	push af
	call fs_close
	pop af
	jp fb_no_timer

fs_failed:
	ld de,#msg_fs_fail
	call puts
	ld a,(fail_stage)
	call print_hex_byte
	ld de,#msg_info
	call puts
	ld a,(fail_info)
	call print_hex_byte
	call crlf
	jp finish

; Keep this pass's headline figures for the summary table.
fs_store_row:
	ld a,(fs_row)
	ld l,a
	ld h,#0
	add hl,hl
	add hl,hl			; row * 4
	ld d,h
	ld e,l
	add hl,hl			; row * 8
	add hl,de			; row * 12
	ld de,#fs_rows
	add hl,de
	ld (fs_row_p),hl
	ld hl,#p_kib100
	call n_load_acc
	ld hl,(fs_row_p)
	call n_store_acc
	ld hl,#p_avg100
	call n_load_acc
	ld hl,(fs_row_p)
	ld de,#4
	add hl,de
	call n_store_acc
	ld hl,#p_max100
	call n_load_acc
	ld hl,(fs_row_p)
	ld de,#8
	add hl,de
	jp n_store_acc

fs_table:
	ld de,#msg_table_head
	call puts
	ld hl,#fs_rows
	ld (fs_size_p),hl
	ld hl,#fs_sizes
	ld (fs_row_p),hl
	ld b,#3
fs_table_loop:
	push bc
	ld de,#msg_table_lead
	call puts
	ld hl,(fs_row_p)
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	call n_acc_from_hl
	ld a,#4
	call print_dec32_pad
	ld de,#msg_table_b
	call puts
	ld hl,(fs_size_p)
	call n_load_acc
	ld a,#9
	call print_x100_pad
	ld de,#msg_table_kib
	call puts
	ld hl,(fs_size_p)
	ld de,#4
	add hl,de
	call n_load_acc
	ld a,#8
	call print_x100_pad
	ld de,#msg_table_ms
	call puts
	ld hl,(fs_size_p)
	ld de,#8
	add hl,de
	call n_load_acc
	ld a,#8
	call print_x100_pad
	ld de,#msg_table_ms
	call puts
	call crlf
	ld hl,(fs_size_p)
	ld de,#12
	add hl,de
	ld (fs_size_p),hl
	ld hl,(fs_row_p)
	inc hl
	inc hl
	ld (fs_row_p),hl
	pop bc
	djnz fs_table_loop
	ret

fs_sizes:
	.dw 128,256,512,0

; ===========================================================================
; Per-pass statistics
; ===========================================================================

; Zero the counters and compute the histogram edges for the TC in use.
pass_reset:
	xor a
	ld hl,#p_io_ticks
	ld b,#8
pass_zero:
	ld (hl),a
	inc hl
	djnz pass_zero
	ld hl,#p_hist
	ld b,#16
pass_zero_h:
	ld (hl),a
	inc hl
	djnz pass_zero_h
	xor a
	ld (p_bad),a
	ld hl,#0xffff
	ld (p_min),hl
	ld hl,#0
	ld (p_max),hl
	ld (p_reads),hl
	ld (p_reads + 2),hl

	; edge = round(ms * 1000 / (TC * 1.6)) = round(ms * 625 / TC), the tick
	; count that first reaches that many milliseconds at this tick rate.  A
	; coarse TC can collapse the lowest edges to zero, which empties the
	; buckets below it rather than mislabelling them.
	ld a,(ctc_tc)
	ld l,a
	ld h,#0
	ld (p_scale),hl
	ld hl,#pass_ms_table
	ld (p_edge_src),hl
	ld hl,#p_edge
	ld (p_edge_p),hl
	ld b,#7
pass_edge_loop:
	push bc
	ld hl,(p_edge_src)
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	call n_acc_from_hl
	ld bc,#625
	call n_mul16
	; + half the divisor, so the edge rounds instead of always truncating
	ld hl,(p_scale)
	srl h
	rr l
	ld (arg32),hl
	ld hl,#0
	ld (arg32 + 2),hl
	call n_add
	ld bc,(p_scale)
	call n_div16
	ld hl,(acc32)
	ld de,(p_edge_p)
	ex de,hl
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	ld (p_edge_p),hl
	ld hl,(p_edge_src)
	inc hl
	inc hl
	ld (p_edge_src),hl
	pop bc
	djnz pass_edge_loop
	ret

pass_ms_table:
	.dw 1,2,5,10,20,50,100

; acc32 holds a latency in ticks.  Out: HL = it.
;
; The remainder combine cannot produce more than 65279 steps -- its alias-free
; ceiling at any tick rate -- so a latency that needs more than 16 bits cannot
; be a real read: it is a sampling artifact.  Recording it as the largest
; representable value would poison the mean and the maximum together, so it is
; counted instead, and pass_report prints the count so a run that suffered any
; cannot be read as clean.
pass_latency:
	ld a,(acc32 + 2)
	ld hl,#acc32 + 3
	or (hl)
	jr nz,pass_lat_bad
	ld hl,(acc32)
	ret
pass_lat_bad:
	ld hl,#p_bad
	inc (hl)
	jr nz,pass_lat_zero
	dec (hl)			; saturate rather than wrap
pass_lat_zero:
	ld hl,#0
	ret

; HL = one latency in ticks.  Fold it into the totals and the histogram.
pass_sample:
	ld (p_lat),hl

	ld de,(p_min)
	or a
	sbc hl,de
	jr nc,pass_not_min
	ld hl,(p_lat)
	ld (p_min),hl
pass_not_min:
	ld hl,(p_lat)
	ld de,(p_max)
	or a
	sbc hl,de
	jr c,pass_not_max
	ld hl,(p_lat)
	ld (p_max),hl
pass_not_max:

	ld hl,(p_lat)
	ld de,#p_io_ticks
	call n_add_hl_to

	ld hl,(p_reads)
	inc hl
	ld (p_reads),hl
	ld a,h
	or l
	jr nz,pass_counted
	ld hl,(p_reads + 2)
	inc hl
	ld (p_reads + 2),hl
pass_counted:

	; The first edge the latency does not reach names its bucket; falling past
	; all seven of them means the last bucket.
	ld hl,#p_edge
	ld b,#7
	ld c,#0
pass_bucket:
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	push hl
	ld hl,(p_lat)
	or a
	sbc hl,de
	pop hl
	jr c,pass_bucket_found
	inc c
	djnz pass_bucket
pass_bucket_found:
	ld a,c
	add a,a
	ld l,a
	ld h,#0
	ld de,#p_hist
	add hl,de
	inc (hl)
	ret nz
	inc hl
	inc (hl)
	ret

; ---------------------------------------------------------------------------
; The report for one pass: three lines, in a form that survives being pasted
; into an issue.
;
;   bytes   524288  time  6248.32 ms   83915 B/s    81.94 KiB/s
;   reads     4096  min      0.99  avg     1.52  max    27.95 ms
;   ms <1:0 1-2:4021 2-5:61 5-10:9 10-20:3 20-50:2 50-100:2 >=100:0
;
; Every millisecond figure is an exact conversion of an integer tick count.
; ---------------------------------------------------------------------------
pass_report:
	ld hl,#p_io_ticks
	call n_load_acc
	call ms_from_ticks
	ld hl,#p_ms
	call n_store_acc

	; Average, minimum and maximum, all as milliseconds * 100.
	ld hl,#p_reads
	call n_load_div
	ld hl,#p_reads
	call n_load_acc
	call n_acc_is_zero
	jr nz,pass_avg_ok
	call n_zero_acc
	jr pass_avg_store
pass_avg_ok:
	ld hl,#p_io_ticks
	call n_load_acc
	call msx100_from_ticks
	call n_div32
pass_avg_store:
	ld hl,#p_avg100
	call n_store_acc

	ld hl,(p_reads)
	ld a,h
	or l
	jr nz,pass_have_min
	ld hl,#0
	ld (p_min),hl
pass_have_min:
	ld hl,(p_min)
	call n_acc_from_hl
	call msx100_from_ticks
	ld hl,#p_min100
	call n_store_acc
	ld hl,(p_max)
	call n_acc_from_hl
	call msx100_from_ticks
	ld hl,#p_max100
	call n_store_acc

	; Throughput.  Both figures come from the same bytes and the same
	; milliseconds, so they cannot disagree with each other.
	call pass_bytes_per_sec
	ld hl,#p_bps
	call n_store_acc
	call pass_kib_x100
	ld hl,#p_kib100
	call n_store_acc

	ld de,#msg_r_bytes
	call puts
	ld hl,#p_bytes
	call n_load_acc
	ld a,#8
	call print_dec32_pad
	ld de,#msg_r_time
	call puts
	ld hl,#p_io_ticks
	call n_load_acc
	call msx100_from_ticks
	ld a,#10
	call print_x100_pad
	ld de,#msg_r_ms_sp
	call puts
	ld hl,#p_bps
	call n_load_acc
	ld a,#7
	call print_dec32_pad
	ld de,#msg_r_bps
	call puts
	ld hl,#p_kib100
	call n_load_acc
	ld a,#9
	call print_x100_pad
	ld de,#msg_r_kib
	call puts

	ld de,#msg_r_reads
	call puts
	ld hl,#p_reads
	call n_load_acc
	ld a,#8
	call print_dec32_pad
	ld de,#msg_r_min
	call puts
	ld hl,#p_min100
	call n_load_acc
	ld a,#8
	call print_x100_pad
	ld de,#msg_r_avg
	call puts
	ld hl,#p_avg100
	call n_load_acc
	ld a,#8
	call print_x100_pad
	ld de,#msg_r_max
	call puts
	ld hl,#p_max100
	call n_load_acc
	ld a,#8
	call print_x100_pad
	ld de,#msg_r_ms
	call puts

	ld a,(p_bad)
	or a
	jr z,pass_no_bad
	ld de,#msg_r_bad
	call puts
	ld l,a
	ld h,#0
	call print_dec_word
	call crlf
pass_no_bad:
	ld de,#msg_r_hist
	call puts
	ld hl,#msg_hist_labels
	ld (p_edge_src),hl
	ld hl,#p_hist
	ld (p_edge_p),hl
	ld b,#8
pass_hist_loop:
	push bc
	ld hl,(p_edge_src)
	ex de,hl
	call puts
	ld hl,(p_edge_src)
pass_hist_skip:
	ld a,(hl)
	inc hl
	cp #'$'
	jr nz,pass_hist_skip
	ld (p_edge_src),hl
	ld hl,(p_edge_p)
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld (p_edge_p),hl
	ex de,hl
	call n_acc_from_hl
	call print_dec32
	call space
	pop bc
	djnz pass_hist_loop
	jp crlf

; acc32 = bytes per second = bytes * 1000 / milliseconds.
; The 4 MiB ceiling checked at entry is exactly what keeps that product inside
; 32 bits; a zero elapsed time means the run was shorter than one tick.
pass_bytes_per_sec:
	ld hl,#p_ms
	call n_load_acc
	call n_acc_is_zero
	jr z,pass_rate_none
	ld hl,#p_ms
	call n_load_div
	ld hl,#p_bytes
	call n_load_acc
	ld bc,#1000
	call n_mul16
	jp n_div32
pass_rate_none:
	jp n_zero_acc

; acc32 = KiB per second * 100 = (bytes * 25 / 256) * 1000 / milliseconds.
; Dividing by 256 before the thousand is what keeps this inside 32 bits for a
; file at the ceiling.
pass_kib_x100:
	ld hl,#p_ms
	call n_load_acc
	call n_acc_is_zero
	jr z,pass_rate_none
	ld hl,#p_ms
	call n_load_div
	ld hl,#p_bytes
	call n_load_acc
	ld bc,#25
	call n_mul16
	ld bc,#256
	call n_div16
	ld bc,#1000
	call n_mul16
	jp n_div32

p_io_ticks:	.ds 4
p_reads:	.ds 4
p_bytes:	.ds 4
p_min:		.ds 2
p_max:		.ds 2
p_hist:		.ds 16
p_edge:		.ds 14
p_edge_p:	.ds 2
p_edge_src:	.ds 2
p_scale:	.ds 2
p_ms:		.ds 4
p_kib100:	.ds 4
p_avg100:	.ds 4
p_max100:	.ds 4
p_min100:	.ds 4
p_bps:		.ds 4
p_lat:		.ds 2
p_bad:		.ds 1

fb_fcb:		.ds 36
fb_records:	.ds 4
fb_bytes:	.ds 4
fb_done:	.ds 4
fb_t0:		.ds 4
fb_countdown:	.ds 2
fb_status:	.ds 1
fb_abort:	.ds 1
fb_sum:		.ds 1

fs_size:	.ds 4
fs_off:		.ds 4
fs_left:	.ds 4
fs_got:		.ds 4
fs_len:		.ds 2
fs_len32:	.ds 4
fs_chunk:	.ds 2
fs_size_p:	.ds 2
fs_row_p:	.ds 2
fs_rows:	.ds 36
fs_handle:	.ds 1
fs_exp:		.ds 1
fs_stage:	.ds 1
fs_row:		.ds 1
fs_cached:	.ds 1
; Split into words by the assembler, not by hand.  FS_CACHE_TOTAL is 65536, and
; `.dw 65536` truncates to zero WITHOUT A DIAGNOSTIC -- which set the byte count
; to nothing and made the whole cached pass report zeros before its first read.
fs_cache_total:
		.dw (FS_CACHE_TOTAL & 0xffff)
		.dw (FS_CACHE_TOTAL >> 16)
fs_cache_window:
		.dw (FS_CACHE_WINDOW & 0xffff)
		.dw (FS_CACHE_WINDOW >> 16)
