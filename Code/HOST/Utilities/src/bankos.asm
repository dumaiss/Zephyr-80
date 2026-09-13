; BANKOS.COM -- software validation for the banked OS, Phase 1.
;
; ../CPM2.2/docs/Zephyr-80_OS_Execution_Memory_Architecture.md, section 27.  An
; ordinary transient: everything it checks goes through CALL 5 and the BDOS
; facade, with arguments deliberately placed in 8000h-A0FFh and C800h, inside
; 2000h-DFFFh, the range bank 7 hides while ZSDOS runs.
;
;   1  IX survives BDOS calls (F2: ZSDOS restores IX from IXSAVE by address)
;   2  functions 27 and 31 return pointers the program can read (F7)
;   3  function 47 returns the program's own DMA, not a staging buffer
;   4  a 150-character function 9 string from the hidden range prints whole
;   5  file I/O with FCB and DMA hidden round-trips, and search-first finds the
;      file.  Needs a writable drive: runs only when the current drive is not A:
;   6  page zero from another bank: with application bank 5 selected, search
;      first writes its directory entry into bank 5's 0080h, not bank 0's
;   7  interrupt registration: a bad source and callbacks outside E000h-E3FFh
;      are refused, a CTC 3 tick counts during disk access, unregistering stops
;      it, and a channel enabled without a registration is shut off
;   8  program exit stops a registered channel and clears its slot
;
; Prints only failures, then a summary.  Returns to the CCP after a key press.

	.module bankos
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
F_CONIN		= 1
F_CONOUT	= 2
F_PRINT		= 9
F_VERSION	= 12
F_OPEN		= 15
F_CLOSE		= 16
F_SFIRST	= 17
F_SNEXT		= 18
F_DELETE	= 19
F_READ		= 20
F_WRITE		= 21
F_MAKE		= 22
F_LOGINV	= 24
F_CURDSK	= 25
F_SETDMA	= 26
F_ALV		= 27
F_DPB		= 31
F_GETDMA	= 47
Z_REGISTER_ISR	= 200
Z_UNREGISTER_ISR = 201
Z_PROGRAM_EXIT	= 202
Z_SELMEM	= 212			; 210 + ZBIOS_EXT_BASE entry 2

CTC3_PORT	= 0x43
CTC_TICK_CONTROL = 0xa7			; interrupt, timer, /256, constant follows, reset
CTC_TICK_TC	= 0x00			; 256: about 150 Hz at 10 MHz

DMA_H		= 0xc800		; hidden while ZSDOS runs
FCB_H		= 0x9000
STR_H		= 0x9800
READ_H		= 0xa000
CB_ADDR		= 0xe000		; program interrupt reservation
CB_COUNT	= 0xe010
CORE_ADDR	= 0xe080		; the reservation: common memory
REGBLK		= 0xe300
RES_SEL5	= 0xe340
RES_SEARCH	= 0xe341
RES_SEL0	= 0xe342
RES_ENTRY	= 0xe350
ENTRY5		= 0xe390
SAVE0080	= 0xe3a0
CSTACK		= 0xe3f0
NRECORDS	= 4

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld de,#msg_banner
	call puts

; ---- 1 IX across BDOS calls ------------------------------------------------
	ld de,#msg_t1
	call puts
	ld ix,#0x5aa5
	ld c,#F_VERSION
	call bdos_ix
	ld c,#F_CURDSK
	call bdos_ix
	ld c,#F_LOGINV
	call bdos_ix
	ld c,#F_DPB
	call bdos_ix
	ld c,#F_ALV
	call bdos_ix
	ld c,#F_GETDMA
	call bdos_ix

; ---- 2 functions 27 and 31 --------------------------------------------------
	ld de,#msg_t2
	call puts
	ld c,#F_DPB
	call BDOS
	ld de,#lbl_dpb_body
	call check_not_body
	ld a,(hl)
	inc hl
	or (hl)
	jr nz,t2_spt_ok
	ld hl,#lbl_dpb_spt
	call fail
t2_spt_ok:
	ld c,#F_ALV
	call BDOS
	ld de,#lbl_alv_body
	call check_not_body

; ---- 3 function 47 -----------------------------------------------------------
	ld de,#msg_t3
	call puts
	ld de,#DMA_H
	ld c,#F_SETDMA
	call BDOS
	ld c,#F_GETDMA
	call BDOS
	ld de,#DMA_H
	or a
	sbc hl,de
	jr z,t3_ok
	ld hl,#lbl_getdma
	call fail
