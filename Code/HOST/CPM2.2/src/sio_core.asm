; Zephyr-80 BIOS-owned Z80 SIO core.
;
; SIO is platform plumbing. Console, storage, and future protocols are clients.
; This module owns the BIOS-facing SIO hardware boundary:
;   - SIO0/B async setup for the legacy serial console path,
;   - SIO interrupt enable/disable,
;   - IM2 table/trampoline/ISR for the current SIO-only build,
;   - one RX byte sink per BIOS-owned SIO channel,
;   - blocking send-byte service used by client drivers.
;
; Ownership rules:
;   BIOS owns SIO0/B and the future SIO1 IO Controller transport.
;   Applications own SIO0/A. This code does not configure SIO0/A as a channel.
;   The SIO WR9 master interrupt bit is still reached through the SIO0/A
;   control port, which is a hardware limitation of the Z80 SIO.
;   CTC remains application-owned and is not required by this module.
;
; Future SIO1 plan:
;   SIO_CH_IOCTRL is reserved for an IO Controller MCU link. That future link
;   will use SIO1 in synchronous mode with the MCU as synchronous master and
;   will carry command/event packets for IOCALL, Virtual Drip console/storage,
;   HID/keyboard, and reset/status control. No packet protocol or SIO1 sync
;   setup is implemented here yet.

	.globl sio_init
	.globl sio_core_init,sio_core_enable_interrupts,sio_core_disable_interrupts
	.globl sio_register_rx_sink,sio_send_byte,sio_rx_kick
	.globl sio_core_rx_lock,sio_core_rx_unlock,sio_core_isr,sio_console_isr
	.globl CONIRQ,sio_console_enable_interrupts,sio_console_disable_interrupts
	.globl SIO_CORE_CODE_START,SIO_CORE_CODE_END
	.globl SIO_CORE_STATE_START,SIO_CORE_STATE_END
	.globl SIO0B_RX_SINK,SIO1_RX_SINK
	.globl SIO_CORE_IRQ_ENABLED,SIO_CORE_IRQ_COUNT
	.globl CONSOLE_IRQ_ENABLED,CONSOLE_IRQ_COUNT
	.globl CONSOLE_IM2_VECTOR_ENTRY
	.globl CONSOLE_IM2_VECTOR_TABLE_START,CONSOLE_IM2_VECTOR_TABLE_END

SIO0B_DATA_PORT		= SIOB_DATA
SIO0B_CTRL_PORT		= SIOB_CTRL
SIO_MASTER_CTRL_PORT	= SIOA_CTRL
SIO_RX_READY		= RR0_RX_AVAILABLE
SIO_TX_READY		= RR0_TX_EMPTY

	.area CODE (ABS)
	.org CBIOS_IM2_VECTOR_TABLE

; SIO-core-owned IM2 repeated-byte table.
; Purpose:
;   Provide the low/high bytes that the Z80 fetches in interrupt mode 2.
; Inputs:
;   I = CBIOS_IM2_VECTOR_PAGE and SIO0/B WR2 = CBIOS_SIO_VECTOR.
; Outputs:
;   The CPU reads E4h/E4h from E500h/E501h and vectors to E4E4h.
; Important invariants:
;   This table is exactly 256 bytes and ends at the exclusive label E600h.
;   A 257th byte would cross from slot 1 into slot 2; future FF-vector-safe
;   hardware may need a different global IM2 layout.
CONSOLE_IM2_VECTOR_TABLE_START:
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	.db CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE,CBIOS_IM2_VECTOR_BYTE
	; No 257th byte is emitted here. With SIO0/B WR2 forced to 00h, the CPU
	; uses E500h/E501h and never indexes the E5FFh/E600h pair for this device.
CONSOLE_IM2_VECTOR_TABLE_END:

	.area CODE (ABS)
	.org CBIOS_SIO_CORE_CODE_BASE

SIO_CORE_CODE_START:

; Compatibility entry kept for existing boot/source references.
sio_init:
	jp sio_core_init

; Initialize BIOS-owned SIO services.
; Purpose:
;   Set up SIO0/B for the existing async console path, clear registered sinks,
;   and leave BIOS-owned SIO interrupts disabled.
; Inputs: none.
; Outputs:
;   SIO0/B is configured 115200 8N1 with WR1 interrupts disabled.
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

	jp sio_core_disable_interrupts

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
;   Clear SIO0/B WR1 interrupt enables, clear SIO master interrupt enable, and
;   mark SIO IRQ mode inactive for foreground ring-buffer lock helpers.
; Outputs:
;   SIO_CORE_IRQ_ENABLED = 0, A = BIOS_OK.
; Clobbers: AF.
sio_core_disable_interrupts:
	di
	ld a,#0x01
	out (SIO0B_CTRL_PORT),a
	xor a
	out (SIO0B_CTRL_PORT),a
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
; Out: A = BIOS_OK / BIOS_ERR.
; Current behavior:
;   SIO_CH_CONSOLE performs the same blocking/polled SIO0/B transmit that the
;   legacy console used before this split. SIO_CH_IOCTRL is reserved and returns
;   BIOS_ERR until SIO1 sync mode exists.
sio_send_byte:
	cp #SIO_CH_CONSOLE
	jr z,SIO_SEND_CONSOLE
	ld a,#BIOS_ERR
	ret
SIO_SEND_CONSOLE:
	in a,(SIO0B_CTRL_PORT)
	and #SIO_TX_READY
	jr z,SIO_SEND_CONSOLE
	ld a,c
	out (SIO0B_DATA_PORT),a
	xor a
	ret

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

; Compatibility label for older symbol maps and diagnostics. The real ISR entry
; is sio_core_isr; the IM2 trampoline jumps there directly.
sio_console_isr:
	jp sio_core_isr

SIO_CORE_CODE_END:

	.area CODE (ABS)
	.org CBIOS_IM2_VECTOR_ENTRY
; Transitional IM2 trampoline inside slot 1. The SIO core owns this logically
; even though it remains in the same fixed slot as the legacy console client.
CONSOLE_IM2_VECTOR_ENTRY:
	jp sio_core_isr

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
