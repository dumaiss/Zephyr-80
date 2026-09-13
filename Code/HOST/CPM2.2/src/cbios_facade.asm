; Zephyr-80 BDOS facade (banked OS, Phase 1 steps 8 and 10).
;
; CALL 5 lands here, in common memory, normally in mode 10.  ZSDOS is in bank 7,
; visible only in mode 11, where 2000h-BFFFh is the OS rather than the program.
; So for each call the facade:
;   - switches to its own common stack;
;   - copies each argument ZSDOS will read or write that lies in the hidden range
;     into a common staging buffer, and hands ZSDOS the buffer instead;
;   - enters mode 11, calls ZSDOS, and returns to the mode it found;
;   - copies results back and returns on the program's stack.
; See docs/Zephyr-80_OS_Execution_Memory_Architecture.md, sections 9, 10, 13, 22.
;
; State lives in single slots: the facade is not reentrant (F8).  Bank 7 code
; never calls CALL 5, and interrupt handlers never call BDOS.  IX and IY are not
; touched, so ZSDOS's own IX preservation reaches the program intact.
;
; The facade does not change the interrupt state.  The BIOS owns IM2 and every
; vector entry reaches common code, so an interrupt during mode 11 is safe (F9).
;
; FACADE_FORCE_STAGE = 1 stages every eligible argument even when ZSDOS could
; use it in place, the plan's first validation build (section 13).  Function 10
; is never forced: ZSDOS tells a command processor's own line input apart by the
; buffer's address, and a staged buffer would hide it.
;
; Zephyr functions, dispatched here without ZSDOS seeing them:
;   200  REGISTER_ISR     B = source (CTC channel 0-3), DE = callback
;   201  UNREGISTER_ISR   B = source
;   202  PROGRAM_EXIT     stop and clear every registration
;   203  SYSINFO          HL -> system information block (zephyr_sysinfo)
;   210-217  ZBIOS_EXT_BASE entry 0-7 (MOVE, XMOVE, SELMEM, SETBNK, IOCALL,
;            VIDEO_SEND, IOCBULK, IOCBULKW) through a register block:
;            DE -> A, C, B, E, D, L, H in, the same seven bytes out
;   Each returns A, with L = A and H = B = 0.  An unassigned number returns FFh.
;   SELMEM through 212 changes the caller's bank, so the caller must be in
;   common memory, as it always had to be for SELMEM.

	.globl facade_entry,facade_reset
	.globl FACADE_CODE_START,FACADE_CODE_END
	.globl irq_register,irq_unregister,irq_program_exit
	.globl zephyr_sysinfo,IOC_DIAG_STATUS,BIOS_CODE_START

FACADE_FORCE_STAGE	= 1

; Argument flags per BDOS function.
F_FCB		= 0x01		; DE -> FCB, read and written
F_SFCB		= 0x02		; DE -> FCB, kept for search-next
F_DMA_IN	= 0x04		; ZSDOS reads the DMA
F_DMA_OUT	= 0x08		; ZSDOS writes the DMA
F_CONBUF	= 0x10		; DE -> console buffer, max + 2 bytes
F_STRING	= 0x20		; DE -> '$'-terminated string
F_TIME		= 0x40		; DE -> 6-byte time, read and written
F_SPECIAL	= 0x80		; handled by function number

BDOS_RESET_DISK	= 13
BDOS_SETDMA	= 26
BDOS_GET_ALV	= 27
BDOS_GET_DPB	= 31
BDOS_GETDMA	= 47

FCB_BYTES	= 36
TIME_BYTES	= 6
DPB_COPY_BYTES	= 16
ALV_COPY_BYTES	= 256
DMA_BYTES	= 128
REGBLK_BYTES	= 7

FAC_LOW_FUNCTIONS	= 49		; 0-48
FAC_HIGH_FIRST		= 98
FAC_HIGH_FUNCTIONS	= 6		; 98-103

