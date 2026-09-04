; Zephyr-80 BIOS-owned Z80 SIO core.
;
; This file is the BIOS hardware boundary for Z80 SIO devices. Higher-level
; clients, such as the Virtual Drip console driver and the IO Controller
; transport, register callbacks and call byte I/O helpers; they do not program
; SIO registers directly except through deliberately exposed low-level helpers.
;
; What this module owns:
;   - SIO0/B asynchronous setup for the console / Virtual Drip serial link.
;   - The SIO1/A synchronous setup entry used once by cold boot.
;   - IM2 setup for the current SIO RX interrupt path.
;   - The exact IM2 vector table word consumed by the Z80 during interrupt
;     acknowledge.
;   - SIO WR1/WR2/WR9 interrupt enable/disable for BIOS-owned channels.
;   - One registered RX byte sink per BIOS-owned channel.
;   - Foreground byte send/receive helpers for BIOS clients.
;
; Console channel map:
;   - Hardware channel: SIO0/B.
;   - Logical dispatch id: SIO_CH_CONSOLE.
;   - Data port: SIO0B_DATA_PORT.
;   - Control port: SIO0B_CTRL_PORT.
;   - Registered sink slot: SIO0B_RX_SINK.
;
; RX sink registration:
;   sio_register_rx_sink stores a callback address for a logical channel.
;   sio_core_dispatch_rx later calls that callback for each received byte.
;
; RX sink calling convention:
;   In:
;     A = SIO channel id, for example SIO_CH_CONSOLE.
;     C = received byte.
;   The registered sink may clobber AF/BC/DE/HL but MUST NOT clobber IX/IY. The
;   SIO ISR saves AF/BC/DE/HL before dispatching and restores them before RETI;
;   it does NOT save IX/IY (sio_core has no free ROM bytes for the extra
;   push/pop), so the sink contract forbids their use. This invariant holds
;   today: no sink-reachable code uses IX/IY, and the only IX user in the BIOS,
;   v9958_write_vram_small, saves/restores IX itself and is never reached from a
;   sink. Foreground sio_rx_kick likewise preserves BC/DE/HL (not IX/IY) around
;   the sink call for callers that may keep live values in those registers.
;
; Hardware RX interrupt path:
;     SIO receives byte
;     -> Z80 interrupt / IM2
;     -> sio_core_isr
;     -> check RR0 RX_READY
;     -> read SIO0B_DATA_PORT
;     -> C = received byte
;     -> A = SIO_CH_CONSOLE
;     -> sio_core_dispatch_rx
;     -> registered sink
;
; Foreground kick path:
;     caller calls sio_rx_kick
;     -> check RR0 RX_READY
;     -> read SIO0B_DATA_PORT
;     -> C = received byte
;     -> A = SIO_CH_CONSOLE
;     -> sio_core_dispatch_rx
;     -> registered sink
;
; Both paths intentionally converge at sio_core_dispatch_rx and therefore feed
; the same registered sink. During debugging, however, they prove different
; things. Bytes delivered through sio_rx_kick prove the parser/sink/FIFO path can
; work from foreground polling; they do not prove that SIO RX interrupts are
; configured, acknowledged, and dispatching bytes correctly.
;
; Ownership rules:
;   BIOS owns SIO0/B and the SIO1/A IO Controller transport.
;   Applications own SIO0/A. This code does not configure SIO0/A as a channel,
;   but it masks SIO0/A WR1 interrupts before enabling the chip-wide SIO0 WR9
;   master interrupt bit used by the SIO0/B console.
;   CTC remains application-owned and is not required by this module.
;
; SIO1 IO Controller link:
;   SIO_CH_IOCTRL uses SIO1/A in synchronous external-clock/external-sync mode.
;   The IO Controller MCU owns the clock and framing. RTS from the Z80 side is
;   a service-request signal and starts inactive.
;
; SIO0/B console / Virtual Drip link:
;   SIO_CH_CONSOLE uses async 115200 8N1 with RTS/CTS hardware flow control.
;   WR3 Auto Enables are ON so /CTS gates the transmitter in hardware; /DCD is
;   tied active-low so its RX gate stays asserted. CTS is also polled before TX
;   on the console path as a belt-and-suspenders check; RTS is software-
;   managed by the BIOS/client. Core init holds RTS released until the console
;   client clears its RX ring, registers its sink, and asserts RTS.

	.globl sio_init
	.globl sio_core_init,sio_core_enable_interrupts,sio_core_disable_interrupts
	.globl sio_register_rx_sink,sio_send_byte,sio_recv_byte,sio_rx_kick
	.globl sio0b_rts_assert,sio0b_rts_release
	.globl sio1_ioc_init,sio1_ioc_rts_assert,sio1_ioc_rts_release
	.globl sio1_ioc_put_byte,sio1_ioc_get_byte
	.globl sio_core_rx_lock,sio_core_rx_unlock,sio_core_isr,sio_console_isr
	.globl CONIRQ,sio_console_enable_interrupts,sio_console_disable_interrupts
	.globl SIO_CORE_CODE_START,SIO_CORE_CODE_END
	.globl SIO_CORE_STATE_START,SIO_CORE_STATE_END
	.globl SIO0B_RX_SINK,SIO1_RX_SINK
	.if VDRIP_TRANSPORT_LINKED
	.globl SIO0B_LAST_RR1,SIO0B_LAST_RX_ERROR
	.endif
	.globl SIO_CORE_IRQ_ENABLED
	.globl CONSOLE_IRQ_ENABLED
	.globl CONSOLE_IM2_VECTOR_ENTRY
	.globl CONSOLE_IM2_VECTOR_TABLE_START,CONSOLE_IM2_VECTOR_TABLE_END

SIO0A_CTRL_PORT		= SIOA_CTRL
SIO0B_DATA_PORT		= SIOB_DATA
SIO0B_CTRL_PORT		= SIOB_CTRL
SIO1_IOC_DATA_PORT	= SIO1A_DATA
SIO1_IOC_CTRL_PORT	= SIO1A_CTRL
SIO_MASTER_CTRL_PORT	= SIOA_CTRL
SIO_RX_READY		= RR0_RX_AVAILABLE
SIO_TX_READY		= RR0_TX_EMPTY
; Z80 SIO RR0 bit 5 is CTS. This code treats a set bit as CTS asserted.
SIO_RR0_CTS		= 0x20
SIO_CONSOLE_TX_READY	= SIO_TX_READY | SIO_RR0_CTS
SIO_CONSOLE_TIMEOUT	= 0xffff
SIO_IOCTRL_TIMEOUT	= 0xffff
; WR0 command bits 5-3 = 110, Reset Error.
SIO_WR0_RESET_ERROR	= 0x30
; RR1 bits 6:4 capture async receive framing/overrun/parity errors.
SIO_RR1_RX_ERROR_MASK	= 0x70
SIO0B_WR5_RTS_OFF	= 0xe8
SIO0B_WR5_RTS_ON	= 0xea
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
;   Set up SIO0/B for the existing async console path, clear registered sinks,
;   and leave BIOS-owned SIO interrupts disabled.  Cold boot calls
;   sio1_ioc_init separately; warm boot deliberately does not reset SIO1/A.
; Inputs: none.
; Outputs:
;   SIO0/B is configured 115200 8N1 with WR1 interrupts disabled, WR3 Auto
;   Enables on (/CTS gates TX in hardware; /DCD tied active-low), CTS also
;   polled before TX on the console path, and software-managed RTS released
;   until the console client is ready.
; Clobbers: AF.
; Important invariants:
;   This does not configure application-owned SIO0/A as a channel and does not
;   require or program the CTC. It only masks SIO0/A WR1 interrupts so SIO0/B
;   can own the chip-wide SIO0 interrupt path.
sio_core_init:
	xor a
	ld (SIO0B_RX_SINK),a
	ld (SIO0B_RX_SINK + 1),a
	ld (SIO1_RX_SINK),a
	ld (SIO1_RX_SINK + 1),a
	.if VDRIP_TRANSPORT_LINKED
	ld (SIO0B_LAST_RR1),a
	ld (SIO0B_LAST_RX_ERROR),a
	.endif

	; WR0: channel reset.
	ld a,#0x18
	out (SIO0B_CTRL_PORT),a

	; WR4: x16 clock, 1 stop bit, no parity.
	ld a,#0x04
	out (SIO0B_CTRL_PORT),a
	ld a,#0x44
	out (SIO0B_CTRL_PORT),a

	; WR3: RX enable, 8-bit RX, Auto Enables ON.
	; Auto Enables gate the transmitter on /CTS so the SIO holds queued data
	; until the remote endpoint is ready. /DCD is tied active-low (permanently
	; asserted), so the DCD-gates-RX side effect leaves the receiver enabled.
	; Without this gate, bulk transfers overrun the host and CP/M reports
	; "Bad Sector" errors under disk-heavy apps (TM2, WordStar).
	ld a,#0x03
	out (SIO0B_CTRL_PORT),a
	ld a,#0xe1
	out (SIO0B_CTRL_PORT),a

	; WR5: preserve the existing DTR/TX-enable/8-bit-TX pattern, but hold
	; software-managed RTS released until the console RX sink is registered.
	ld a,#0x05
	out (SIO0B_CTRL_PORT),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (SIO0B_CTRL_PORT),a

	call sio0b_discard_rx_pending
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
;   receive interrupts on all received characters without parity-vector
;   modification, and enable the SIO master interrupt bit.
;
; Interrupt setup trace:
;   1. Load I with CBIOS_IM2_VECTOR_PAGE and enter interrupt mode 2.
;   2. Mask SIO0/A WR1 interrupts. WR9 MIE is chip-wide for SIO0, while this
;      module only owns SIO0/B.
;   3. Write SIO0/B WR2 with CBIOS_SIO_VECTOR. The Z80 forms the IM2 vector
;      table address from I plus the SIO-supplied vector byte.
;   4. Issue Reset Highest IUS / Return-from-Interrupt through channel A, the
;      SIO master channel for WR0 commands that affect interrupt state.
;   5. Program SIO0/B WR1 RX mode.
;   6. Program WR9 MIE through the SIO0 master control port.
;
; SIO WR1 receive interrupt mode bits are D4:D3:
;   00 -> RX interrupts disabled
;   01 -> interrupt on first received character / special condition
;   10 -> interrupt on all received characters, parity affects vector
;   11 -> interrupt on all received characters, parity does not affect vector
;
; The desired console mode is "all receive characters, parity does not affect
; vector." Stable vector behavior matters because CONSOLE_IM2_VECTOR_ENTRY is an
; exact two-byte table entry, not a table of status-modified vectors.
; Outputs:
;   SIO_CORE_IRQ_ENABLED = 1, A = BIOS_OK.
; Clobbers: AF.
sio_core_enable_interrupts:
	di
	ld a,#CBIOS_IM2_VECTOR_PAGE
	ld i,a
	im 2

	; SIO0 WR9 MIE is chip-wide; keep channel A masked before enabling it.
	ld a,#0x01
	out (SIO0A_CTRL_PORT),a
	xor a
	out (SIO0A_CTRL_PORT),a

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
	ld a,#0x09
	out (SIO_MASTER_CTRL_PORT),a
	ld a,#SIO_WR9_MIE
	out (SIO_MASTER_CTRL_PORT),a
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
;     The callback may clobber AF/BC/DE/HL but MUST NOT clobber IX/IY. The ISR
;     preserves AF/BC/DE/HL around the whole interrupt frame; IX/IY are not
;     saved, so a sink that uses them would corrupt foreground state.
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
;   SIO_CH_CONSOLE polls SIO0/B TX-empty and CTS with a finite timeout. It does
;   not use DCD or WR3 Auto Enables.
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
	ld de,#SIO_CONSOLE_TIMEOUT
SIO_SEND_CONSOLE_WAIT:
	in a,(SIO0B_CTRL_PORT)
	and #SIO_CONSOLE_TX_READY
	cp #SIO_CONSOLE_TX_READY
	jr z,SIO_SEND_CONSOLE_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_SEND_CONSOLE_WAIT
	ld a,#BIOS_ERR_TIMEOUT
	ret
SIO_SEND_CONSOLE_READY:
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
;
; This is a polling/fallback path. It reads SIO0/B RR0 in foreground code and,
; if RX_READY is set, reads one pending byte and dispatches it through the same
; registered sink used by the real ISR path.
;
; Important debugging distinction:
;   If keyboard input works only when sio_rx_kick is called, the Virtual Drip
;   parser, vdrip_rx_sink, and textq FIFO may be functioning, but the true
;   interrupt-fed hardware path may still be broken. sio_rx_kick does not prove
;   that WR1/WR2/WR9, IM2 entry, IUS reset, or RX interrupt delivery are correct.
;
; Final console input design:
;   Hot CONST loops should not call sio_rx_kick. CONST should be a cheap queue
;   availability check, and normal input should arrive through sio_core_isr.
;
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
	xor a
	out (SIO0B_CTRL_PORT),a
	in a,(SIO0B_CTRL_PORT)
	and #SIO_RX_READY
	jr z,SIO_RX_KICK_DONE
	push bc
	push de
	push hl
	in a,(SIO0B_DATA_PORT)
	ld c,a
	call sio0b_record_rx_diag
	; sio0b_record_rx_diag returns A=0, matching SIO_CH_CONSOLE.
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
;
; Entry assumptions:
;   - The Z80 is in IM2.
;   - SIO0/B WR2 selects CONSOLE_IM2_VECTOR_ENTRY.
;   - SIO0/B WR1 RX interrupts are enabled for all received characters.
;   - SIO0 WR9 MIE is enabled.
;   - The active console driver has registered SIO0B_RX_SINK.
;
; Register preservation:
;   The ISR pushes AF, BC, DE, and HL before touching SIO state or dispatching to
;   a registered sink. The sink callback may clobber those registers but MUST NOT
;   clobber IX/IY, which the ISR does not save (sio_core has no free bytes for the
;   extra push/pop). This invariant holds today: no sink-reachable code uses
;   IX/IY, and the sole IX user, v9958_write_vram_small, preserves IX itself. The
;   ISR restores AF/BC/DE/HL before RETI.
;
; Channel serviced:
;   This ISR services BIOS-owned SIO0/B console RX. SIO1/A is polled by the
;   IO Controller transport and does not currently use this ISR.
;
; RX handling policy:
;   The ISR is bounded. It handles at most one byte on entry and at most one
;   additional byte during the post-RESET_HIGHEST_IUS race check. It must not
;   drain RX indefinitely while RR0 RX_READY remains set. Unbounded draining can
;   produce long interrupt latency because the registered sink may parse VDrip
;   packet bytes and update queues.
;
; IUS handling:
;   RESET_HIGHEST_IUS is the SIO WR0 command used here as the Return from
;   Interrupt / reset-highest-interrupt-under-service acknowledgement. It is
;   written through the SIO0 master control port. After the first reset, this ISR
;   checks RR0 once more for a byte that may have arrived between the final poll
;   and the IUS reset, then issues a final RESET_HIGHEST_IUS before RETI.
;
; Sink call:
;   sio_core_isr_rx_once reads SIO0B_DATA_PORT, puts the byte in C, leaves A as
;   SIO_CH_CONSOLE, and jumps to sio_core_dispatch_rx.
;
; The ISR must not:
;   - emit VDP traffic
;   - call CONOUT
;   - block on serial TX
;   - perform screen redraws
;   - run slow diagnostics
;   - touch CP/M/BDOS state directly
;
; Purpose:
;   Handle BIOS-owned SIO interrupt work and dispatch received bytes to the
;   registered channel sink. Today only SIO_CH_CONSOLE / SIO0/B is active.
; Outputs:
;   RX bytes are dispatched if a sink exists.
; Important invariants:
;   The ISR is bounded: it handles at most one RX byte at entry and at most one
;   more byte after RESET_HIGHEST_IUS. It never calls BDOS, does not block, does
;   not switch banks, resets highest IUS, and returns with RETI.
sio_core_isr:
	push af
	push bc
	push de
	push hl

	call sio_core_isr_rx_once

