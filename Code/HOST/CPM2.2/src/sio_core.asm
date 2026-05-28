; Zephyr-80 BIOS-owned Z80 SIO core.
;
; SIO is platform plumbing. Console, storage, and future protocols are clients.
; This module owns the BIOS-facing SIO hardware boundary:
;   - SIO0/B async setup for the legacy serial console path,
;   - SIO1/A synchronous setup for the IO Controller transaction link,
;   - SIO interrupt enable/disable,
;   - IM2 table/trampoline/ISR for the current SIO-only build,
;   - one RX byte sink per BIOS-owned SIO channel,
;   - blocking byte I/O services used by client drivers.
;
; Ownership rules:
;   BIOS owns SIO0/B and the SIO1/A IO Controller transport.
;   Applications own SIO0/A. This code does not configure SIO0/A as a channel.
;   The SIO WR9 master interrupt bit is still reached through the SIO0/A
;   control port, which is a hardware limitation of the Z80 SIO.
;   CTC remains application-owned and is not required by this module.
;
; SIO1 IO Controller link:
;   SIO_CH_IOCTRL uses SIO1/A in synchronous external-clock/external-sync mode.
;   The IO Controller MCU owns the clock and framing. RTS from the Z80 side is
;   a service-request signal and starts inactive.

	.globl sio_init
	.globl sio_core_init,sio_core_enable_interrupts,sio_core_disable_interrupts
	.globl sio_register_rx_sink,sio_send_byte,sio_recv_byte,sio_rx_kick
	.globl sio1_ioc_init,sio1_ioc_rts_assert,sio1_ioc_rts_release
	.globl sio1_ioc_put_byte,sio1_ioc_get_byte
	.globl sio_core_rx_lock,sio_core_rx_unlock,sio_core_isr,sio_console_isr
	.globl CONIRQ,sio_console_enable_interrupts,sio_console_disable_interrupts
	.globl SIO_CORE_CODE_START,SIO_CORE_CODE_END,BIOS_CODE_END
	.globl SIO_CORE_STATE_START,SIO_CORE_STATE_END
	.globl SIO0B_RX_SINK,SIO1_RX_SINK
	.globl SIO_CORE_IRQ_ENABLED,SIO_CORE_IRQ_COUNT
	.globl CONSOLE_IRQ_ENABLED,CONSOLE_IRQ_COUNT
	.globl CONSOLE_IM2_VECTOR_ENTRY
	.globl CONSOLE_IM2_VECTOR_TABLE_START,CONSOLE_IM2_VECTOR_TABLE_END

SIO0B_DATA_PORT		= SIOB_DATA
SIO0B_CTRL_PORT		= SIOB_CTRL
SIO1_IOC_DATA_PORT	= SIO1A_DATA
SIO1_IOC_CTRL_PORT	= SIO1A_CTRL
SIO_MASTER_CTRL_PORT	= SIOA_CTRL
SIO_RX_READY		= RR0_RX_AVAILABLE
SIO_TX_READY		= RR0_TX_EMPTY
SIO_IOCTRL_TIMEOUT	= 0xffff
SIO_WR4_IOCTRL_SYNC	= 0x30
SIO_WR3_IOCTRL_RX	= 0xd1
SIO_WR5_IOCTRL_RTS_OFF	= 0xe8
SIO_WR5_IOCTRL_RTS_ON	= 0xea

	.area CODE (ABS)
	.org CBIOS_SIO_CORE_CODE_BASE

SIO_CORE_CODE_START:

; SIO-core-owned exact IM2 table entry.
; Purpose:
;   Provide the exact ISR address that the Z80 fetches in interrupt mode 2.
; Inputs:
;   I = CBIOS_IM2_VECTOR_PAGE and SIO0/B WR2 = CBIOS_SIO_VECTOR.
; Outputs:
;   The CPU reads this word and vectors directly to sio_core_isr.
; Important invariants:
;   SIO0/B WR1 status-affects-vector must remain disabled so WR2 selects this
;   exact two-byte table entry.
CONSOLE_IM2_VECTOR_TABLE_START:
CONSOLE_IM2_VECTOR_ENTRY:
	.dw sio_core_isr
CONSOLE_IM2_VECTOR_TABLE_END:

; Compatibility entry kept for existing boot/source references.
sio_init:
	jp sio_core_init

; Initialize BIOS-owned SIO services.
; Purpose:
;   Set up SIO0/B for the existing async console path, set up SIO1/A for the
;   synchronous IO Controller link, clear registered sinks, and leave
;   BIOS-owned SIO interrupts disabled.
; Inputs: none.
; Outputs:
;   SIO0/B is configured 115200 8N1 with WR1 interrupts disabled. SIO1/A is
;   configured synchronous 8-bit, external clock/sync, no parity/CRC, no IRQs,
;   and RTS inactive.
; Clobbers: AF.
; Important invariants:
;   This does not configure application-owned SIO0/A as a channel and does not
;   require or program the CTC.
sio_core_init:
	xor a
	ld (SIO0B_RX_SINK),a
	ld (SIO0B_RX_SINK + 1),a
	ld (SIO1_RX_SINK),a
	ld (SIO1_RX_SINK + 1),a

	; WR0: channel reset.
	ld a,#0x18
	out (SIO0B_CTRL_PORT),a

	; WR4: x16 clock, 1 stop bit, no parity.
	ld a,#0x04
	out (SIO0B_CTRL_PORT),a
	ld a,#0x44
	out (SIO0B_CTRL_PORT),a

	; WR3: RX enable, 8-bit RX, Auto Enables off.
	ld a,#0x03
	out (SIO0B_CTRL_PORT),a
	ld a,#0xc1
	out (SIO0B_CTRL_PORT),a

	; WR5: DTR, 8-bit TX, TX enable, RTS.
	ld a,#0x05
	out (SIO0B_CTRL_PORT),a
	ld a,#0xea
	out (SIO0B_CTRL_PORT),a

	call sio1_ioc_init
	jp sio_core_disable_interrupts

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
	; WR9: SIO1 master interrupts disabled.
	ld a,#0x09
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

CONIRQ:
	or a
	jp z,sio_core_disable_interrupts

; Compatibility aliases kept for the legacy console boot path.
sio_console_enable_interrupts:
	jp sio_core_enable_interrupts
sio_console_disable_interrupts:
	jp sio_core_disable_interrupts

; Enable BIOS-owned SIO interrupts.
; Purpose:
;   Program the Z80 for IM2, program SIO0/B WR2 with vector 00h, enable SIO0/B
;   receive interrupts, and enable the SIO master interrupt bit.
; Outputs:
;   SIO_CORE_IRQ_ENABLED = 1, SIO_CORE_IRQ_COUNT = 0, A = BIOS_OK.
; Clobbers: AF.
sio_core_enable_interrupts:
	di
	ld a,#CBIOS_IM2_VECTOR_PAGE
	ld i,a
	im 2

	ld a,#0x02
	out (SIO0B_CTRL_PORT),a
	ld a,#CBIOS_SIO_VECTOR
	out (SIO0B_CTRL_PORT),a

	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (SIO0B_CTRL_PORT),a
	ld a,#0x01
	out (SIO0B_CTRL_PORT),a
	ld a,#SIO_WR1_RX_INT_ALL
	out (SIO0B_CTRL_PORT),a
	ld a,#0x09
	out (SIO_MASTER_CTRL_PORT),a
	ld a,#SIO_WR9_MIE
	out (SIO_MASTER_CTRL_PORT),a
	xor a
	ld (SIO_CORE_IRQ_COUNT),a
	ld (SIO_CORE_IRQ_COUNT + 1),a
	ld a,#0x01
	ld (SIO_CORE_IRQ_ENABLED),a
	ei
	xor a
	ret

; Disable BIOS-owned SIO interrupts.
; Purpose:
;   Clear SIO0/B and SIO1/A WR1 interrupt enables, clear SIO master interrupt
;   enable, and mark SIO IRQ mode inactive for foreground ring-buffer lock
;   helpers.
; Outputs:
;   SIO_CORE_IRQ_ENABLED = 0, A = BIOS_OK.
; Clobbers: AF.
sio_core_disable_interrupts:
	di
	ld a,#0x01
	out (SIO0B_CTRL_PORT),a
	xor a
	out (SIO0B_CTRL_PORT),a
	ld a,#0x01
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#0x09
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#0x09
	out (SIO_MASTER_CTRL_PORT),a
	xor a
	out (SIO_MASTER_CTRL_PORT),a
	ld (SIO_CORE_IRQ_ENABLED),a
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
;   Register preservation:
;     The callback may clobber AF/BC/DE/HL. The ISR preserves those registers
;     around the whole interrupt frame.
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

; Send one byte on a BIOS-owned SIO channel.
; In:  A = SIO channel id, C = byte to send.
; Out: A = BIOS_OK / BIOS_ERR_*.
; Current behavior:
;   SIO_CH_CONSOLE preserves the existing blocking/polled SIO0/B transmit path.
;   SIO_CH_IOCTRL polls SIO1/A with a finite timeout because the MCU only
;   clocks the synchronous link during an active transaction.
sio_send_byte:
	cp #SIO_CH_CONSOLE
	jr z,SIO_SEND_CONSOLE
	cp #SIO_CH_IOCTRL
	jr z,SIO_SEND_IOCTRL
	ld a,#BIOS_ERR_IO
	ret
SIO_SEND_CONSOLE:
	in a,(SIO0B_CTRL_PORT)
	and #SIO_TX_READY
	jr z,SIO_SEND_CONSOLE
	ld a,c
	out (SIO0B_DATA_PORT),a
	xor a
	ret
SIO_SEND_IOCTRL:
	ld de,#SIO_IOCTRL_TIMEOUT
SIO_SEND_IOCTRL_WAIT:
	in a,(SIO1_IOC_CTRL_PORT)
	and #SIO_TX_READY
	jr nz,SIO_SEND_IOCTRL_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_SEND_IOCTRL_WAIT
	ld a,#BIOS_ERR_TIMEOUT
	ret
SIO_SEND_IOCTRL_READY:
	ld a,c
	out (SIO1_IOC_DATA_PORT),a
	xor a
	ret

; Receive one byte from a BIOS-owned SIO channel.
; In:  A = SIO channel id.
; Out: A = BIOS_OK / BIOS_ERR_*, C = byte when A = BIOS_OK.
sio_recv_byte:
	cp #SIO_CH_IOCTRL
	jr z,SIO_RECV_IOCTRL
	ld a,#BIOS_ERR_IO
	ret
SIO_RECV_IOCTRL:
	ld de,#SIO_IOCTRL_TIMEOUT