ZEXT_FIRST		= 200
ZEXT_REGISTER_ISR	= 200
ZEXT_UNREGISTER_ISR	= 201
ZEXT_PROGRAM_EXIT	= 202
ZEXT_SYSINFO		= 203
ZEXT_BIOS_EXT_FIRST	= 210
ZEXT_BIOS_EXT_COUNT	= 8
ZEXT_LIMIT		= 240

	.area CODE (ABS)
	.org CBIOS_FACADE_BASE

FACADE_CODE_START:

; The six serial-number bytes CP/M keeps ahead of FBASE, then FBASE itself.
; ZSDOS's own serial, so tools that identify the BDOS by it still see ZSDOS.
facade_serial:
	.ascii "ZSDOS "
facade_fbase:
	jp facade_entry

	.ifne (facade_fbase - facade_serial) - (FBASE - CBIOS_FACADE_BASE)
	.error 1			; FBASE must be six bytes into the facade
	.endif

; ---------------------------------------------------------------------------
; CALL 5.  In: C = function, DE = parameter.  Out: what ZSDOS returns (AF, BC,
; DE, HL), with a staged pointer in DE mapped back to the program's own.
; ---------------------------------------------------------------------------
facade_entry:
	ld (fac_caller_sp),sp
	ld sp,#FAC_STACK_TOP
	ld (fac_de),de
	ld (fac_os_de),de
	ld (fac_ret_de),de
	ld hl,#0
	ld (fac_ret_af),hl
	ld (fac_ret_bc),hl
	ld (fac_ret_hl),hl
	ld a,c
	ld (fac_fn),a
	cp #ZEXT_FIRST
	jr c,fac_bdos
	cp #ZEXT_LIMIT
	jp c,fac_zext

fac_bdos:
	call fac_flags_for_a
	ld (fac_flags),a
	and #F_SPECIAL
	jp nz,fac_special
	ld a,(fac_flags)
	and #F_STRING
	jp nz,fac_print_string
	call fac_stage_in
	call fac_os_call
	call fac_stage_out
	jp fac_return

; A = function.  Out: A = argument flags.
fac_flags_for_a:
	cp #FAC_LOW_FUNCTIONS
	jr c,fac_flags_low
	sub #FAC_HIGH_FIRST
	jr c,fac_flags_none
	cp #FAC_HIGH_FUNCTIONS
	jr nc,fac_flags_none
	ld hl,#fac_flags_high
	jr fac_flags_index
fac_flags_low:
	ld hl,#fac_flags_low_table
fac_flags_index:
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	ret
fac_flags_none:
	xor a
	ret

; ---------------------------------------------------------------------------
; fac_visible: Z if HL..HL+BC-1 lies wholly in 0000h-1FFFh or wholly in
; E000h-FFFFh, so ZSDOS can use it in place; NZ if it touches the OS body.
; Forced staging answers NZ for every range.  fac_visible_nf never forces.
; Preserves BC, DE, HL.
; ---------------------------------------------------------------------------
fac_visible:
	.if FACADE_FORCE_STAGE
	or #0x01
	ret
	.endif
fac_visible_nf:
	push hl
	ld a,h
	cp #0xe0
	jr nc,fac_visible_high
	add hl,bc			; exclusive end
	ld a,h
	cp #0x20
	jr c,fac_visible_yes
	jr nz,fac_visible_no
	ld a,l
	or a
	jr z,fac_visible_yes
fac_visible_no:
	pop hl
	or #0x01
	ret
fac_visible_high:
	add hl,bc			; no carry: ends below 10000h
	jr nc,fac_visible_yes
	ld a,h				; carry with 0000h: ends exactly at 10000h
	or l
	jr nz,fac_visible_no
fac_visible_yes:
	pop hl
	xor a
	ret