SIO_CORE_ISR_DONE:
	; Reset Highest IUS / Return from Interrupt is issued through channel A.
	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (SIO_MASTER_CTRL_PORT),a

	; Re-check RR0: a byte may have arrived between the
	; final poll and RESET_HIGHEST_IUS. If so, process one
	; byte only; do not drain indefinitely in ISR context.
	call sio_core_isr_rx_once
	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (SIO_MASTER_CTRL_PORT),a

SIO_CORE_ISR_EXIT:
	pop hl
	pop de
	pop bc
	pop af
	reti

sio_core_isr_rx_once:
	xor a
	out (SIO0B_CTRL_PORT),a
	in a,(SIO0B_CTRL_PORT)
	and #SIO_RX_READY
	ret z
	in a,(SIO0B_DATA_PORT)
	ld c,a
	call sio0b_record_rx_diag
	; sio0b_record_rx_diag returns A=0, matching SIO_CH_CONSOLE.
	jp sio_core_dispatch_rx

; SIO0/B console RTS helpers.
; RTS is software-managed by the BIOS/client. The SIO core does not own a
; central RX ring, so clients that own the registered RX sink can deassert and
; assert RTS around their own high/low watermarks. These helpers preserve the
; current WR5 DTR/TX-enable/8-bit-TX pattern and only change RTS.
sio0b_rts_assert:
	ld a,#0x05
	out (SIO0B_CTRL_PORT),a
	ld a,#SIO0B_WR5_RTS_ON
	out (SIO0B_CTRL_PORT),a
	xor a
	ret

sio0b_rts_release:
	ld a,#0x05
	out (SIO0B_CTRL_PORT),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (SIO0B_CTRL_PORT),a
	xor a
	ret

; Discard stale SIO0/B RX bytes during core initialization while RTS is held
; released and no console RX sink is registered yet. This keeps line/reset
; noise from being delivered later when interrupts are enabled.
; Clobbers AF, B, C.
sio0b_discard_rx_pending:
	ld b,#0x00
SIO0B_DISCARD_RX_LOOP:
	in a,(SIO0B_CTRL_PORT)
	and #SIO_RX_READY
	jr z,SIO0B_DISCARD_RX_DONE
	in a,(SIO0B_DATA_PORT)
	ld c,a
	call sio0b_record_rx_diag
	djnz SIO0B_DISCARD_RX_LOOP
SIO0B_DISCARD_RX_DONE:
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO0B_CTRL_PORT),a
	.if VDRIP_TRANSPORT_LINKED
	xor a
	ld (SIO0B_LAST_RR1),a
	ld (SIO0B_LAST_RX_ERROR),a
	.endif
	ret

; Clear any SIO0/B receive error latch, and record it while something reads it.
;
; The error reset is FUNCTIONAL and stays in every build: a latched special
; receive condition is cleared only by Error Reset, and SIO0/B interrupts are
; enabled by cbios_boot.asm whatever console is linked.  Leaving a latch
; standing would be a way to wedge SIO0/B RX, not a lost diagnostic.
;
; The two stored bytes ARE the diagnostic.  Their only reader is the VDrip
; transport, which aborts a failed receive on SIO0B_LAST_RX_ERROR, so they are
; assembled out of a build that does not link it.
;
; In: C = received byte to preserve for the RX sink.
; Out: A = 0 (matching SIO_CH_CONSOLE for the dispatch that follows),
;      C preserved.
sio0b_record_rx_diag:
	ld a,#0x01
	out (SIO0B_CTRL_PORT),a
	in a,(SIO0B_CTRL_PORT)
	.if VDRIP_TRANSPORT_LINKED
	ld (SIO0B_LAST_RR1),a
	.endif
	and #SIO_RR1_RX_ERROR_MASK
	.if VDRIP_TRANSPORT_LINKED
	ld (SIO0B_LAST_RX_ERROR),a
	.endif
	jr z,SIO0B_RX_DIAG_DONE
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO0B_CTRL_PORT),a
SIO0B_RX_DIAG_DONE:
	xor a
	out (SIO0B_CTRL_PORT),a
	ret

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
	.if VDRIP_TRANSPORT_LINKED
SIO0B_LAST_RR1:
	.db 0x00
SIO0B_LAST_RX_ERROR:
	.db 0x00
	.endif
SIO_CORE_STATE_END:

	.area CODE (ABS)