t3_ok:
	call dma_default

; ---- 4 function 9 from the hidden range -------------------------------------
	ld de,#msg_t4
	call puts
	ld hl,#STR_H
	ld b,#150
t4_fill:
	ld (hl),#'.'
	inc hl
	djnz t4_fill
	ld (hl),#13
	inc hl
	ld (hl),#10
	inc hl
	ld (hl),#'$'
	ld de,#STR_H
	ld c,#F_PRINT
	call BDOS

; ---- 5 file I/O with FCB and DMA hidden -------------------------------------
	ld de,#msg_t5
	call puts
	ld c,#F_CURDSK
	call BDOS
	or a
	jr nz,t5_run
	ld de,#msg_t5_skip
	call puts
	jp t6
t5_run:
	call fcb_file
	ld de,#FCB_H
	ld c,#F_DELETE
	call BDOS
	call fcb_file
	ld de,#FCB_H
	ld c,#F_MAKE
	call BDOS
	inc a
	jr nz,t5_made
	ld hl,#lbl_make
	call fail
	jp t6
t5_made:
	ld de,#DMA_H
	ld c,#F_SETDMA
	call BDOS
	xor a
	ld (rec),a
t5_write:
	ld a,(rec)
	ld hl,#DMA_H
	call fill_record
	ld de,#FCB_H
	ld c,#F_WRITE
	call BDOS
	or a
	jr z,t5_written
	ld hl,#lbl_write
	call fail
	jp t5_cleanup
t5_written:
	ld a,(rec)
	inc a
	ld (rec),a
	cp #NRECORDS
	jr c,t5_write
	ld de,#FCB_H
	ld c,#F_CLOSE
	call BDOS
	inc a
	jr nz,t5_closed
	ld hl,#lbl_close
	call fail
t5_closed:
	call fcb_file
	ld de,#FCB_H
	ld c,#F_OPEN
	call BDOS
	inc a
	jr nz,t5_opened
	ld hl,#lbl_open
	call fail
	jp t5_cleanup
t5_opened:
	ld de,#READ_H
	ld c,#F_SETDMA
	call BDOS
	xor a
	ld (rec),a
t5_read:
	ld de,#FCB_H
	ld c,#F_READ
	call BDOS
	or a
	jr z,t5_got
	ld hl,#lbl_read
	call fail
	jp t5_cleanup
t5_got:
	ld a,(rec)
	call check_record
	ld a,(rec)
	inc a
	ld (rec),a
	cp #NRECORDS
	jr c,t5_read

	call fcb_file
	ld de,#DMA_H
	ld c,#F_SETDMA
	call BDOS
	ld de,#FCB_H
	ld c,#F_SFIRST
	call BDOS
	cp #4
	jr c,t5_found
	ld hl,#lbl_search
	call fail
	jr t5_cleanup
t5_found:
	add a,a				; entry = DMA + 32 * A, A < 4
	add a,a
	add a,a
	add a,a
	add a,a
	ld l,a
	ld h,#0
	ld de,#DMA_H + 1		; name starts one byte in
	add hl,de
	ld de,#file_name
	ld b,#11
t5_name:
	ld a,(de)
	cp (hl)
	jr nz,t5_name_bad
	inc hl
	inc de
	djnz t5_name
	jr t5_cleanup
t5_name_bad:
	ld hl,#lbl_search_name
	call fail
t5_cleanup:
	call dma_default
	call fcb_file
	ld de,#FCB_H
	ld c,#F_DELETE
	call BDOS

; ---- 6 page zero from another bank ------------------------------------------
t6:
	ld de,#msg_t6
	call puts
	ld hl,(BDOS + 1)
	ld (ENTRY5),hl
	ld hl,#0x0080
	ld de,#SAVE0080
	ld bc,#32
	ldir
	ld a,#0xff
	ld (RES_SEL5),a
	ld (RES_SEARCH),a
	ld (RES_SEL0),a
	ld hl,#RES_ENTRY
	ld b,#32
t6_clear:
	ld (hl),#0
	inc hl
	djnz t6_clear
	ld hl,#core_start
	ld de,#CORE_ADDR
	ld bc,#core_end - core_start
	ldir
	ld (saved_sp),sp
	ld sp,#CSTACK
	call CORE_ADDR
	ld sp,(saved_sp)

	ld a,(RES_SEL5)
	ld e,#0
	ld hl,#lbl_selmem5
	call check
	ld a,(RES_SEL0)
	ld e,#0
	ld hl,#lbl_selmem0
	call check
	ld a,(RES_SEARCH)
	cp #4
	jr c,t6_found
	ld hl,#lbl_bank5_search
	call fail
	jr t6_bank0
t6_found:
	ld a,(RES_ENTRY + 1)		; first name character
	cp #0x21
	jr nc,t6_bank0
	ld hl,#lbl_bank5_entry
	call fail
t6_bank0:
	ld hl,#0x0080
	ld de,#SAVE0080
	ld b,#32
t6_compare:
	ld a,(de)
	cp (hl)
	jr nz,t6_bank0_bad
	inc hl
	inc de
	djnz t6_compare
	jr t6_done
t6_bank0_bad:
	ld hl,#lbl_bank0_dma
	call fail
t6_done:
	call dma_default

; ---- 7 interrupt registration ------------------------------------------------
	ld de,#msg_t7
	call puts
	ld hl,#callback_start
	ld de,#CB_ADDR
	ld bc,#callback_end - callback_start
	ldir
	ld hl,#0
	ld (CB_COUNT),hl

	ld b,#4
	ld de,#CB_ADDR
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0xff
	ld hl,#lbl_source4
	call check
	ld b,#3
	ld de,#0x9000
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0xff
	ld hl,#lbl_outside
	call check
	ld b,#3
	ld de,#0xe400
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0xff
	ld hl,#lbl_outside_end
	call check
	ld b,#3
	ld de,#CB_ADDR
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0
	ld hl,#lbl_register
	call check
	ld b,#3
	ld de,#CB_ADDR
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0xff
	ld hl,#lbl_register_twice
	call check

	call ctc3_start
	ld b,#16
t7_disk:
	push bc
	call fcb_all
	ld de,#DMA_H
	ld c,#F_SETDMA
	call BDOS
	ld de,#FCB_H
	ld c,#F_SFIRST
	call BDOS
t7_next:
	inc a
	jr z,t7_disk_done
	ld c,#F_SNEXT
	call BDOS
	jr t7_next
t7_disk_done:
	pop bc
	djnz t7_disk
	call dma_default
	ld hl,(CB_COUNT)
	ld a,h
	or l
	jr nz,t7_ticked
	ld hl,#lbl_ticks
	call fail
t7_ticked:
	ld b,#3
	ld c,#Z_UNREGISTER_ISR
	call BDOS
	ld e,#0
	ld hl,#lbl_unregister
	call check
	call count_snapshot
	call delay
	ld hl,#lbl_still_ticking
	call count_unchanged

	; A channel enabled with no registration is shut off by its first
	; interrupt; the callback, unregistered, must not run.
	call ctc3_start
	call delay
	ld hl,#lbl_unowned
	call count_unchanged

; ---- 8 program exit ----------------------------------------------------------
	ld de,#msg_t8
	call puts
	ld b,#3
	ld de,#CB_ADDR
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0
	ld hl,#lbl_register
	call check
	call ctc3_start
	call delay
	ld c,#Z_PROGRAM_EXIT
	call BDOS
	call count_snapshot
	call delay
	ld hl,#lbl_exit_stops
	call count_unchanged
	ld b,#3
	ld de,#CB_ADDR
	ld c,#Z_REGISTER_ISR
	call BDOS
	ld e,#0
	ld hl,#lbl_exit_clears
	call check
	ld b,#3
	ld c,#Z_UNREGISTER_ISR
	call BDOS

; ---- summary -------------------------------------------------------------------
	ld a,(fails)
	or a
	ld de,#msg_pass
	jr z,summary
	call hex
	ld de,#msg_fail_all
summary:
	call puts
	ld de,#msg_key
	call puts
	ld c,#F_CONIN
	call BDOS
	call crlf
	ld sp,(entry_sp)
	ret

; ---------------------------------------------------------------------------
; C = function.  Call it with DE = 0 and fail unless IX comes back 5AA5h.
bdos_ix:
	ld de,#0
	call BDOS
	push ix
	pop hl
	ld de,#0x5aa5
	or a
	sbc hl,de
	ret z
	ld hl,#lbl_ix
	jp fail

; HL = returned pointer, DE = label.  Fail if it points into 2000h-DFFFh.
check_not_body:
	ld a,h
	cp #0x20
	ret c
	cp #0xe0
	ret nc
	ex de,hl
	jp fail

dma_default:
	ld de,#0x0080
	ld c,#F_SETDMA
	jp BDOS

; FCB_H = BANKOS.TMP on the default drive, the rest zero.
fcb_file:
	ld hl,#file_name
	jr fcb_set