; ---------------------------------------------------------------------------
; Copy hidden arguments in, in mode 10.  Sets fac_os_de and fac_eff_dma.
; ---------------------------------------------------------------------------
fac_stage_in:
	ld a,(fac_flags)
	and #F_FCB | F_SFCB
	jr z,fac_stage_in_conbuf
	ld hl,(fac_de)
	ld bc,#FCB_BYTES
	call fac_visible
	jr z,fac_stage_in_conbuf
	ld de,#FAC_FCB_BUF
	ld a,(fac_flags)
	and #F_SFCB
	jr z,fac_stage_in_fcb
	ld de,#FAC_SFCB_BUF		; ZSDOS keeps this pointer for search-next
fac_stage_in_fcb:
	ld (fac_os_de),de
	ldir

fac_stage_in_conbuf:
	ld a,(fac_flags)
	and #F_CONBUF
	jr z,fac_stage_in_time
	ld hl,(fac_de)
	ld c,(hl)			; maximum length
	ld b,#0
	inc bc
	inc bc
	ld (fac_conbuf_len),bc
	call fac_visible_nf
	jr z,fac_stage_in_time
	ld de,#FAC_CONBUF
	ld (fac_os_de),de
	ldir

fac_stage_in_time:
	ld a,(fac_flags)
	and #F_TIME
	jr z,fac_stage_in_dma
	ld hl,(fac_de)
	ld bc,#TIME_BYTES
	call fac_visible
	jr z,fac_stage_in_dma
	ld de,#FAC_TIME_BUF
	ld (fac_os_de),de
	ldir

fac_stage_in_dma:
	ld a,(fac_flags)
	and #F_DMA_IN | F_DMA_OUT
	ret z
	ld hl,(fac_app_dma)
	ld bc,#DMA_BYTES
	call fac_visible
	jr nz,fac_stage_in_dma_hidden
	ld (fac_eff_dma),hl
	ret
fac_stage_in_dma_hidden:
	ld de,#FAC_DMA_BUF
	ld (fac_eff_dma),de
	ld a,(fac_flags)
	and #F_DMA_IN
	ret z
	ldir
	ret

; ---------------------------------------------------------------------------
; Copy results back, in mode 10.
; ---------------------------------------------------------------------------
fac_stage_out:
	ld a,(fac_flags)
	and #F_FCB | F_SFCB
	ld bc,#FCB_BYTES
	call nz,fac_copy_back
	ld a,(fac_flags)
	and #F_CONBUF
	ld bc,(fac_conbuf_len)
	call nz,fac_copy_back
	ld a,(fac_flags)
	and #F_TIME
	ld bc,#TIME_BYTES
	call nz,fac_copy_back
	ld a,(fac_flags)
	and #F_DMA_OUT
	ret z
	ld hl,(fac_eff_dma)
	ld de,#FAC_DMA_BUF
	or a
	sbc hl,de
	ret nz				; the DMA was used in place
	ld hl,#FAC_DMA_BUF
	ld de,(fac_app_dma)
	ld bc,#DMA_BYTES
	ldir
	ret

; BC = bytes.  If the pointer argument was staged, copy the buffer back to the
; program's own pointer.
fac_copy_back:
	ld hl,(fac_os_de)
	ld de,(fac_de)
	or a
	sbc hl,de
	ret z
	ld hl,(fac_os_de)
	ldir
	ret

; ---------------------------------------------------------------------------
; fac_os_enter_call: enter mode 11, bring ZSDOS's DMA in step when the function
; uses it, call ZSDOS with (fac_fn) and (fac_os_de), and keep what it returned.
; Stays in mode 11.  fac_os_leave restores the latch.  fac_os_call does both.
; ---------------------------------------------------------------------------
fac_os_enter_call:
	in a,(BANK_PORT)
	ld (fac_latch),a
	or #SHADOW_BIT
	out (BANK_PORT),a
	ld a,(fac_flags)
	and #F_DMA_IN | F_DMA_OUT
	jr z,fac_os_function
	ld hl,(fac_eff_dma)
	ld de,(fac_zsdos_dma)
	or a
	sbc hl,de
	jr z,fac_os_function
	ld de,(fac_eff_dma)
	ld (fac_zsdos_dma),de
	ld c,#BDOS_SETDMA
	call ZSDOS_ENTRY
