; Zephyr-80 interrupt ownership (banked OS, Phase 1 step 7; plan section 18).
;
; IM2 belongs to the BIOS.  I always selects the page at CBIOS_IM2_VECTOR_TABLE,
; every entry in it leads to common code, and a program that wants a timer
; interrupt registers a callback through the BDOS facade rather than loading I
; itself.  So an interrupt is safe in mode 11 whatever the program is doing.
;
; Programmable sources are CTC channels 0-3.  SIO0/B and SIO1 belong to the BIOS.
;
; A callback:
;   - lives, with everything it touches, in E000h-E3FFh (PROGRAM_ISR_AREA);
;     only the entry address is checked
;   - runs in mode 10 or mode 11, on the ISR stack, with interrupts disabled
;   - may use AF, BC, DE, HL; preserves IX, IY and the alternate set
;   - ends with RET, never enables interrupts, never calls BDOS or the BIOS
; Registrations are cleared by WBOOT and by the program-exit call ZCPR2 makes
; when a transient returns (plan F5).

	.globl irq_register,irq_unregister,irq_program_exit,irq_reset
	.globl IRQ_CODE_START,IRQ_CODE_END
	.globl xing_isr

	.area CODE (ABS)
	.org CBIOS_IRQ_CODE_BASE

IRQ_CODE_START:

; ---------------------------------------------------------------------------
; CTC channel entries.  Each moves to the ISR stack before pushing anything, so
; only the return address lands on the interrupted stack (plan F2).
; ---------------------------------------------------------------------------
ctc0_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	xor a
	jr ctc_isr_dispatch

ctc1_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#1
	jr ctc_isr_dispatch

ctc2_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#2
	jr ctc_isr_dispatch

ctc3_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#3

; A = channel.
ctc_isr_dispatch:
	push bc
	push de
	push hl
	ld c,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#irq_ctc_slots
	add hl,de
	ld a,(hl)
	inc hl
	ld h,(hl)
	ld l,a
	or h
	jr z,ctc_isr_unowned
	ld de,#ctc_isr_done
	push de
	jp (hl)

ctc_isr_unowned:
	; Enabled without a registration: shut the channel off instead of taking
	; this interrupt forever.
	ld a,c
	add a,#CTC0_CTRL
	ld c,a
	ld a,#CTC_RESET_DISABLE
	out (c),a
ctc_isr_done:
	pop hl
	pop de
	pop bc
	pop af
	ld sp,(CBIOS_ISR_SP_SAVE)
	; Accepting the interrupt cleared IFF1 and IFF2 and RETI does not set them;
	; EI's one-instruction delay keeps RETI from nesting.
	ei
	reti

; Any vector no BIOS device is programmed to supply.
irq_unexpected:
	ei
	reti

; ---------------------------------------------------------------------------
; irq_register -- BDOS facade function ZEXT_REGISTER_ISR.
; In:  B = source, 0-3 for CTC channel 0-3.  DE = callback entry.
; Out: A = 00h registered.
;      A = FFh refused: no such source, callback outside E000h-E3FFh, or the
;          source is already registered.
; Clobbers: F, HL.  The slot is written with interrupts masked; the caller's
; interrupt state is restored.
; The program programs the channel itself afterwards, and must not write the
; CTC vector byte: the BIOS owns it.
; ---------------------------------------------------------------------------
irq_register:
	call irq_slot_for_b
	jr nz,irq_refuse
	ld a,d
	and #0xfc
	cp #(PROGRAM_ISR_AREA >> 8)
	jr nz,irq_refuse
	ld a,(hl)
	inc hl
	or (hl)
	dec hl
	jr nz,irq_refuse
	ld a,i
	jp pe,irq_register_iff
	ld a,i
irq_register_iff:
	push af
	di
	ld (hl),e
	inc hl
	ld (hl),d
	jr irq_restore_ok

irq_refuse:
	ld a,#0xff
	ret

; ---------------------------------------------------------------------------
; irq_unregister -- BDOS facade function ZEXT_UNREGISTER_ISR.
; In:  B = source.
; Out: A = 00h: channel reset and slot cleared; A = FFh: no such source.
; Clobbers: F, HL.
; ---------------------------------------------------------------------------
irq_unregister:
	call irq_slot_for_b
	jr nz,irq_refuse
	ld a,i
	jp pe,irq_unregister_iff
	ld a,i
