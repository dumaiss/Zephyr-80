; Legacy SIO-backed CP/M console driver.
;
; Console is a driver. SIO is platform plumbing owned by sio_core.asm.
; This module owns CP/M console behavior and the terminal input buffer:
;   - CONST reports buffered terminal input,
;   - CONIN consumes buffered terminal input,
;   - CONOUT sends one byte through the SIO core blocking send-byte API,
;   - list/punch/reader/listst keep the existing deterministic behavior.
;
; The driver subscribes to SIO_CH_CONSOLE RX bytes during initialization. Its
; callback only enqueues the byte and returns; it never calls BDOS, blocks,
; performs disk I/O, or does terminal rendering.

	.globl sio_console_driver,sio_console_init,legacy_console_rx_sink
	.globl CONSOLE_DRIVER_CODE_START,CONSOLE_DRIVER_CODE_END
	.globl CONSOLE_RX_HEAD,CONSOLE_RX_TAIL,CONSOLE_RX_COUNT
	.globl CONSOLE_TX_HEAD,CONSOLE_TX_TAIL,CONSOLE_TX_COUNT
	.globl CONSOLE_TX_ACTIVE
	.globl CONSOLE_RX_BUFFER,CONSOLE_TX_BUFFER
	.globl sio_register_rx_sink,sio_send_byte,sio_rx_kick
	.globl sio_core_rx_lock,sio_core_rx_unlock

CONSOLE_EOF		= 0x1a
CONSOLE_READY		= 0xff
CONSOLE_RX_BUFFER_SIZE	= 0x10
CONSOLE_TX_BUFFER_SIZE	= 0x10
CONSOLE_RX_BUFFER_MASK	= CONSOLE_RX_BUFFER_SIZE - 1
CONSOLE_TX_BUFFER_MASK	= CONSOLE_TX_BUFFER_SIZE - 1

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

; Initialize the legacy console client.
; Purpose:
;   Clear console-owned terminal buffers and register legacy_console_rx_sink for
;   SIO_CH_CONSOLE bytes from the SIO core.
; Inputs: none.
; Outputs:
;   CONSOLE_RX_* state is empty; SIO0/B RX bytes dispatch into this driver.
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

	ld a,#SIO_CH_CONSOLE
	ld hl,#legacy_console_rx_sink
	jp sio_register_rx_sink

; CONST backend.
; Purpose:
;   Report buffered terminal input availability. The foreground kick lets the
;   SIO core dispatch a byte that arrived before interrupts were enabled or
;   while the foreground temporarily disabled interrupts around buffer updates.
; Outputs:
;   A = CONST_HAS_CHAR when buffered input is available, else CONST_NO_CHAR.
; Clobbers: AF.
sio_console_const:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
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
;   Block until the console-owned RX ring has a byte, then consume it.
; Outputs:
;   A = received byte.
; Clobbers:
;   AF only. BC/DE/HL are preserved for direct BIOS callers that keep live
;   foreground state in those registers.
sio_console_conin:
	push de
	push hl
SIO_CONSOLE_CONIN_WAIT:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(CONSOLE_RX_COUNT)
	or a
	jr nz,SIO_CONSOLE_CONIN_HAVE_CHAR
	jr SIO_CONSOLE_CONIN_WAIT
SIO_CONSOLE_CONIN_HAVE_CHAR:
	call sio_core_rx_lock
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
	call sio_core_rx_unlock
	pop af
	pop hl
	pop de
	ret

; CONOUT backend.
; Purpose:
;   Keep existing blocking console output behavior, but route the hardware work
;   through the SIO core send-byte API.
; Input:
;   C = byte to transmit.
; Clobbers:
;   AF is preserved locally to match the old driver behavior.
sio_console_conout:
	push af
	ld a,#SIO_CH_CONSOLE
	call sio_send_byte
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

; RX sink callback registered with the SIO core.
;
; In:
;   A = SIO channel id
;   C = received byte
; Must:
;   return quickly, never call BDOS, never block, and never perform disk I/O.
; Behavior:
;   Enqueue C into the console-owned terminal RX ring. If the ring is full, the
;   new byte is dropped, preserving the old bounded ISR behavior.
; Clobbers:
;   AF, DE, HL.
legacy_console_rx_sink:
	cp #SIO_CH_CONSOLE
	ret nz
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

; TX ring state is retained for symbol compatibility and future nonblocking
; console work. Current CONOUT remains blocking and does not enqueue here.
CONSOLE_TX_HEAD:
	.db 0x00
CONSOLE_TX_TAIL:
	.db 0x00
CONSOLE_TX_COUNT:
	.db 0x00
CONSOLE_TX_ACTIVE:
	.db 0x00
CONSOLE_RX_BUFFER:
	.ds CONSOLE_RX_BUFFER_SIZE
CONSOLE_TX_BUFFER:
	.ds CONSOLE_TX_BUFFER_SIZE
CONSOLE_DRIVER_STATE_END:

	.area CODE (ABS)