fac_os_function:
	ld a,(fac_fn)
	ld c,a
	ld de,(fac_os_de)
	call ZSDOS_ENTRY
	ld (fac_ret_hl),hl
	ld (fac_ret_de),de
	ld (fac_ret_bc),bc
	push af
	pop hl
	ld (fac_ret_af),hl
	ret

fac_os_call:
	call fac_os_enter_call
fac_os_leave:
	ld a,(fac_latch)
	out (BANK_PORT),a
	ret

; ---------------------------------------------------------------------------
; Functions handled by number.
; ---------------------------------------------------------------------------
fac_special:
	ld a,(fac_fn)
	cp #BDOS_SETDMA
	jr z,fac_setdma
	cp #BDOS_GETDMA
	jr z,fac_getdma
	cp #BDOS_RESET_DISK
	jr z,fac_reset_disk
	cp #BDOS_GET_ALV
	jr z,fac_get_alv
	; BDOS_GET_DPB
	ld hl,#FAC_DPB_COPY
	ld bc,#DPB_COPY_BYTES
	jr fac_pointer_copy
fac_get_alv:
	ld hl,#FAC_ALV_COPY
	ld bc,#ALV_COPY_BYTES

; Functions 27 and 31 return a pointer into bank 7, where the disk structures
; live (F7).  Copy what it points at into common memory and return the copy.
fac_pointer_copy:
	ld (fac_copy_dst),hl
	ld (fac_copy_len),bc
	call fac_os_enter_call
	ld hl,(fac_ret_hl)
	ld a,h
	cp #0x20
	jr c,fac_pointer_done		; already visible to the program
	cp #0xe0
	jr nc,fac_pointer_done
	ld de,(fac_copy_dst)
	ld bc,(fac_copy_len)
	ldir
	ld hl,(fac_copy_dst)
	call fac_set_hl_result
fac_pointer_done:
	call fac_os_leave
	jp fac_return

; Function 26 only records the program's DMA.  ZSDOS is told the address it
; should use -- this one, or a staging buffer -- lazily, on the next call that
; reads or writes the DMA (fac_os_enter_call).
fac_setdma:
	ld hl,(fac_de)
	ld (fac_app_dma),hl
	ld hl,#0
	call fac_set_hl_result
	jp fac_return

; Function 47: the program's DMA, never a staging buffer.
fac_getdma:
	ld hl,(fac_app_dma)
	call fac_set_hl_result
	jp fac_return

; Function 13 resets the DMA to 0080h inside ZSDOS (F10).
fac_reset_disk:
	call fac_os_call
	ld hl,#DEFAULT_DMA
	ld (fac_app_dma),hl
	ld (fac_zsdos_dma),hl
	jp fac_return

; HL = result.  Return it the CP/M way: HL, with A = L and B = H.
fac_set_hl_result:
	ld (fac_ret_hl),hl
	ld a,l
	ld (fac_ret_af + 1),a
	ld a,h
	ld (fac_ret_bc + 1),a
	ret

; ---------------------------------------------------------------------------
; Function 9.  The string has no length, so it is copied in chunks of at most
; 127 characters into FAC_DMA_BUF, each terminated, and printed in turn.  ZSDOS
; keeps its column count between calls, so tabs still line up.
; ---------------------------------------------------------------------------
fac_print_string:
	ld hl,(fac_de)
fac_print_chunk:
	ld de,#FAC_DMA_BUF
	ld b,#DMA_BYTES - 1
fac_print_copy:
	ld a,(hl)
	ld (de),a
	inc hl
	inc de
	cp #'$'
	jr z,fac_print_last
	djnz fac_print_copy
	ld a,#'$'
	ld (de),a
	push hl
	call fac_print_staged
	pop hl
	jr fac_print_chunk
fac_print_last:
	call fac_print_staged
	jp fac_return
fac_print_staged:
	ld hl,#FAC_DMA_BUF
	ld (fac_os_de),hl
	jp fac_os_call

; ---------------------------------------------------------------------------
; Return to the program with ZSDOS's registers.
; ---------------------------------------------------------------------------
fac_return:
	ld hl,(fac_ret_af)
	push hl
	ld bc,(fac_ret_bc)
	ld hl,(fac_ret_de)
	ld de,(fac_os_de)
	or a
	sbc hl,de
	ld de,(fac_ret_de)
	jr nz,fac_return_de
	ld de,(fac_de)			; ZSDOS echoed the staged pointer
fac_return_de:
	ld hl,(fac_ret_hl)
	pop af
	ld sp,(fac_caller_sp)
	ret

; ---------------------------------------------------------------------------
; Zephyr functions 200-239.  Run in the mode they were called in: nothing here
; enters bank 7 except through a gate.
; ---------------------------------------------------------------------------
fac_zext:
	cp #ZEXT_REGISTER_ISR
	jr nz,fac_zext_unregister
	call irq_register
	jp fac_zext_return
fac_zext_unregister:
	cp #ZEXT_UNREGISTER_ISR
	jr nz,fac_zext_exit
	call irq_unregister
	jp fac_zext_return
fac_zext_exit:
	cp #ZEXT_PROGRAM_EXIT
	jr nz,fac_zext_sysinfo
	call irq_program_exit
	jp fac_zext_return
fac_zext_sysinfo:
	cp #ZEXT_SYSINFO
	jr nz,fac_zext_bios
	ld hl,#zephyr_sysinfo
	ld a,l
	ld b,h
	ld de,(fac_de)
	ld sp,(fac_caller_sp)
	ret
fac_zext_bios:
	sub #ZEXT_BIOS_EXT_FIRST
	jr c,fac_zext_bad
	cp #ZEXT_BIOS_EXT_COUNT
	jr nc,fac_zext_bad
	ld l,a				; target = ZBIOS_EXT_BASE + 3 * index
	add a,a
	add a,l
	ld l,a
	ld h,#0
	ld de,#ZBIOS_EXT_BASE
	add hl,de
	ld (fac_zext_target),hl
	ld hl,(fac_de)
	ld de,#FAC_REGBLK
	ld bc,#REGBLK_BYTES
	ldir
	ld a,(FAC_REGBLK + 1)
	ld c,a
	ld a,(FAC_REGBLK + 2)
	ld b,a
	ld de,(FAC_REGBLK + 3)
	ld hl,(FAC_REGBLK + 5)
	ld a,(FAC_REGBLK)
	call fac_zext_jump
	ld (FAC_REGBLK),a
	ld a,c
	ld (FAC_REGBLK + 1),a
	ld a,b
	ld (FAC_REGBLK + 2),a
	ld (FAC_REGBLK + 3),de
	ld (FAC_REGBLK + 5),hl
	ld hl,#FAC_REGBLK
	ld de,(fac_de)
	ld bc,#REGBLK_BYTES
	ldir
	ld a,(FAC_REGBLK)
	jp fac_zext_return
fac_zext_jump:
	push hl
	ld hl,(fac_zext_target)
	ex (sp),hl
	ret
fac_zext_bad:
	ld a,#0xff
fac_zext_return:
	ld l,a
	ld h,#0
	ld b,h
	ld de,(fac_de)
	ld sp,(fac_caller_sp)
	ret

; ---------------------------------------------------------------------------
; facade_reset -- cold boot and WBOOT.  The program's DMA is 0080h again, and
; ZSDOS's is unknown until the next DMA call sets it.
; ---------------------------------------------------------------------------
facade_reset:
	ld hl,#DEFAULT_DMA
	ld (fac_app_dma),hl
	ld hl,#0xffff
	ld (fac_zsdos_dma),hl
	ret

; ---------------------------------------------------------------------------
; Argument flags, BDOS functions 0-48 and 98-103.
; ---------------------------------------------------------------------------
fac_flags_low_table:
	.db 0, 0, 0, 0, 0, 0, 0, 0	; 0-7
	.db 0				; 8
	.db F_STRING			; 9   print string
	.db F_CONBUF			; 10  read console buffer
	.db 0, 0			; 11-12
	.db F_SPECIAL			; 13  reset disk system
	.db 0				; 14  select disk
	.db F_FCB, F_FCB		; 15  open, 16 close
	.db F_SFCB | F_DMA_OUT		; 17  search first
	.db F_DMA_OUT			; 18  search next
	.db F_FCB			; 19  delete
	.db F_FCB | F_DMA_OUT		; 20  read sequential
	.db F_FCB | F_DMA_IN		; 21  write sequential
	.db F_FCB, F_FCB		; 22  make, 23 rename
	.db 0, 0			; 24-25
	.db F_SPECIAL			; 26  set DMA
	.db F_SPECIAL			; 27  allocation vector address
	.db 0, 0			; 28-29
	.db F_FCB			; 30  set attributes
	.db F_SPECIAL			; 31  DPB address
	.db 0				; 32  user code
	.db F_FCB | F_DMA_OUT		; 33  read random
	.db F_FCB | F_DMA_IN		; 34  write random
	.db F_FCB, F_FCB		; 35  file size, 36 set random record
	.db 0, 0, 0			; 37-39
	.db F_FCB | F_DMA_IN		; 40  write random with zero fill
	.db 0, 0, 0, 0, 0, 0		; 41-46
	.db F_SPECIAL			; 47  return DMA
	.db 0				; 48  DOS version
fac_flags_high:
	.db F_TIME			; 98  get time
	.db F_TIME			; 99  set time
	.db 0, 0			; 100-101
	.db F_FCB | F_DMA_OUT		; 102 get file stamp
	.db F_FCB | F_DMA_IN		; 103 put file stamp
fac_flags_end:

	.ifne (fac_flags_high - fac_flags_low_table) - FAC_LOW_FUNCTIONS
	.error 1
	.endif
	.ifne (fac_flags_end - fac_flags_high) - FAC_HIGH_FUNCTIONS
	.error 1
	.endif

; ---------------------------------------------------------------------------
; Zephyr BDOS function 203: where a program finds what used to be published at
; fixed addresses.  Layout: ZSYSINFO_OFF_* in cbios_defs.inc; the CP/M tools'
; copy is ../Utilities/src/zbdos.inc.
; ---------------------------------------------------------------------------
zephyr_sysinfo:
	.db ZSYSINFO_VERSION
	.db ZBIOS_XPORT_LEVEL
	.dw IOC_DIAG_STATUS
	.dw SERCON_FLAGS
	.dw BIOS_CODE_START
	.dw ZBIOS_EXT_BASE
zephyr_sysinfo_end:

	.ifne (zephyr_sysinfo_end - zephyr_sysinfo) - (ZSYSINFO_OFF_EXT + 2)
	.error 1			; the block and ZSYSINFO_OFF_* disagree
	.endif

; ---------------------------------------------------------------------------
; State.  RAM at run time: the cold-boot shadow copy puts this image in SRAM.
; ---------------------------------------------------------------------------
fac_caller_sp:		.dw 0
fac_de:			.dw 0
fac_os_de:		.dw 0
fac_fn:			.db 0
fac_flags:		.db 0
fac_latch:		.db 0
fac_app_dma:		.dw DEFAULT_DMA
fac_zsdos_dma:		.dw 0xffff
fac_eff_dma:		.dw 0
fac_conbuf_len:		.dw 0
fac_ret_af:		.dw 0
fac_ret_bc:		.dw 0
fac_ret_de:		.dw 0
fac_ret_hl:		.dw 0
fac_copy_dst:		.dw 0
fac_copy_len:		.dw 0
fac_zext_target:	.dw 0

FACADE_CODE_END:

	.ifgt (FACADE_CODE_END - FACADE_CODE_START) - (FACADE_CODE_LIMIT - CBIOS_FACADE_BASE)
	.error 1			; facade code runs into the BIOS
	.endif
