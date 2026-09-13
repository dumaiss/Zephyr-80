; Zephyr-80 crossing gates (banked OS, Phase 1 steps 7, 9 and 10).
;
; Common-memory entry points for code the common BIOS used to run itself.  That
; code is in bank 7 now, visible only in latch mode 11, so each gate switches to
; a common stack, enters mode 11, calls into bank 7, and restores the latch it
; found.  See docs/Zephyr-80_OS_Execution_Memory_Architecture.md, sections 10,
; 11, 14 and 16.
;
; Callers are programs, in mode 10.  OS code in bank 7 calls the bank 7 entries
; directly and never comes through here.
;
; The gates share one saved SP, one stack and one saved latch, so they are not
; reentrant.  Nothing reaches a gate from inside another: bank 7 code never calls
; a common jump-table entry, and interrupt handlers call nothing here.

	.globl gate_const,gate_conin,gate_conout
	.globl gate_iocall,gate_iocbulk,gate_iocbulkw,gate_video_send
	.globl bios_inert_ret,bios_inert_reader,bios_inert_seldsk
	.globl bios_inert_error,bios_inert_listst,bios_inert_sectran
	.globl xing_os_call_ix,wbtrap,xing_rom_copy_record,bank7_check
	.globl GATE_CODE_START,GATE_CODE_END
	.globl const,conin,conout,IOCALL,IOCBULK,IOCBULKW,VIDEO_SEND
	.globl sio_send_byte,CURRENT_BANK,BIOS7_MAGIC

	.area CODE (ABS)
	.org CBIOS_GATE_CODE_BASE

GATE_CODE_START:

; ---------------------------------------------------------------------------
; xing_os_call_ix
; Purpose:
;   Call a bank 7 routine from common code: enter mode 11, call it, restore the
;   latch exactly as found.
; Input:
;   IX = bank 7 target; A, BC, DE, HL = the target's arguments.
; Output:
;   The target's AF, BC, DE, HL.  IX as the target left it.
; Invariants:
;   SP must be in common memory.  Called in mode 10 or mode 11.  One saved-latch
;   slot, so not reentrant.
; ---------------------------------------------------------------------------
xing_os_call_ix:
	push af
	in a,(BANK_PORT)
	ld (xing_saved_latch),a
	or #SHADOW_BIT
	out (BANK_PORT),a
	pop af
	call xing_jp_ix
	push af
	ld a,(xing_saved_latch)
	out (BANK_PORT),a
	pop af
	ret

xing_jp_ix:
	jp (ix)

; ---------------------------------------------------------------------------
; Console gates: the CP/M BIOS table's CONST, CONIN and CONOUT.
; ZCPR2 calls BIOS+6 and BIOS+9 directly (plan F6), on its own small stack.
; In/Out: the CP/M contract for each entry.
; ---------------------------------------------------------------------------
gate_const:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	ld ix,#const
	jr gate_call

gate_conin:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	ld ix,#conin
	jr gate_call

gate_conout:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	ld ix,#conout
gate_call:
	call xing_os_call_ix
gate_return:
	pop ix
	ld sp,(gate_caller_sp)
	ret

; ---------------------------------------------------------------------------
; gate_iocall -- ZBIOS_EXT_BASE + 0Ch.
; Both 32-byte mailboxes are staged through common memory: the caller's frames
; can be anywhere in its 64 KiB, and in mode 11 bank 7 hides 2000h-BFFFh.
; In/Out: IOCALL's contract (HL = TX frame, DE = RX frame, A = status).  HL and
; DE are returned unchanged; the RX frame is copied back whatever the status,
; as IOCALL leaves it undefined on error anyway.
; ---------------------------------------------------------------------------
gate_iocall:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	push hl
	push de
	ld de,#GATE_TX_BUF
	ld bc,#IOC_FRAME_SIZE
	ldir
	ld hl,#GATE_TX_BUF
	ld de,#GATE_RX_BUF
	ld ix,#IOCALL
	call xing_os_call_ix
	pop de
	push de
	push af
	ld hl,#GATE_RX_BUF
	ld bc,#IOC_FRAME_SIZE
	ldir
	pop af
	pop de
	pop hl
	jp gate_return

; ---------------------------------------------------------------------------
; gate_iocbulk -- ZBIOS_EXT_BASE + 12h: bulk receive.
; The transfer lands in FAC_BULK_BUF and is copied to the caller afterwards, so
; the bulk lane never waits on a mapping change mid-transfer (plan F4).
; In/Out: IOCBULK's contract (HL = destination, DE = count, A = status).
; ---------------------------------------------------------------------------
gate_iocbulk:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	push hl
	push de
	ld hl,#FAC_BULK_BUF
	ld ix,#IOCBULK
	call xing_os_call_ix
	pop bc				; count
	pop de				; caller's destination
	push af
	or a
	jr nz,gate_iocbulk_done		; nothing to deliver
	ld hl,#FAC_BULK_BUF
	ldir				; OK means 1..IOC_BULK_MAX_LEN bytes
gate_iocbulk_done:
	pop af
	jp gate_return

; ---------------------------------------------------------------------------
; gate_iocbulkw -- ZBIOS_EXT_BASE + 15h: bulk transmit.
; The payload is staged before the transfer starts (plan F4).  A count IOCBULKW
; would refuse is passed through uncopied, so IOCBULKW still reports it.
; In/Out: IOCBULKW's contract (HL = source, DE = count, A = status).
; ---------------------------------------------------------------------------
gate_iocbulkw:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	ld a,d
	or e
	jr z,gate_iocbulkw_call
	push hl
	ld hl,#IOC_BULK_MAX_LEN
	or a
	sbc hl,de
	pop hl
	jr c,gate_iocbulkw_call		; count above the maximum
	push de
	ld b,d
	ld c,e
	ld de,#FAC_BULK_BUF
	ldir
	pop de
gate_iocbulkw_call:
	ld hl,#FAC_BULK_BUF
	ld ix,#IOCBULKW
	call xing_os_call_ix
	jp gate_return

; ---------------------------------------------------------------------------
; gate_video_send -- ZBIOS_EXT_BASE + 0Fh.
; In/Out: VIDEO_SEND's contract (A = type, HL = payload, BC = length,
; A = status).
; A VDP data block is staged and sent in chunks of at most FAC_BULK_SIZE bytes;
; the VDP sees one continuous byte stream.  A single frame is staged whole when
; VIDEO_SEND can accept it, and passed through uncopied when it cannot.
; ---------------------------------------------------------------------------
gate_video_send:
	ld (gate_caller_sp),sp
	ld sp,#GATE_STACK_TOP
	push ix
	ld ix,#VIDEO_SEND
	or a
	jr z,gate_video_call		; reset: no payload
	cp #0xff
	jr z,gate_video_call
	cp #VIDEO_TYPE_VDP_DATA_BLOCK
	jr z,gate_video_block
	ld d,a				; type
	ld a,b
	or a
	jr nz,gate_video_single		; too long; VIDEO_SEND refuses it
	ld a,c
	or a
	jr z,gate_video_single		; empty
	cp #VIDEO_SINGLE_PAYLOAD_MAX + 1
	jr nc,gate_video_single
	push bc
	push de
	ld de,#GATE_TX_BUF
	ldir
	pop de
	pop bc
gate_video_single:
	ld hl,#GATE_TX_BUF
	ld a,d
gate_video_call:
	call xing_os_call_ix
	jp gate_return

gate_video_block:
	ld a,b
	or c
	jr z,gate_video_block_done
	push bc				; remaining
	ld a,b
	cp #(FAC_BULK_SIZE >> 8)
	jr c,gate_video_block_have	; under one chunk: send what is left
	ld bc,#FAC_BULK_SIZE
gate_video_block_have:
	push bc				; this chunk
	ld de,#FAC_BULK_BUF
	ldir				; HL moves past the chunk
	pop bc
	push hl				; next source
	push bc
	ld hl,#FAC_BULK_BUF
	ld a,#VIDEO_TYPE_VDP_DATA_BLOCK
	call xing_os_call_ix
	pop de				; this chunk
	pop hl				; next source
	pop bc				; remaining
	push hl
	ld h,b
	ld l,c
	or a
	sbc hl,de
	ld b,h
	ld c,l
	pop hl
	jr gate_video_block
gate_video_block_done:
	xor a
	jp gate_return

; ---------------------------------------------------------------------------
; Inert CP/M BIOS entries (plan F6).
; The disk structures live in bank 7 and ZSDOS reaches the bank 7 BIOS directly,
; so the common table's disk and auxiliary entries do nothing.  Each fails
; cleanly instead of crashing a program that calls it.
; ---------------------------------------------------------------------------
bios_inert_sectran:
	ld h,b
	ld l,c
bios_inert_ret:
	ret

bios_inert_reader:
	ld a,#0x1a			; CP/M end of file
	ret

bios_inert_seldsk:
	ld hl,#0x0000			; no such drive
	ret

bios_inert_error:
	ld a,#BIOS_ERR
	ret

bios_inert_listst:
	xor a				; not ready
	ret

; ---------------------------------------------------------------------------
; wbtrap -- warm boot from bank 7 (plan F1).
; ZSDOS's warm-boot exits jump here instead of RST 0, and ZSDOS's BIOS table
; sends BOOT and WBOOT here too.  In mode 11, 0000h is the program's page zero,
; but whatever it vectors to below C000h may be hidden behind bank 7.  So mode
; 10 is restored first, on a common stack; a program that replaced the JP at
; 0000h then gets control in the mode it expects, and otherwise WBOOT runs.
; ---------------------------------------------------------------------------
wbtrap:
	di
	ld sp,#FAC_STACK_TOP
	ld a,(CURRENT_BANK)
	and #BANK_MASK
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ei
	jp 0x0000

; ---------------------------------------------------------------------------
; xing_rom_copy_record -- drive A:'s shadow/copy window, for the bank 7 backend.
; Shadow/copy mode puts ROM at 0000h-BFFFh, which unmaps bank 7, so the window
; runs from common memory.
; In:  B  = shadow/copy latch value: ROM page, SHADOW_BIT, destination bank
;      HL = ROM source, DE = destination, one 128-byte record
; Out: A = BIOS_OK.  Latch and interrupt state restored as found.
; Invariants:
;   The caller's stack is the storage stack, in bank 7's runtime range
;   C000h-DFFFh, which shadow/copy mode maps to bank 0.  So the latch and
;   interrupt state found are kept in common variables, and nothing touches the
;   stack between the two latch writes.
;   Interrupts are masked across the window, because a handler fetching from
;   below C000h would read flash.  The caller's state is captured with LD A,I
;   and retried once for the NMOS erratum (a read that coincides with an
;   accepted interrupt reports IFF2 clear).
; ---------------------------------------------------------------------------
xing_rom_copy_record:
	ld a,i
	jp pe,xing_rom_copy_iff
	ld a,i
xing_rom_copy_iff:
	ld a,#0x00			; LD leaves P/V alone
	jp po,xing_rom_copy_iff_known
	inc a
xing_rom_copy_iff_known:
	ld (xing_rom_iff),a
	in a,(BANK_PORT)
	ld (xing_rom_latch),a
	di
	ld a,b
	out (BANK_PORT),a
	ld bc,#ROMDISK_RECORD_BYTES
	ldir
	ld a,(xing_rom_latch)
	out (BANK_PORT),a
	ld a,(xing_rom_iff)
	or a
	ld a,#BIOS_OK			; LD leaves Z alone
	ret z
	ei
	ret

; ---------------------------------------------------------------------------
; bank7_check -- confirm bank 7 holds this build's OS image before calling it.
; Called during boot, in mode 11, after sio_core_init.  Returns if the signature
; at BIOS7_MAGIC matches; otherwise reports over SIO0/B -- the one output that
; does not live in bank 7 -- and halts.
; ---------------------------------------------------------------------------
bank7_check:
	ld hl,#BIOS7_MAGIC
	ld de,#bank7_expect
	ld b,#8
bank7_check_loop:
	ld a,(de)
	cp (hl)
	jr nz,bank7_check_failed
	inc hl
	inc de
	djnz bank7_check_loop
	ret
bank7_check_failed:
	ld hl,#bank7_fail_text
bank7_fail_loop:
	ld a,(hl)
	or a
	jr z,bank7_halt
	ld c,a
	push hl
	ld a,#SIO_CH_CONSOLE
	call sio_send_byte
	pop hl
	inc hl
	jr bank7_fail_loop
bank7_halt:
	di
	halt

bank7_expect:
	.ascii "BANK7OS1"
bank7_fail_text:
	.ascii "Zephyr-80: bank 7 does not hold this build's OS image"
	.db CR,LF,0

gate_caller_sp:
	.dw 0
xing_saved_latch:
	.db 0
xing_rom_latch:
	.db 0
xing_rom_iff:
	.db 0

GATE_CODE_END:

	.ifgt (GATE_CODE_END - GATE_CODE_START) - (CBIOS_GATE_CODE_LIMIT - CBIOS_GATE_CODE_BASE)
	.error 1			; gates overflow their region
	.endif
