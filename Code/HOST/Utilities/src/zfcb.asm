; ZFCB.COM -- Milestone 6: the writable CP/M FCB personality on a FAT drive.
;
; ZFW exercises the native byte-oriented API (function 218).  This exercises
; the other half of the same files: ordinary CP/M BDOS/FCB calls, the ones an
; unmodified CP/M program makes.  It uses nothing Zephyr-specific, so it is
; also a fair regression test on a conventional drive -- run it on B: and every
; check must pass there too.
;
; Usage: select the drive and run ZFCB.  It works on ZFCBTST.TMP, ZFCBTS2.TMP
; and ZFCBTS3.TMP in the current drive and USER, and deletes all three before
; it finishes.
;
; `ZFCB WP` additionally tests software write protection.  That is off by
; default because the two drive types answer a protected write differently: the
; FAT personality intercepts above ZSDOS and returns a failure code, while a
; conventional drive reaches ZSDOS and raises its own "Bdos Err ... R/O", which
; takes the console and ends the run.  Running the default set on a
; conventional drive is the point -- every check there must pass too, and a
; failure that appears only on the FAT drive is a FAT bug.
;
; A FAIL line prints the BDOS result byte, or one of this program's own codes:
; E1 = the call should have failed and did not, E2 = a size or record count was
; wrong, E3 = data did not read back, E4 = an unexpected FCB field.

	.module zfcb
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_OPEN = 15
BDOS_CLOSE = 16
BDOS_DELETE = 19
BDOS_READ_SEQ = 20
BDOS_WRITE_SEQ = 21
BDOS_MAKE = 22
BDOS_RENAME = 23
BDOS_GET_DRIVE = 25
BDOS_SETDMA = 26
BDOS_WRITE_PROTECT = 28
BDOS_GET_RO = 29
BDOS_READ_RANDOM = 33
BDOS_WRITE_RANDOM = 34
BDOS_FILE_SIZE = 35
BDOS_WRITE_RANDOM_ZF = 40
BDOS_RESET_DRIVE = 37
BDOS_GET_FLAGS = 100
BDOS_SET_FLAGS = 101
ZSDOS_FLAG_RO_ENABLE = 0x04

ERR_UNEXPECTED = 0xe1
ERR_VALUE      = 0xe2
ERR_DATA       = 0xe3
ERR_FIELD      = 0xe4

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	; Every record moves through this buffer.
	ld de,#recbuf
	ld c,#BDOS_SETDMA
	call BDOS
	; The drive under test is whichever one is current, so the same binary
	; checks a FAT drive and a conventional one.
	ld c,#BDOS_GET_DRIVE
	call BDOS
	add a,#'A'
	ld (txt_drive_letter),a
	; Any argument at all selects the write-protect set.
	ld a,(0x0080)
	or a
	jr z,start_tables
	ld a,#1
	ld (wp_enabled),a
start_tables:
	ld de,#txt_banner
	call print
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
	jr nz,next_test_run
	; End of a table: continue into the optional set if it was asked for.
	ld a,(wp_enabled)
	or a
	jp z,summary
	xor a
	ld (wp_enabled),a
	ld hl,#wp_table
	ld (tbl_ptr),hl
	jr next_test
next_test_run:
	push hl
	call print
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

report:
	or a
	jr nz,report_fail
	ld hl,#pass_count
	inc (hl)
	ld de,#txt_ok
	jp print
report_fail:
	push af
	ld hl,#fail_count
	inc (hl)
	ld de,#txt_fail
	call print
	pop af
	push af
	call print_hex
	pop af
	cp #ERR_VALUE
	jr z,report_value
report_end:
	ld de,#txt_crlf
	jp print
report_value:
	ld de,#txt_got
	call print
	ld hl,(v_got)
	call print_hex16
	ld de,#txt_want
	call print
	ld hl,(v_want)
	call print_hex16
	jr report_end

summary:
	ld de,#txt_passed
	call print
	ld a,(pass_count)
	call print_dec
	ld de,#txt_failed
	call print
	ld a,(fail_count)
	call print_dec
	ld de,#txt_crlf
	call print
	ld a,(wp_stuck)
	or a
	jr z,finish
	ld de,#txt_wp_stuck
	call print
finish:
	ld sp,(entry_sp)
	ret

print:
	ld c,#BDOS_PRINT
	jp BDOS

; ---------------------------------------------------------------------------
; FCB helpers.  The FCB is the caller's, exactly as an ordinary program keeps
; it, so a bug that corrupts it shows up here as it would in real software.
; ---------------------------------------------------------------------------

; HL = 11-byte packed name.  Clears the FCB and installs it on the current
; drive (byte 0 = 0), leaving every position field at zero.
set_fcb:
	push hl
	ld hl,#fcb
	ld b,#36
	xor a
clear_fcb:
	ld (hl),a
	inc hl
	djnz clear_fcb
	pop hl
	ld de,#fcb + 1
	ld bc,#11
	ldir
	ret

; A = BDOS function on the FCB.  Out: A = result, flags from it.
fcb_call:
	ld c,a
	ld de,#fcb
	call BDOS
	or a
	ret

; Open, close, make and delete return 0-3 on success and FFh on failure, so a
; bare "or a" would reject a perfectly good directory code.
dir_result:
	cp #4
	ret nc
	xor a
	ret

; A = seed, HL = destination, BC = count.  Maximal-length 8-bit sequence, so a
; record served from the wrong offset does not still compare equal.
fill_pattern:
	ld (hl),a
	inc hl
	add a,a
	jr nc,fill_next
	xor #0x1d
fill_next:
	dec bc
	ld d,a
	ld a,b
	or c
	ld a,d
	jr nz,fill_pattern
	ret

; HL = expected, DE = actual, BC = count.
cmp_block:
	ld a,(de)
	cp (hl)
	jr nz,cmp_bad
	inc hl
	inc de
	dec bc
	ld a,b
	or c
	jr nz,cmp_block
	xor a
	ret
cmp_bad:
	ld a,#ERR_DATA
	or a
	ret

; HL and DE must match; both are recorded so a failure prints them.
cmp_hl_de:
	ld (v_got),hl
	ld (v_want),de
	ld a,h
	cp d
	jr nz,cmp_hl_de_bad
	ld a,l
	cp e
	jr nz,cmp_hl_de_bad
	xor a				; CP leaves the compared value in A; 0 passes
	ret
cmp_hl_de_bad:
	ld a,#ERR_VALUE
	or a
	ret

print_hex16:
	ld a,h
	push hl
	call print_hex
	pop hl
	ld a,l
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
dec_tens:
	cp #10
	jr c,dec_out
	sub #10
	inc b
	jr dec_tens
dec_out:
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
; Tests
; ---------------------------------------------------------------------------

; A leftover file from an interrupted run would make MAKE's result ambiguous.
t_clean:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_DELETE
	call fcb_call
	ld hl,#name_test2
	call set_fcb
	ld a,#BDOS_DELETE
	call fcb_call
	xor a
	ret

t_make:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_MAKE
	call fcb_call
	call dir_result
	ret nz
	; A new file is empty, so the position fields must start at zero or the
	; first sequential write lands in the wrong place.
	ld a,(fcb + 12)			; EX
	or a
	jr nz,t_make_field
	ld a,(fcb + 15)			; RC
	or a
	jr nz,t_make_field
	ld a,(fcb + 32)			; CR
	or a
	jr nz,t_make_field
	xor a
	ret
t_make_field:
	ld a,#ERR_FIELD
	or a
	ret

; Three sequential records, each a different pattern.
t_write_seq:
	ld b,#0
t_write_seq_loop:
	push bc
	ld a,b
	add a,#1			; seeds 1, 2, 3
	ld hl,#recbuf
	ld bc,#128
	call fill_pattern
	ld a,#BDOS_WRITE_SEQ
	call fcb_call
	pop bc
	ret nz
	inc b
	ld a,b
	cp #3
	jr c,t_write_seq_loop
	xor a
	ret

t_close:
	ld a,#BDOS_CLOSE
	call fcb_call
	jp dir_result

t_open:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_OPEN
	call fcb_call
	jp dir_result

; Read the same three records back and compare byte for byte.
t_read_seq:
	ld b,#0
t_read_seq_loop:
	push bc
	ld a,#BDOS_READ_SEQ
	call fcb_call
	jr nz,t_read_seq_fail
	pop bc
	push bc
	ld a,b
	add a,#1
	ld hl,#cmpbuf
	ld bc,#128
	call fill_pattern
	ld hl,#cmpbuf
	ld de,#recbuf
	ld bc,#128
	call cmp_block
	jr nz,t_read_seq_fail
	pop bc
	inc b
	ld a,b
	cp #3
	jr c,t_read_seq_loop
	xor a
	ret
t_read_seq_fail:
	pop bc
	ret

; Function 35 reports the size in records, which is how a CP/M program learns
; how long the file is.
t_file_size:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_FILE_SIZE
	call fcb_call
	ld hl,(fcb + 33)
	ld a,(fcb + 35)
	or a
	jr nz,t_file_size_bad
	ld de,#3
	jp cmp_hl_de
t_file_size_bad:
	ld a,#ERR_VALUE
	or a
	ret

; Random write to record 5, past the current end, then read it back.
t_write_random:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_OPEN
	call fcb_call
	call dir_result
	ret nz
	ld a,#0x7e
	ld hl,#recbuf
	ld bc,#128
	call fill_pattern
	ld a,#5
	ld (fcb + 33),a
	xor a
	ld (fcb + 34),a
	ld (fcb + 35),a
	ld a,#BDOS_WRITE_RANDOM
	call fcb_call
	ret nz
	ld a,#5
	ld (fcb + 33),a
	ld a,#BDOS_READ_RANDOM
	call fcb_call
	ret nz
	ld a,#0x7e
	ld hl,#cmpbuf
	ld bc,#128
	call fill_pattern
	ld hl,#cmpbuf
	ld de,#recbuf
	ld bc,#128
	call cmp_block
	ret nz
	; CP/M records the new length in the directory at CLOSE, not at write.
	; Without this the file still measures three records afterwards.
	ld a,#BDOS_CLOSE
	call fcb_call
	jp dir_result

; Function 40 guarantees a skipped gap reads back as zeros; that guarantee is
; the only thing separating it from function 34.
t_zero_fill:
	ld hl,#name_test2
	call set_fcb
	ld a,#BDOS_MAKE
	call fcb_call
	call dir_result
	ret nz
	ld a,#0x33
	ld hl,#recbuf
	ld bc,#128
	call fill_pattern
	ld a,#BDOS_WRITE_SEQ
	call fcb_call
	ret nz
	ld a,#0x91
	ld hl,#recbuf
	ld bc,#128
	call fill_pattern
	ld a,#4
	ld (fcb + 33),a
	xor a
	ld (fcb + 34),a
	ld (fcb + 35),a
	ld a,#BDOS_WRITE_RANDOM_ZF
	call fcb_call
	ret nz
	ld a,#BDOS_CLOSE
	call fcb_call
	call dir_result
	ret nz
	; Every record up to the one just written must now be readable, and the
	; file must measure five records.
	ld hl,#name_test2
	call set_fcb
	ld a,#BDOS_OPEN
	call fcb_call
	call dir_result
	ret nz
	ld b,#1
t_zero_fill_gap:
	push bc
	ld a,b
	ld (fcb + 33),a
	xor a
	ld (fcb + 34),a
	ld (fcb + 35),a
	ld a,#BDOS_READ_RANDOM
	call fcb_call
	jr nz,t_zero_fill_fail
	pop bc
	inc b
	ld a,b
	cp #4
	jr c,t_zero_fill_gap
	; The record itself must be exactly what was written.
	ld a,#4
	ld (fcb + 33),a
	ld a,#BDOS_READ_RANDOM
	call fcb_call
	ret nz
	ld a,#0x91
	ld hl,#cmpbuf
	ld bc,#128
	call fill_pattern
	ld hl,#cmpbuf
	ld de,#recbuf
	ld bc,#128
	call cmp_block
	ret nz
	ld hl,#name_test2
	call set_fcb
	ld a,#BDOS_FILE_SIZE
	call fcb_call
	ld hl,(fcb + 33)
	ld de,#5
	jp cmp_hl_de
t_zero_fill_fail:
	pop bc
	ret

; Rename must move the contents, so the file is opened and sized afterwards.
t_rename:
	ld hl,#name_test
	call set_fcb
	ld hl,#name_test3
	ld de,#fcb + 17
	ld bc,#11
	ldir
	ld a,#BDOS_RENAME
	call fcb_call
	call dir_result
	ret nz
	ld hl,#name_test3
	call set_fcb
	ld a,#BDOS_FILE_SIZE
	call fcb_call
	ld hl,(fcb + 33)
	ld de,#6
	jp cmp_hl_de

t_rename_gone:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_OPEN
	call fcb_call
	call dir_result
	jr nz,t_rename_gone_ok
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_rename_gone_ok:
	xor a
	ret

; ERA takes ambiguous names: both test files must go, in one call.
t_delete_wild:
	ld hl,#name_wild
	call set_fcb
	ld a,#BDOS_DELETE
	call fcb_call
	call dir_result
	ret nz
	ld hl,#name_test2
	call set_fcb
	ld a,#BDOS_OPEN
	call fcb_call
	call dir_result
	jr nz,t_delete_wild_ok
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_delete_wild_ok:
	xor a
	ret

t_delete_gone:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_DELETE
	call fcb_call
	call dir_result
	jr nz,t_delete_gone_ok
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_delete_gone_ok:
	xor a
	ret

; Software write protection is enforced above ZSDOS for a FAT drive, so it has
; to be checked independently of ZSDOS's own enforcement.
t_write_protect:
	ld c,#BDOS_WRITE_PROTECT
	call BDOS
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_MAKE
	call fcb_call
	call dir_result
	jr nz,t_write_protect_ok
	ld a,#ERR_UNEXPECTED
	or a
	ret
t_write_protect_ok:
	xor a
	ret

; ZSDOS FLAGS bit 2 ("Read-Only Enable") makes CMND37 skip the write-protect
; clear, so functions 13 and 37 and a warm boot all leave it set.  Drop the
; bit just long enough for function 37 to work, then restore the user's byte.
t_wp_clear:
	ld c,#BDOS_GET_FLAGS
	call BDOS
	ld (saved_flags),a
	and #(~ZSDOS_FLAG_RO_ENABLE & 0xff)
	ld e,a
	ld c,#BDOS_SET_FLAGS
	call BDOS
	ld de,#0xffff
	ld c,#BDOS_RESET_DRIVE
	call BDOS
	ld a,(saved_flags)
	ld e,a
	ld c,#BDOS_SET_FLAGS
	call BDOS
	ld c,#BDOS_GET_RO
	call BDOS
	ld a,l
	or h
	ret z
	ld a,#1
	ld (wp_stuck),a
	ld a,#ERR_VALUE
	ld hl,#0
	ld (v_want),hl
	ld c,#BDOS_GET_RO
	push af
	call BDOS
	ld (v_got),hl
	pop af
	or a
	ret

; The drive must be usable again, and nothing of this run may be left on it.
t_final_clean:
	ld hl,#name_test
	call set_fcb
	ld a,#BDOS_MAKE
	call fcb_call
	call dir_result
	ret nz
	ld a,#BDOS_CLOSE
	call fcb_call
	ld hl,#name_wild
	call set_fcb
	ld a,#BDOS_DELETE
	call fcb_call
	jp dir_result

test_table:
	.dw n_clean,        t_clean
	.dw n_make,         t_make
	.dw n_write_seq,    t_write_seq
	.dw n_close,        t_close
	.dw n_open,         t_open
	.dw n_read_seq,     t_read_seq
	.dw n_file_size,    t_file_size
	.dw n_write_random, t_write_random
	.dw n_zero_fill,    t_zero_fill
	.dw n_rename,       t_rename
	.dw n_rename_gone,  t_rename_gone
	.dw n_delete_wild,  t_delete_wild
	.dw n_delete_gone,  t_delete_gone
	.dw n_final_clean,  t_final_clean
	.dw 0,              0

; Optional: only walked when an argument was given.
wp_table:
	.dw n_write_protect, t_write_protect
	.dw n_wp_clear,     t_wp_clear
	.dw n_wp_final,     t_final_clean
	.dw 0,              0

n_clean:         .ascii "clean slate       $"
n_make:          .ascii "make              $"
n_write_seq:     .ascii "write sequential  $"
n_close:         .ascii "close             $"
n_open:          .ascii "open              $"
n_read_seq:      .ascii "read sequential   $"
n_file_size:     .ascii "file size         $"
n_write_random:  .ascii "write/read random $"
n_zero_fill:     .ascii "random zero fill  $"
n_rename:        .ascii "rename            $"
n_rename_gone:   .ascii "old name gone     $"
n_delete_wild:   .ascii "delete wildcard   $"
n_delete_gone:   .ascii "delete missing    $"
n_write_protect: .ascii "write protected   $"
n_wp_clear:      .ascii "clear protection  $"
n_final_clean:   .ascii "writable again    $"
n_wp_final:      .ascii "clean after w/p   $"

txt_banner:  .ascii "ZFCB: CP/M FCB read/write tests on drive "
txt_drive_letter: .ascii "?"
	.ascii ":\r\n$"
txt_ok:      .ascii "ok\r\n$"
txt_fail:    .ascii "FAIL $"
txt_got:     .ascii " got=$"
txt_want:    .ascii " want=$"
txt_passed:  .ascii "passed $"
txt_failed:  .ascii "  failed $"
txt_crlf:    .ascii "\r\n$"
txt_wp_stuck: .ascii "\r\nWARNING: drive left write protected; power cycle to recover\r\n$"

name_test:   .ascii "ZFCBTST TMP"
name_test2:  .ascii "ZFCBTS2 TMP"
name_test3:  .ascii "ZFCBTS3 TMP"
name_wild:   .ascii "ZFCBT???TMP"

entry_sp:    .dw 0
tbl_ptr:     .dw 0
call_vec:    .dw 0
v_got:       .dw 0
v_want:      .dw 0
saved_flags: .db 0
pass_count:  .db 0
fail_count:  .db 0
wp_stuck:    .db 0
wp_enabled:  .db 0
fcb:         .ds 36
recbuf:      .ds 128
cmpbuf:      .ds 128
	.ds 128
stack_top:
