; Default SIO channel B console backend.
;
; The backend keeps pluggable driver state and foreground-safe RX/TX buffers.
; The boot path enables the maskable SIO interrupt receiver after CP/M runtime
; bank setup is stable.
;
; Transitional ownership:
;   This file owns driver slot 1 for the current SIO-only build. Slot 1 holds
;   the SIO console code, the E4E4h IM2 trampoline, and the E500h-E5FFh IM2
;   repeated-byte table. IM2 is intentionally not global core yet because no
;   other interrupting device participates in this transitional build.
;
; Future video-card/storage interrupts may need to move IM2 ownership into a
;   global interrupt layer, especially for devices that emit FFh vectors or need
;   a 257-byte FF-safe table. The compact table below is valid only because SIO
;   WR2 is programmed with CBIOS_SIO_VECTOR = 00h.

	.globl sio_console_driver,sio_console_init,sio_console_isr
	.globl CONIRQ,sio_console_enable_interrupts,sio_console_disable_interrupts
	.globl CONSOLE_DRIVER_CODE_START,CONSOLE_DRIVER_CODE_END
	.globl CONSOLE_IM2_VECTOR_ENTRY
	.globl CONSOLE_IM2_VECTOR_TABLE_START,CONSOLE_IM2_VECTOR_TABLE_END
	.globl CONSOLE_RX_HEAD,CONSOLE_RX_TAIL,CONSOLE_RX_COUNT
	.globl CONSOLE_TX_HEAD,CONSOLE_TX_TAIL,CONSOLE_TX_COUNT
	.globl CONSOLE_TX_ACTIVE,CONSOLE_IRQ_ENABLED
	.globl CONSOLE_IRQ_COUNT
	.globl CONSOLE_RX_BUFFER,CONSOLE_TX_BUFFER

CONSOLE_DATA_PORT	= SIOB_DATA
CONSOLE_CTRL_PORT	= SIOB_CTRL
CONSOLE_MASTER_CTRL_PORT	= SIOA_CTRL
CONSOLE_RX_READY	= RR0_RX_AVAILABLE
CONSOLE_TX_READY	= RR0_TX_EMPTY
CONSOLE_EOF		= 0x1a
CONSOLE_READY		= 0xff
CONSOLE_RX_BUFFER_SIZE	= 0x10
CONSOLE_TX_BUFFER_SIZE	= 0x10
CONSOLE_RX_BUFFER_MASK	= CONSOLE_RX_BUFFER_SIZE - 1
CONSOLE_TX_BUFFER_MASK	= CONSOLE_TX_BUFFER_SIZE - 1

	.area CODE (ABS)
	.org CBIOS_IM2_VECTOR_TABLE

; SIO-owned IM2 repeated-byte table.
; Purpose:
;   Provide the low/high bytes that the Z80 fetches in interrupt mode 2.
; Inputs:
;   I = CBIOS_IM2_VECTOR_PAGE and SIO WR2 = CBIOS_SIO_VECTOR.
; Outputs:
;   The CPU reads E4h/E4h from E500h/E501h and vectors to E4E4h.
; Important invariants:
;   This table is exactly 256 bytes and ends at the exclusive label E600h.
;   A 257th byte would cross from slot 1 into slot 2. That is acceptable for
;   some FF-safe IM2 designs, but not for the current fixed-slot SIO backend.
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
	; No 257th byte is emitted here. With SIO WR2 forced to 00h, the CPU uses
	; E500h/E501h and never indexes the E5FFh/E600h pair for this device.
CONSOLE_IM2_VECTOR_TABLE_END:

	.area CODE (ABS)
	.org CBIOS_CONSOLE_DRIVER_CODE_BASE

CONSOLE_DRIVER_CODE_START:

; Driver dispatch table consumed by cbios_console.asm.
; Entry order must match the facade contract:
;   const, conin, conout, list, punch, reader, listst.
sio_console_driver:
	.dw sio_console_const
	.dw sio_console_conin
	.dw sio_console_conout
	.dw sio_console_list
	.dw sio_console_punch
	.dw sio_console_reader
	.dw sio_console_listst

; Initialize the SIO-backed console driver state. Boot enables interrupts after
; the current bank and CP/M page-zero vectors are in place.
; Purpose:
;   Clear RX/TX ring state and leave maskable SIO interrupts disabled.
; Inputs: none.
; Outputs:
;   CONSOLE_IRQ_ENABLED = 0 and the RX/TX buffers are empty.
; Clobbers: AF, HL.
sio_console_init:
	xor a
	ld (CONSOLE_RX_HEAD),a
	ld (CONSOLE_RX_TAIL),a
	ld (CONSOLE_RX_COUNT),a
	ld (CONSOLE_TX_HEAD),a
	ld (CONSOLE_TX_TAIL),a
	ld (CONSOLE_TX_COUNT),a
	ld (CONSOLE_TX_ACTIVE),a

	call sio_console_disable_interrupts
	ret

CONIRQ:
	; CP/M-facing interrupt switch. A = 0 disables; any nonzero value enables.
	or a
	jp z,sio_console_disable_interrupts

; Enable the SIO/IM2 console interrupt path.
; Purpose:
;   Program the Z80 for IM2, program SIO WR2 with vector 00h, enable SIO receive
;   interrupts, and enable the SIO master interrupt bit.
; Inputs: none.
; Outputs:
;   CONSOLE_IRQ_ENABLED = 1, CONSOLE_IRQ_COUNT = 0, A = FFh.
; Clobbers: AF.
; Important invariants:
;   The SIO vector and IM2 table belong to this legacy console driver in the
;   current build. Interrupts are enabled only after boot/WBOOT has established
;   bank 0, runtime state, and page zero.
sio_console_enable_interrupts:
	di
	ld a,#CBIOS_IM2_VECTOR_PAGE
	ld i,a
	im 2

	ld a,#0x02
	out (CONSOLE_CTRL_PORT),a
	ld a,#CBIOS_SIO_VECTOR
	out (CONSOLE_CTRL_PORT),a

	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (CONSOLE_CTRL_PORT),a
	ld a,#0x01
	out (CONSOLE_CTRL_PORT),a
	ld a,#SIO_WR1_RX_INT_ALL
	out (CONSOLE_CTRL_PORT),a
	ld a,#0x09
	out (CONSOLE_MASTER_CTRL_PORT),a
	ld a,#SIO_WR9_MIE
	out (CONSOLE_MASTER_CTRL_PORT),a
	xor a
	ld (CONSOLE_IRQ_COUNT),a
	ld (CONSOLE_IRQ_COUNT + 1),a
	ld a,#0x01
	ld (CONSOLE_IRQ_ENABLED),a
	ei
	ld a,#0xff
	ret

; CONST backend.
; Purpose:
;   Report buffered input availability. This checks CONSOLE_RX_COUNT, not only
;   raw SIO polling, so interrupt-received bytes are visible to CP/M.
; Outputs:
;   A = CONST_HAS_CHAR when buffered input is available, else CONST_NO_CHAR.
; Clobbers: AF.
sio_console_const:
	call sio_console_rx_kick
	ld a,(CONSOLE_RX_COUNT)
	or a
	jr z,SIO_CONSOLE_CONST_NONE
	ld a,#CONST_HAS_CHAR
	ret
SIO_CONSOLE_CONST_NONE:
	ld a,#CONST_NO_CHAR
	ret

; CONIN backend.
; Purpose:
;   Block until a byte is available in the foreground-safe receive ring.
; Outputs:
;   A = received byte.
; Clobbers:
;   AF; DE and HL are preserved locally.
; Important invariants:
;   RX head/count may be updated by the ISR. Tail/count updates in the foreground
;   are protected by sio_console_rx_lock when interrupt mode is active.
sio_console_conin:
	push de
	push hl
SIO_CONSOLE_CONIN_WAIT:
	call sio_console_rx_kick
	ld a,(CONSOLE_RX_COUNT)
	or a
	jr nz,SIO_CONSOLE_CONIN_HAVE_CHAR
	jr SIO_CONSOLE_CONIN_WAIT
SIO_CONSOLE_CONIN_HAVE_CHAR:
	call sio_console_rx_lock
	ld hl,#CONSOLE_RX_BUFFER
	ld a,(CONSOLE_RX_TAIL)
	ld e,a
	ld d,#0x00
	add hl,de
	ld a,(hl)
	push af
	ld a,(CONSOLE_RX_TAIL)
	inc a
	and #CONSOLE_RX_BUFFER_MASK
	ld (CONSOLE_RX_TAIL),a
	ld a,(CONSOLE_RX_COUNT)
	dec a
	ld (CONSOLE_RX_COUNT),a
	call sio_console_rx_unlock
	pop af
	pop hl
	pop de
	ret

; CONOUT backend.
; Purpose:
;   Blocking transmit of the character in C.
; Inputs:
;   C = byte to transmit.
; Outputs:
;   The byte is written to SIO channel B when TX is ready.
; Clobbers:
;   AF is preserved locally.
; Important invariants:
;   The current foreground output path still polls TX readiness and does not use
;   the TX ring for CP/M CONOUT.
sio_console_conout:
	push af
SIO_CONSOLE_CONOUT_WAIT:
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_TX_READY
	jr z,SIO_CONSOLE_CONOUT_WAIT
	ld a,c
	out (CONSOLE_DATA_PORT),a
	pop af
	ret

sio_console_list:
	ret

sio_console_punch:
	ret

sio_console_reader:
	ld a,#CONSOLE_EOF
	ret

sio_console_listst:
	ld a,#CONSOLE_READY
	ret

; SIO interrupt service routine.
; Purpose:
;   Drain one available RX byte into the receive ring and optionally advance the
;   TX ring when TX-ready interrupts are active.
; Inputs:
;   Entered through the E4E4h trampoline in IM2.
; Outputs:
;   CONSOLE_IRQ_COUNT increments; RX bytes are buffered unless the ring is full.
; Clobbers:
;   AF, BC, DE, HL are preserved; alternate registers, IX, and IY are untouched.
; Important invariants:
;   The ISR ends with SIO_WR0_RESET_HIGHEST_IUS and RETI. It does not switch
;   banks, so all touched state must remain in common runtime memory.
sio_console_isr:
	push af
	push bc
	push de
	push hl

	ld hl,(CONSOLE_IRQ_COUNT)
	inc hl
	ld (CONSOLE_IRQ_COUNT),hl

	in a,(CONSOLE_CTRL_PORT)
	ld b,a
	and #CONSOLE_RX_READY
	jr z,SIO_ISR_CHECK_TX
	in a,(CONSOLE_DATA_PORT)
	ld c,a
	call sio_console_rx_store

SIO_ISR_CHECK_TX:
	ld a,b
	and #CONSOLE_TX_READY
	jr z,SIO_ISR_DONE
	call sio_console_tx_drain

SIO_ISR_DONE:
	ld a,#SIO_WR0_RESET_HIGHEST_IUS
	out (CONSOLE_CTRL_PORT),a
	pop hl
	pop de
	pop bc
	pop af
	reti

; Store one RX byte from foreground polling or the ISR.
; Input: C = received byte.
; Output:
;   Byte appended to CONSOLE_RX_BUFFER unless the ring is full.
; Clobbers: AF, DE, HL.
; Important invariants:
;   Full-buffer policy is drop-new-byte. This keeps the ISR bounded and avoids
;   corrupting unread foreground input.
sio_console_rx_store:
	ld a,(CONSOLE_RX_COUNT)
	cp #CONSOLE_RX_BUFFER_SIZE
	ret nc
	ld hl,#CONSOLE_RX_BUFFER
	ld a,(CONSOLE_RX_HEAD)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c
	ld a,(CONSOLE_RX_HEAD)
	inc a
	and #CONSOLE_RX_BUFFER_MASK
	ld (CONSOLE_RX_HEAD),a
	ld a,(CONSOLE_RX_COUNT)
	inc a
	ld (CONSOLE_RX_COUNT),a
	ret

; Opportunistically poll one RX byte into the same ring used by interrupts.
; Purpose:
;   Covers the short windows before interrupts are enabled or while foreground
;   code has IRQs temporarily disabled.
; Clobbers:
;   AF; BC and HL are preserved locally when a byte is read.
sio_console_rx_kick:
	call sio_console_rx_lock
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_RX_READY
	jr z,SIO_CONSOLE_RX_KICK_DONE
	push bc
	push hl
	in a,(CONSOLE_DATA_PORT)
	ld c,a
	call sio_console_rx_store
	pop hl
	pop bc
SIO_CONSOLE_RX_KICK_DONE:
	call sio_console_rx_unlock
	ret

; Disable maskable interrupts around foreground RX ring updates when IRQ mode is
; active. If the console is still polling-only, this is a no-op.
sio_console_rx_lock:
	ld a,(CONSOLE_IRQ_ENABLED)
	or a
	ret z
	di
	ret

; Re-enable maskable interrupts after a foreground RX ring update when IRQ mode
; is active.
sio_console_rx_unlock:
	ld a,(CONSOLE_IRQ_ENABLED)
	or a
	ret z
	ei
	ret

; Drain one pending TX ring byte if any are queued.
; Note:
;   CP/M CONOUT currently bypasses this path and performs blocking transmit.
sio_console_tx_drain:
	ld a,(CONSOLE_TX_COUNT)
	or a
	jr z,SIO_ISR_TX_IDLE
	ld hl,#CONSOLE_TX_BUFFER
	ld a,(CONSOLE_TX_TAIL)
	ld e,a
	ld d,#0x00
	add hl,de
	ld a,(hl)
	out (CONSOLE_DATA_PORT),a
	ld a,(CONSOLE_TX_TAIL)
	inc a
	and #CONSOLE_TX_BUFFER_MASK
	ld (CONSOLE_TX_TAIL),a
	ld a,(CONSOLE_TX_COUNT)
	dec a
	ld (CONSOLE_TX_COUNT),a
	ret

SIO_ISR_TX_IDLE:
	xor a
	ld (CONSOLE_TX_ACTIVE),a
	ret

sio_console_tx_kick:
	in a,(CONSOLE_CTRL_PORT)
	and #CONSOLE_TX_READY
	ret z
	jp sio_console_tx_drain

; Disable the SIO console interrupt path.
; Purpose:
;   Clear SIO WR1 interrupt enables, clear SIO master interrupt enable, and mark
;   console IRQ mode inactive for foreground lock/unlock helpers.
; Outputs:
;   CONSOLE_IRQ_ENABLED = 0, CONSOLE_TX_ACTIVE = 0.
; Clobbers: AF.
sio_console_disable_interrupts:
	di
	ld a,#0x01
	out (CONSOLE_CTRL_PORT),a
	xor a
	out (CONSOLE_CTRL_PORT),a
	ld a,#0x09
	out (CONSOLE_MASTER_CTRL_PORT),a
	xor a
	out (CONSOLE_MASTER_CTRL_PORT),a
	ld (CONSOLE_TX_ACTIVE),a
	ld (CONSOLE_IRQ_ENABLED),a
	ret

	.area CODE (ABS)
	.org CBIOS_IM2_VECTOR_ENTRY
; IM2 trampoline inside slot 1. The repeated-byte table vectors here by storing
; E4h/E4h as the fetched address word.
CONSOLE_IM2_VECTOR_ENTRY:
	jp sio_console_isr

CONSOLE_DRIVER_CODE_END:

	.area WORK (ABS)
	.org CBIOS_CONSOLE_DRIVER_WORK_AREA
CONSOLE_DRIVER_STATE_START:
CONSOLE_RX_HEAD:
	.db 0x00
CONSOLE_RX_TAIL:
	.db 0x00
CONSOLE_RX_COUNT:
	.db 0x00
CONSOLE_TX_HEAD:
	.db 0x00
CONSOLE_TX_TAIL:
	.db 0x00
CONSOLE_TX_COUNT:
	.db 0x00
CONSOLE_TX_ACTIVE:
	.db 0x00
CONSOLE_IRQ_ENABLED:
	.db 0x00
CONSOLE_IRQ_COUNT:
	.dw 0x0000
CONSOLE_RX_BUFFER:
	.ds CONSOLE_RX_BUFFER_SIZE
CONSOLE_TX_BUFFER:
	.ds CONSOLE_TX_BUFFER_SIZE
CONSOLE_DRIVER_STATE_END:

	.area CODE (ABS)