SIO_RECV_IOCTRL_WAIT:
	in a,(SIO1_IOC_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,SIO_RECV_IOCTRL_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_RECV_IOCTRL_WAIT
	ld a,#BIOS_ERR_TIMEOUT
	ret
SIO_RECV_IOCTRL_READY:
	in a,(SIO1_IOC_DATA_PORT)
	ld c,a
	xor a
	ret

; SIO1 IO Controller low-level helpers. These are intentionally thin wrappers
; over the generic SIO channel APIs so protocol code does not touch console
; routines or SIO hardware ports directly.
sio1_ioc_rts_assert:
	ld a,#0x05
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#SIO_WR5_IOCTRL_RTS_ON
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	ret

sio1_ioc_rts_release:
	ld a,#0x05
	out (SIO1_IOC_CTRL_PORT),a
	ld a,#SIO_WR5_IOCTRL_RTS_OFF
	out (SIO1_IOC_CTRL_PORT),a
	xor a
	ret

sio1_ioc_put_byte:
	ld a,#SIO_CH_IOCTRL
	jp sio_send_byte

sio1_ioc_get_byte:
	ld a,#SIO_CH_IOCTRL
	jp sio_recv_byte

; Optional foreground RX kick.
; In:  A = SIO channel id.
; Out: A = BIOS_OK / BIOS_ERR.
; Purpose:
;   Catch a byte already pending before interrupts are enabled or while the
;   foreground temporarily owns the console driver's RX ring.
; Clobbers:
;   AF only. If a byte is dispatched, BC/DE/HL are preserved around the sink
;   callback so CP/M callers and direct-BIOS tools do not lose live state.
sio_rx_kick:
	cp #SIO_CH_CONSOLE
	jr z,SIO_RX_KICK_CONSOLE
	cp #SIO_CH_IOCTRL
	jr z,SIO_RX_KICK_NOOP
	ld a,#BIOS_ERR
	ret
SIO_RX_KICK_NOOP:
	xor a
	ret
SIO_RX_KICK_CONSOLE:
	call sio_core_rx_lock
	in a,(SIO0B_CTRL_PORT)
	and #SIO_RX_READY
	jr z,SIO_RX_KICK_DONE
	push bc
	push de
	push hl
	in a,(SIO0B_DATA_PORT)
	ld c,a
	ld a,#SIO_CH_CONSOLE
	call sio_core_dispatch_rx
	pop hl
	pop de
	pop bc
SIO_RX_KICK_DONE:
	call sio_core_rx_unlock
	xor a
	ret

; Foreground helpers for clients that update RX buffers also touched by sinks.
sio_core_rx_lock:
	ld a,(SIO_CORE_IRQ_ENABLED)
	or a
	ret z
	di
	ret

sio_core_rx_unlock:
	ld a,(SIO_CORE_IRQ_ENABLED)
	or a
	ret z
	ei
	ret

; SIO interrupt service routine.
; Purpose:
;   Handle BIOS-owned SIO interrupt work and dispatch received bytes to the
;   registered channel sink. Today only SIO_CH_CONSOLE / SIO0/B is active.
; Outputs:
;   SIO_CORE_IRQ_COUNT increments; RX bytes are dispatched if a sink exists.
; Important invariants:
;   The ISR is short, never calls BDOS, does not block, does not switch banks,
;   resets highest IUS, and returns with RETI.
sio_core_isr:
	push af
	push bc
	push de
	push hl

	ld hl,(SIO_CORE_IRQ_COUNT)
	inc hl
	ld (SIO_CORE_IRQ_COUNT),hl

	in a,(SIO0B_CTRL_PORT)
	ld b,a
	and #SIO_RX_READY
	jr z,SIO_CORE_ISR_DONE
	in a,(SIO0B_DATA_PORT)
	ld c,a
	ld a,#SIO_CH_CONSOLE
	call sio_core_dispatch_rx

SIO_CORE_ISR_DONE:
	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (SIO0B_CTRL_PORT),a
	pop hl
	pop de
	pop bc
	pop af
	reti

; Dispatch one received byte to the registered sink.
; In: A = SIO channel id, C = received byte.
; Out: A = BIOS_OK / BIOS_ERR.
sio_core_dispatch_rx:
	cp #SIO_CH_CONSOLE
	jr z,SIO_DISPATCH_CONSOLE
	cp #SIO_CH_IOCTRL
	jr z,SIO_DISPATCH_IOCTRL
	ld a,#BIOS_ERR
	ret
SIO_DISPATCH_CONSOLE:
	ld hl,(SIO0B_RX_SINK)
	ld a,#SIO_CH_CONSOLE
	jr SIO_DISPATCH_HAVE
SIO_DISPATCH_IOCTRL:
	ld hl,(SIO1_RX_SINK)
	ld a,#SIO_CH_IOCTRL
SIO_DISPATCH_HAVE:
	ld d,h
	ld e,l
	ld h,d
	ld l,e
	ld d,a
	ld a,h
	or l
	jr z,SIO_DISPATCH_NO_SINK
	ld a,d
	ld de,#SIO_DISPATCH_RETURN
	push de
	jp (hl)
SIO_DISPATCH_RETURN:
	xor a
	ret
SIO_DISPATCH_NO_SINK:
	xor a
	ret

; Compatibility label for older symbol maps and diagnostics. The exact IM2
; table entry points at sio_core_isr directly.
sio_console_isr:
	jp sio_core_isr

SIO_CORE_CODE_END:
BIOS_CODE_END:

	.area WORK (ABS)
	.org CBIOS_SIO_CORE_WORK_AREA
SIO_CORE_STATE_START:
SIO0B_RX_SINK:
	.dw 0x0000
SIO1_RX_SINK:
	.dw 0x0000
SIO_CORE_IRQ_ENABLED:
CONSOLE_IRQ_ENABLED:
	.db 0x00
SIO_CORE_IRQ_COUNT:
CONSOLE_IRQ_COUNT:
	.dw 0x0000
SIO_CORE_STATE_END:

	.area CODE (ABS)
