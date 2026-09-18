; IRQ core: CPU interrupt policy, full context, IM2 and source ownership.
; User callbacks live in E000h-E3FFh; kernel callbacks live in common BIOS.
; All callbacks return with RET, never enable interrupts or call BDOS, and
; must be bounded. AF/BC/DE/HL/IX/IY and both alternate sets are preserved.
; I, IM and interrupt policy remain core-owned. No NMI service is installed.

	.globl irq_init,irq_reset,irq_register,irq_register_kernel,irq_unregister
	.globl irq_unregister_kernel,irq_program_exit,irq_save_disable,irq_restore,irq_disable,irq_enable
	.globl xing_isr
	.area CODE (ABS)
	.org CBIOS_IRQ_CODE_BASE
IRQ_CODE_START:

; Hardware entry: only the CPU's return PC lands on the foreground stack.
; IFF1/IFF2 are already clear. No callback/helper may enable interrupts.
ctc0_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	xor a
	jr irq_dispatch
ctc1_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#1
	jr irq_dispatch
ctc2_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#2
	jr irq_dispatch
ctc3_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#3
	jr irq_dispatch
xing_isr:
	ld (CBIOS_ISR_SP_SAVE),sp
	ld sp,#CBIOS_ISR_STACK_TOP
	push af
	ld a,#IRQ_SOURCE_SIO0
irq_dispatch:
	push bc
	push de
	push hl
	push ix
	push iy
	ex af,af'
	push af
	ex af,af'
	exx
	push bc
	push de
	push hl
	exx
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
	jr z,irq_unowned
	ld de,#irq_isr_done
	push de
	jp (hl)
irq_unowned:
	ld a,c
	cp #IRQ_SOURCE_COUNT
	call c,ctc_stop_channel
irq_isr_done:
	exx
	pop hl
	pop de
	pop bc
	exx
	ex af,af'
	pop af
	ex af,af'
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ld sp,(CBIOS_ISR_SP_SAVE)
irq_unexpected:
	ei
	reti

; Boot only, IRQs already masked. Reinstalls IM2 without changing enables.
; Clobbers AF. No traffic, no wait; not a callback API.
irq_init:
	ld a,#CBIOS_IM2_VECTOR_PAGE
	ld i,a
	im 2
	ret

; User slots are cleared at cold/WBOOT. Kernel ownership survives WBOOT's
; screen hold, so the existing SIO sink can still receive its dismissal key.
; In: IRQs masked. Clobbers AF/B/HL; bounded, no traffic.
irq_reset:
	ld hl,#irq_ctc_slots
	ld b,#IRQ_SOURCE_COUNT * 2
	xor a
irq_reset_loop:
	ld (hl),a
	inc hl
	djnz irq_reset_loop
	ret
irq_ctc_slots:
	.dw 0,0,0,0
irq_sio_slot:
	.dw 0

; Keep the floating FFh vector target fixed, independent of code growth.
	.ifgt (. - IRQ_CODE_START) - 0xc7
	.error 1
	.endif
	.ds 0xc7 - (. - IRQ_CODE_START)
irq_ff_unexpected:
	jp irq_unexpected

; PROGRAM_EXIT also returns the application-owned serial channel to CP/M.
; In: any IFF. Out: A=0. Clobbers F/BC/HL. Foreground only, no traffic.
irq_program_exit:
	call irq_save_disable
	push af
	ld b,#0
irq_exit_loop:
	call irq_unregister
	inc b
	ld a,b
	cp #IRQ_SOURCE_COUNT
	jr c,irq_exit_loop
	call sio0a_quiesce
	pop af
	call irq_restore
	xor a
	ret
; Boot ownership transition; caller has masked IRQs and installed its stack.
; Clobbers AF/B/HL, no traffic or wait. Delegates device-local reset to drivers.
irq_boot_prepare:
	call irq_init
	call irq_reset
	call ctc_disable_interrupts
	jp sio0a_quiesce
IRQ_CODE_END:
	.ifgt (IRQ_CODE_END - IRQ_CODE_START) - (CBIOS_IRQ_CODE_LIMIT - CBIOS_IRQ_CODE_BASE)
	.error 1
	.endif

; CPU-global policy helpers in previously unallocated common memory.
	.org CBIOS_IRQ_POLICY_BASE
IRQ_POLICY_START:
; In: any IFF. Out: A=0 (disabled) or 1 (enabled), IRQs disabled.
; Clobbers AF only. Nestable: each caller retains its own token. Bounded,
; no device traffic; ISR-safe (token is zero inside a maskable ISR).
; Retry the NMOS LD A,I false-negative window once, as in the old facade.
irq_save_disable:
	ld a,i
	jp pe,irq_save_known
	ld a,i
irq_save_known:
	di
	ld a,#0
	ret po
	inc a
	ret
; In: A=token. Clobbers F only. No wait/traffic. ISR callers must use only
; their own zero token; never pass an enabled foreground token from an ISR.
irq_restore:
	di
	or a
	ret z