irq_unregister_iff:
	push af
	di
	ld a,b
	call irq_stop_channel
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
irq_restore_ok:
	pop af
	ld a,#0x00			; LD leaves P/V alone
	ret po
	ei
	ret

; ---------------------------------------------------------------------------
; irq_program_exit -- BDOS facade function ZEXT_PROGRAM_EXIT.
; Stops every registered channel and clears its slot.  ZCPR2 calls it when a
; transient returns, because that path never reaches WBOOT (plan F5).
; Out: A = 00h.  Clobbers: F, BC, HL.
; ---------------------------------------------------------------------------
irq_program_exit:
	ld a,i
	jp pe,irq_exit_iff
	ld a,i
irq_exit_iff:
	push af
	di
	ld hl,#irq_ctc_slots
	ld b,#0
irq_exit_loop:
	ld a,(hl)
	inc hl
	or (hl)
	jr z,irq_exit_next
	ld (hl),#0
	dec hl
	ld (hl),#0
	inc hl
	ld a,b
	call irq_stop_channel
irq_exit_next:
	inc hl
	inc b
	ld a,b
	cp #IRQ_SOURCE_COUNT
	jr c,irq_exit_loop
	jr irq_restore_ok

; ---------------------------------------------------------------------------
; irq_reset -- clear every registration.  Cold boot and WBOOT, with interrupts
; already disabled and the CTC already reset by ctc_disable_interrupts.
; Clobbers: AF, B, HL.
; ---------------------------------------------------------------------------
irq_reset:
	ld hl,#irq_ctc_slots
	ld b,#IRQ_SOURCE_COUNT * 2
	xor a
irq_reset_loop:
	ld (hl),a
	inc hl
	djnz irq_reset_loop
	ret

; HL = slot for source B.  Z if B is a registerable source.  Preserves BC, DE.
irq_slot_for_b:
	ld a,b
	cp #IRQ_SOURCE_COUNT
	jr nc,irq_slot_bad
	add a,a
	ld l,a
	ld h,#0
	push de
	ld de,#irq_ctc_slots
	add hl,de
	pop de
	xor a
	ret
irq_slot_bad:
	or #0x01
	ret

; A = channel.  Reset it with its interrupt disabled.  Preserves BC.
irq_stop_channel:
	push bc
	add a,#CTC0_CTRL
	ld c,a
	ld a,#CTC_RESET_DISABLE
	out (c),a
	pop bc
	ret

; Callback entry per CTC channel; zero means unregistered.
irq_ctc_slots:
	.dw 0,0,0,0

IRQ_CODE_END:

	.ifgt (IRQ_CODE_END - IRQ_CODE_START) - (CBIOS_IRQ_CODE_LIMIT - CBIOS_IRQ_CODE_BASE)
	.error 1			; interrupt code overflows its region
	.endif

; ---------------------------------------------------------------------------
; The IM2 vector page.  A full 256 bytes, so a vector from an unprogrammed or
; future device is harmless.  The BIOS programs the CTC vector base
; (CTC_VECTOR_BASE, in ctc_disable_interrupts) and SIO0/B WR2 (CBIOS_SIO_VECTOR,
; in sio_core_enable_interrupts).
; ---------------------------------------------------------------------------
	.area CODE (ABS)
	.org CBIOS_IM2_VECTOR_TABLE

IM2_VECTOR_TABLE_START:
	.dw ctc0_isr			; 00h  CTC channel 0
	.dw ctc1_isr			; 02h  CTC channel 1
	.dw ctc2_isr			; 04h  CTC channel 2
	.dw ctc3_isr			; 06h  CTC channel 3
	.rept 4
	.dw irq_unexpected		; 08h-0Eh
	.endm
	.rept 8
	.dw xing_isr			; 10h-1Eh  SIO0: 10h is live; the rest
	.endm				;          cover status-affects-vector
	.rept 112
	.dw irq_unexpected		; 20h-FEh
	.endm
IM2_VECTOR_TABLE_END:

	.ifne (IM2_VECTOR_TABLE_END - IM2_VECTOR_TABLE_START) - CBIOS_IM2_VECTOR_SIZE
	.error 1			; the vector page must be exactly 256 bytes
	.endif
	.ifne CTC_VECTOR_BASE
	.error 1			; the page above assumes CTC vectors at 00h-06h
	.endif
	.ifne CBIOS_SIO_VECTOR - 0x10
	.error 1			; the page above assumes the SIO vector is 10h
	.endif