; FCB_H = ????????.??? on the default drive.
fcb_all:
	ld hl,#all_name
fcb_set:
	ld de,#FCB_H
	xor a
	ld (de),a
	inc de
	ld bc,#11
	ldir
	ld b,#24
fcb_zero:
	ld (de),a
	inc de
	djnz fcb_zero
	ret

; A = record number, HL = buffer.  Fill 128 bytes with A + offset.
fill_record:
	ld c,a
	ld b,#0
fill_loop:
	ld a,c
	add a,b
	ld (hl),a
	inc hl
	inc b
	ld a,b
	cp #128
	jr c,fill_loop
	ret

; A = record number.  Fail if READ_H does not hold its pattern.
check_record:
	ld c,a
	ld hl,#READ_H
	ld b,#0
check_record_loop:
	ld a,c
	add a,b
	cp (hl)
	jr nz,check_record_bad
	inc hl
	inc b
	ld a,b
	cp #128
	jr c,check_record_loop
	ret
check_record_bad:
	ld hl,#lbl_record
	jp fail

ctc3_start:
	ld a,#CTC_TICK_CONTROL
	out (CTC3_PORT),a
	ld a,#CTC_TICK_TC
	out (CTC3_PORT),a
	ret

count_snapshot:
	ld hl,(CB_COUNT)
	ld (count1),hl
	ret

; HL = label.  Fail if the callback ran since count_snapshot.
count_unchanged:
	push hl
	ld hl,(CB_COUNT)
	ld de,(count1)
	or a
	sbc hl,de
	pop hl
	ret z
	jp fail

; About half a second, interrupts enabled.
delay:
	ld b,#4
delay_outer:
	ld hl,#0
delay_inner:
	dec hl
	ld a,h
	or l
	jr nz,delay_inner
	djnz delay_outer
	ret

; A = got, E = want, HL = label.  Fail unless equal.
check:
	cp e
	ret z
; HL = label.
fail:
	ld a,(fails)
	inc a
	ld (fails),a
	push hl
	ld de,#msg_fail
	call puts
	pop de
	call puts
	jp crlf

; ---------------------------------------------------------------------------
; Copied to E000h, the program interrupt reservation.
callback_start:
	ld hl,(CB_COUNT)
	inc hl
	ld (CB_COUNT),hl
	ret
callback_end:

; ---------------------------------------------------------------------------
; Copied to E080h, in the program interrupt reservation, and run there on a
; common stack: SELMEM 5 replaces the low 56 KiB, this program included.  Relative jumps only; calls into the facade
; build their return address from CORE_ADDR.
core_start:
	ld a,#5
	ld (REGBLK),a
	ld de,#REGBLK
	ld c,#Z_SELMEM
	ld hl,#CORE_ADDR + (core_r1 - core_start)
	push hl
	ld hl,(ENTRY5)
	jp (hl)
core_r1:
	ld a,(REGBLK)
	ld (RES_SEL5),a
	or a
	jr nz,core_done			; still bank 0: do not write its page zero

	; bank 5: default FCB ????????.??? and a cleared DMA
	ld hl,#0x005c
	ld (hl),#0
	inc hl
	ld b,#11
core_fcb_name:
	ld (hl),#'?'
	inc hl
	djnz core_fcb_name
	ld b,#24
core_fcb_rest:
	ld (hl),#0
	inc hl
	djnz core_fcb_rest
	ld hl,#0x0080
	ld b,#128
core_dma_clear:
	ld (hl),#0
	inc hl
	djnz core_dma_clear

	ld de,#0x0080
	ld c,#F_SETDMA
	ld hl,#CORE_ADDR + (core_r2 - core_start)
	push hl
	ld hl,(ENTRY5)
	jp (hl)
core_r2:
	ld de,#0x005c
	ld c,#F_SFIRST
	ld hl,#CORE_ADDR + (core_r3 - core_start)
	push hl
	ld hl,(ENTRY5)
	jp (hl)
core_r3:
	ld (RES_SEARCH),a
	cp #4
	jr nc,core_back
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	ld l,a
	ld h,#0
	ld de,#0x0080
	add hl,de
	ld de,#RES_ENTRY
	ld bc,#32
	ldir
core_back:
	xor a
	ld (REGBLK),a
	ld de,#REGBLK
	ld c,#Z_SELMEM
	ld hl,#CORE_ADDR + (core_r4 - core_start)
	push hl
	ld hl,(ENTRY5)
	jp (hl)
core_r4:
	ld a,(REGBLK)
	ld (RES_SEL0),a
