; SIO: the bank-7 half.
; The common half -- what an interrupt reaches -- is in common/sio.asm.
; Split so that every source file belongs to exactly one memory class, which is
; what lets the build check a file's directory against the addresses it emits.


; ===========================================================================
; SIO services that do not need common memory
; ===========================================================================
;
; Bank 7.  These three are reached only from bank 7 or from boot after
; bank7_check, and no interrupt path reaches them, so nothing requires their
; addresses to be valid under more than one latch state.
;
; What stays in common, and why (docs/memory-model-implementation-plan.md,
; step 2.1):
;   sio_core_init                boot calls it BEFORE bank7_check
;   sio_core_disable_interrupts  sio_core_init tail-jumps into it
;   sio_send_byte                bank7_check's failure path emits through it
;   sio_rx_kick                  irq_sink_context re-enters its body
;   the ISR block                interrupt
;
; sio_core_enable_interrupts calls irq_save_disable / irq_register_kernel /
; irq_restore, which are in common and stay reachable from here: common is
; mapped in mode 11.

	.area CODE (ABS)
	.org CBIOS_SIO_BANK7_CODE_BASE

SIO_BANK7_CODE_START:


; Initialize SIO1/A for the BIOS-owned IO Controller link.
; Purpose:
;   Configure synchronous external-clock/external-sync operation. The MCU
;   provides clocks only during an active transaction, and RTS is held inactive
;   until IOCALL asserts it.
; Outputs: A = BIOS_OK.
; Clobbers: AF.
sio1_ioc_init:
	; WR0: channel reset.
	ld a,#0x18
	out (SIO1_IOC_CTRL_PORT),a

	; WR1: no interrupts or wait/DMA.
	ld a,#0x01
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	out (SIO1_IOC_CTRL_PORT),a

	; WR4: synchronous external sync, x1 clock, no parity.
	ld a,#0x04
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#SIO_WR4_IOCTRL_SYNC
	out (SIO1_IOC_CTRL_PORT),a

	; WR6/WR7 are unused in external-sync mode; clear sync/CRC bytes.
	ld a,#0x06
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#0x07
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	out (SIO1_IOC_CTRL_PORT),a

	; WR3: 8-bit RX, receiver enabled, enter hunt for external SYNC.
	ld a,#0x03
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#SIO_WR3_IOCTRL_RX
	out (SIO1_IOC_CTRL_PORT),a

	; WR5: 8-bit TX enabled, CRC/parity disabled, RTS inactive.
	ld a,#0x05
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#SIO_WR5_IOCTRL_RTS_OFF
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	ret

; Enable SIO0/B-local interrupts and register its common callback.
; In: any caller IFF. Out: A=BIOS_OK. Clobbers AF only. Bounded, no VDrip
; traffic. Foreground only; CPU IM2/I/global enable remain IRQ-core policy.
; WR1 requests every received character without parity-vector modification.
; Z80 SIO has WR0-WR7 only: 09h would select WR1 on channel A, not a
; chip-wide enable. Do not configure application-owned A here.
sio_core_enable_interrupts:
	call irq_save_disable
	push af
	push bc
	push de
	push hl
	ld b,#IRQ_SOURCE_SIO0
	ld de,#sio_core_isr
	call irq_register_kernel
	pop hl
	pop de
	pop bc

	ld a,#0x02
	out (SIO0B_CTRL_PORT),a
	ld a,#CBIOS_SIO_VECTOR
	out (SIO0B_CTRL_PORT),a

	; Reset Highest IUS / Return from Interrupt is issued through channel A.
	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (SIO_MASTER_CTRL_PORT),a
	ld a,#0x01
	out (SIO0B_CTRL_PORT),a
	; WR1 D4:D3 = 11b: RX interrupt on all received characters, with parity
	; status not affecting the interrupt vector.
	ld a,#SIO_WR1_RX_INT_ALL
	out (SIO0B_CTRL_PORT),a
	ld a,#0x01
	ld (SIO_CORE_IRQ_ENABLED),a
	pop af
	call irq_restore
	xor a
	ret

; Register one RX byte sink for a BIOS-owned SIO channel.
;
; RX sink callback contract:
;   In:
;     A = SIO channel id
;     C = received byte
;   Must:
;     return quickly, never call BDOS, never block, never perform disk I/O, and
;     never do heavy rendering. Recommended behavior is to enqueue C into the
;     owning driver's RX buffer, set a flag if needed, and return.
;   Register preservation: the IRQ core and foreground kick preserve all
;   main/index/alternate registers around sink execution.
;
; In:  A = SIO channel id, HL = callback address.
; Out: A = BIOS_OK / BIOS_ERR.
sio_register_rx_sink:
	cp #SIO_CH_CONSOLE
	jr z,SIO_REGISTER_CONSOLE
	cp #SIO_CH_IOCTRL
	jr z,SIO_REGISTER_IOCTRL
	ld a,#BIOS_ERR
	ret
SIO_REGISTER_CONSOLE:
	ld (SIO0B_RX_SINK),hl
	xor a
	ret
SIO_REGISTER_IOCTRL:
	ld (SIO1_RX_SINK),hl
	xor a
	ret

SIO_BANK7_CODE_END:

	.ifgt (SIO_BANK7_CODE_END - SIO_BANK7_CODE_START) - (CBIOS_SIO_BANK7_CODE_LIMIT - CBIOS_SIO_BANK7_CODE_BASE)
	.error 1			; bank-7 SIO services overflow their region
	.endif