irq_enable:
	ei
	ret
irq_disable:
	di
	ret

; Stackless boot entries: policy remains here even before a valid SP exists.
irq_rom_entry:
	di
	jp rom_copy_masked
irq_boot_entry:
	di
	jp boot_masked
irq_wboot_entry:
	di
	jp wboot_masked
irq_wbtrap_entry:
	di
	jp trap_masked

; Polling sink call: caller already saved BC/DE/HL and masked IRQs.
; Preserve index/alternate context even though no hardware ISR frame exists.
irq_sink_context:
	push ix
	push iy
	ex af,af'
	push af
	ex af,af'
	exx
	push bc
	push de
	push hl
	exx
	call SIO_RX_KICK_READ
	exx
	pop hl
	pop de
	pop bc
	exx
	ex af,af'
	pop af
	ex af,af'
	pop iy
	pop ix
	ret
IRQ_POLICY_END:
	.ifgt (IRQ_POLICY_END - IRQ_POLICY_START) - (CBIOS_IRQ_POLICY_LIMIT - CBIOS_IRQ_POLICY_BASE)
	.error 1
	.endif

	.org CBIOS_IRQ_REG_BASE
IRQ_REG_START:
; Public user API, unchanged: B=CTC source 0..3, DE=E000h-E3FFh entry.
; Out: A=0 or FFh. Preserves BC/DE, clobbers F/HL. No wait/traffic.
irq_register:
	ld a,b
	cp #IRQ_SOURCE_COUNT
	jr nc,irq_refuse
	ld a,d
	and #0xfc
	cp #(PROGRAM_ISR_AREA >> 8)
	jr nz,irq_refuse
	jr irq_register_slot
; Private kernel API: only SIO0, entry in resident BIOS code F000h-F957h.
; Trusted kernel may rebind its slot after SIO reinitialization. Atomic install
; uses the same slot mechanism. Not exposed through BDOS.
irq_register_kernel:
	ld a,b
	cp #IRQ_SOURCE_SIO0
	jr nz,irq_refuse
	ld a,d
	cp #(CBIOS_BASE >> 8)
	jr c,irq_refuse
	cp #(FAC_BULK_BUF >> 8)
	jr c,irq_kernel_slot
	jr nz,irq_refuse
	ld a,e
	cp #(FAC_BULK_BUF & 0xff)
	jr nc,irq_refuse
irq_kernel_slot:
	call irq_slot_for_b
	call irq_save_disable
	push af
	jr irq_write_slot
irq_register_slot:
	call irq_slot_for_b
	call irq_save_disable
	push af
	ld a,(hl)
	inc hl
	or (hl)
	dec hl
	jr nz,irq_register_busy
irq_write_slot:
	ld (hl),e
	inc hl
	ld (hl),d
	jr irq_restore_ok
irq_register_busy:
	pop af
	call irq_restore
irq_refuse:
	ld a,#0xff
	ret

; Private kernel unregister: B=SIO0; driver must mask its local sources first.
; Same atomic clear and caller-IFF restoration as user removal. No traffic/wait.
irq_unregister_kernel:
	ld a,b
	cp #IRQ_SOURCE_SIO0
	jr nz,irq_refuse
	call irq_slot_for_b
	call irq_save_disable
	push af
	jr irq_clear_slot

; User unregister: B=0..3. Stops the mapped hardware channel before clearing
; its callback. Preserves BC/DE, clobbers AF/HL, restores caller's IFF.
irq_unregister:
	ld a,b
	cp #IRQ_SOURCE_COUNT
	jr nc,irq_refuse
	call irq_slot_for_b
	call irq_save_disable
	push af
	ld a,b
	call ctc_stop_channel
irq_clear_slot:
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
irq_restore_ok:
	pop af
	call irq_restore
	xor a
	ret
irq_slot_for_b:
	ld a,b
	add a,a
	ld l,a
	ld h,#0
	push de
	ld de,#irq_ctc_slots
	add hl,de
	pop de
	ret
IRQ_REG_END:
	.ifgt (IRQ_REG_END - IRQ_REG_START) - (CBIOS_IRQ_REG_LIMIT - CBIOS_IRQ_REG_BASE)
	.error 1
	.endif

	.org CBIOS_IM2_VECTOR_TABLE
IM2_VECTOR_TABLE_START:
	.dw ctc0_isr,ctc1_isr,ctc2_isr,ctc3_isr
	.rept 4
	.dw irq_unexpected
	.endm
	.rept 8
	.dw xing_isr
	.endm
	.rept 112
	.dw irq_unexpected
	.endm
IM2_VECTOR_TABLE_END:
	.ifne (IM2_VECTOR_TABLE_END - IM2_VECTOR_TABLE_START) - CBIOS_IM2_VECTOR_SIZE
	.error 1
	.endif
; The high byte of every trailing default entry must remain F7h for FFh.
	.ifne ((irq_unexpected - IRQ_CODE_START + (CBIOS_IRQ_CODE_BASE & 0xff)) / 256)
	.error 1
	.endif