core_done:
	ret
core_end:

; ---------------------------------------------------------------------------
file_name:	.ascii "BANKOS  TMP"
all_name:	.ascii "???????????"

lbl_ix:			.ascii "IX changed across a BDOS call$"
lbl_dpb_body:		.ascii "function 31 pointer is in 2000h-DFFFh$"
lbl_dpb_spt:		.ascii "function 31 DPB has SPT 0$"
lbl_alv_body:		.ascii "function 27 pointer is in 2000h-DFFFh$"
lbl_getdma:		.ascii "function 47 is not the program's DMA$"
lbl_make:		.ascii "make BANKOS.TMP failed$"
lbl_write:		.ascii "write with hidden FCB/DMA failed$"
lbl_close:		.ascii "close failed$"
lbl_open:		.ascii "open failed$"
lbl_read:		.ascii "read with hidden FCB/DMA failed$"
lbl_record:		.ascii "record read back differs$"
lbl_search:		.ascii "search first did not find BANKOS.TMP$"
lbl_search_name:	.ascii "search first entry has the wrong name$"
lbl_selmem5:		.ascii "SELMEM 5 through function 212 refused$"
lbl_selmem0:		.ascii "SELMEM 0 through function 212 refused$"
lbl_bank5_search:	.ascii "bank 5 search first found nothing$"
lbl_bank5_entry:	.ascii "bank 5 0080h did not receive the entry$"
lbl_bank0_dma:		.ascii "bank 0 0080h changed by a bank 5 call$"
lbl_source4:		.ascii "register source 4 accepted$"
lbl_outside:		.ascii "register callback 9000h accepted$"
lbl_outside_end:	.ascii "register callback E400h accepted$"
lbl_register:		.ascii "register CTC 3 at E000h refused$"
lbl_register_twice:	.ascii "second register of CTC 3 accepted$"
lbl_ticks:		.ascii "no CTC 3 ticks during disk access$"
lbl_unregister:		.ascii "unregister CTC 3 refused$"
lbl_still_ticking:	.ascii "callback ran after unregister$"
lbl_unowned:		.ascii "unregistered channel ran the callback$"
lbl_exit_stops:		.ascii "callback ran after program exit$"
lbl_exit_clears:	.ascii "program exit left CTC 3 registered$"

msg_banner:	.ascii "BANKOS - banked OS Phase 1 validation"
		.db 13,10
		.ascii "$"
msg_t1:		.ascii "1 IX across BDOS calls"
		.db 13,10
		.ascii "$"
msg_t2:		.ascii "2 functions 27 and 31"
		.db 13,10
		.ascii "$"
msg_t3:		.ascii "3 function 47"
		.db 13,10
		.ascii "$"
msg_t4:		.ascii "4 function 9 from 9800h; 150 dots follow:"
		.db 13,10
		.ascii "$"
msg_t5:		.ascii "5 file I/O with FCB and DMA hidden"
		.db 13,10
		.ascii "$"
msg_t5_skip:	.ascii "  skipped: current drive is A: (run from B: or C:)"
		.db 13,10
		.ascii "$"
msg_t6:		.ascii "6 page zero from bank 5"
		.db 13,10
		.ascii "$"
msg_t7:		.ascii "7 interrupt registration"
		.db 13,10
		.ascii "$"
msg_t8:		.ascii "8 program exit"
		.db 13,10
		.ascii "$"
msg_fail:	.ascii " FAIL $"
msg_pass:	.ascii "BANKOS: PASS"
		.db 13,10
		.ascii "$"
msg_fail_all:	.ascii " failed - BANKOS: FAIL"
		.db 13,10
		.ascii "$"
msg_key:	.ascii "press a key$"

; ---------------------------------------------------------------------------
; DE = '$'-terminated string.  Preserves BC, HL, IX.
puts:
	push bc
	push hl
	push ix
	ld c,#F_PRINT
	call BDOS
	pop ix
	pop hl
	pop bc
	ret

crlf:
	ld a,#13
	call conout
	ld a,#10
	jr conout

hex:
	push af
	rrca
	rrca
	rrca
	rrca
	call nibble
	pop af
nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
conout:
	push bc
	push de
	push hl
	push ix
	ld e,a
	ld c,#F_CONOUT
	call BDOS
	pop ix
	pop hl
	pop de
	pop bc
	ret

entry_sp:	.dw 0
saved_sp:	.dw 0
count1:		.dw 0
rec:		.db 0
fails:		.db 0

		.ds 128
stack_top:
