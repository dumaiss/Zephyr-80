; Shared Zephyr-80 Virtual Drip transport.
;
; This module is the single framed-protocol owner used by the retained VDrip
; console and VDrip storage backend. SIO core remains the only hardware
; reader; its registered SIO0/B sink enters here.
;
; Wire:
;   A5h 5Ah LEN_LO LEN_HI TYPE PAYLOAD...
;   LEN = TYPE + PAYLOAD, little-endian. No CRC/checksum.
;
; Receive modes:
;   RAW     - deliver each byte to the selected console callback.
;   READY   - parse frames until a zero-payload PROXY_READY is received.
;   STORAGE - parse one pending storage reply.
;   PACKET  - parse packetized PTY input while no storage request is active.

	.module vdrip_transport

	.include "drivers/transport/vdrip_protocol.inc"

	.globl VDRIP_TRANSPORT_CODE_START,VDRIP_TRANSPORT_CODE_END
	.globl VDRIP_TRANSPORT_BANK7_CODE_START,VDRIP_TRANSPORT_BANK7_CODE_END
	.globl VDRIP_TRANSPORT_STATE_START,VDRIP_TRANSPORT_STATE_END
	.globl vdrip_send_frame,vdrip_send_packet,vdrip_send_packet0,vdrip_send_packet1
	.globl console_backend_send_frame
	.globl vdrip_transport_register_sink
	.globl vdrip_transport_set_raw_callback
	.globl vdrip_transport_set_idle_mode
	.globl vdrip_transport_wait_ready
	.globl vdrip_transport_begin_storage,vdrip_transport_end_storage
	.globl vdrip_transport_wait_reply
	.globl vdrip_rx_sink
	.globl vdrip_proxy_online
	.globl vdrip_pending_type,vdrip_pending_seq
	.globl vdrip_reply_ready,vdrip_reply_error,vdrip_reply_status

	.globl sio_register_rx_sink,sio_send_byte,sio_rx_kick
	.globl SIO_CH_CONSOLE,SIO0B_LAST_RX_ERROR

VDRIP_MODE_RAW		= 0x00
VDRIP_MODE_READY	= 0x01
VDRIP_MODE_STORAGE	= 0x02
VDRIP_MODE_PACKET	= 0x03

VDRIP_RX_WAIT_SYNC0	= 0x00
VDRIP_RX_WAIT_SYNC1	= 0x01
VDRIP_RX_LEN_LO		= 0x02
VDRIP_RX_LEN_HI		= 0x03
VDRIP_RX_TYPE		= 0x04
VDRIP_RX_PAYLOAD	= 0x05

VDRIP_RX_MAX_DECLARED	= 131
VDRIP_READ_REPLY_LEN	= 130
VDRIP_WRITE_REPLY_LEN	= 2

	.area CODE (ABS)
	.org CBIOS_VDRIP_TRANSPORT_CODE_BASE

VDRIP_TRANSPORT_CODE_START:

; ---------------------------------------------------------------------------
; Common memory: the registered RX sink and the parser it calls
; ---------------------------------------------------------------------------
; The sink runs in the SIO0/B interrupt frame, and it parses inline rather than
; enqueuing, so the whole packet state machine and dispatch are reached from an
; interrupt and must be addressable whatever the latch holds.
;
; Shrinking this to just the sink plus a receive queue -- which is what the
; project's own SIO rule asks for -- is a behaviour change scheduled with the
; Phase 5 restoration of CONSOLE=vdrip, where it can actually be tested.
; See docs/memory-model-implementation-plan.md.

; Common SIO0/B receive sink. ISR-safe: bounded byte parsing/queue dispatch.
vdrip_rx_sink:
	push af
	push bc
	push de
	push hl
	cp #SIO_CH_CONSOLE
	jr nz,vdrip_rx_sink_done
	ld a,(vdrip_rx_mode)
	or a
	jr nz,vdrip_rx_sink_framed
	ld a,c
	call vdrip_call_raw_callback
	jr vdrip_rx_sink_done
vdrip_rx_sink_framed:
	ld a,c
	call vdrip_parse_byte
vdrip_rx_sink_done:
	pop hl
	pop de
	pop bc
	pop af
	ret

vdrip_call_raw_callback:
	ld hl,(vdrip_raw_callback)
	ld d,h
	ld e,l
	ld a,d
	or e
	ret z
	ld a,c
	ld de,#vdrip_raw_callback_return
	push de
	jp (hl)
vdrip_raw_callback_return:
	ret

vdrip_parse_byte:
	ld c,a
	ld a,(vdrip_rx_state)
	cp #VDRIP_RX_WAIT_SYNC0
	jr z,vdrip_parse_sync0
	cp #VDRIP_RX_WAIT_SYNC1
	jr z,vdrip_parse_sync1
	cp #VDRIP_RX_LEN_LO
	jr z,vdrip_parse_len_lo
	cp #VDRIP_RX_LEN_HI
	jr z,vdrip_parse_len_hi
	cp #VDRIP_RX_TYPE
	jr z,vdrip_parse_type
	cp #VDRIP_RX_PAYLOAD
	jr z,vdrip_parse_payload
	jp vdrip_parser_reset

vdrip_parse_sync0:
	ld a,c
	cp #PACKET_SYNC0
	ret nz
	ld a,#VDRIP_RX_WAIT_SYNC1
	ld (vdrip_rx_state),a
	ret
vdrip_parse_sync1:
	ld a,c
	cp #PACKET_SYNC1
	jr z,vdrip_parse_sync_done
	cp #PACKET_SYNC0
	ret z
	jp vdrip_parser_reset
vdrip_parse_sync_done:
	ld a,#VDRIP_RX_LEN_LO
	ld (vdrip_rx_state),a
	ret
vdrip_parse_len_lo:
	ld a,c
	ld (vdrip_declared_len),a
	ld a,#VDRIP_RX_LEN_HI
	ld (vdrip_rx_state),a
	ret
vdrip_parse_len_hi:
	ld a,c
	ld (vdrip_declared_len + 1),a
	or a
	jp nz,vdrip_parser_reset
	ld a,(vdrip_declared_len)
	or a
	jp z,vdrip_parser_reset
	cp #(VDRIP_RX_MAX_DECLARED + 1)
	jp nc,vdrip_parser_reset
	dec a
	ld (vdrip_payload_len),a
	ld (vdrip_payload_remaining),a
	xor a
	ld (vdrip_payload_index),a
	ld a,#VDRIP_RX_TYPE
	ld (vdrip_rx_state),a
	ret
vdrip_parse_type:
	ld a,c
	ld (vdrip_rx_type),a
	ld a,(vdrip_payload_len)
	or a
	jr z,vdrip_dispatch_packet
	ld a,#VDRIP_RX_PAYLOAD
	ld (vdrip_rx_state),a
	ret
vdrip_parse_payload:
	ld hl,#MOVE_BUFFER
	ld a,(vdrip_payload_index)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c
	ld a,(vdrip_payload_index)
	inc a
	ld (vdrip_payload_index),a
	ld a,(vdrip_payload_remaining)
	dec a
	ld (vdrip_payload_remaining),a
	ret nz

vdrip_dispatch_packet:
	ld a,(vdrip_rx_type)
	cp #PACKET_PROXY_READY
	jr z,vdrip_dispatch_ready
	cp #PACKET_PROTOCOL_ERROR
	jr z,vdrip_dispatch_protocol_error
	ld b,a
	ld a,(vdrip_rx_mode)
	cp #VDRIP_MODE_PACKET
	jr z,vdrip_dispatch_console_packet
	cp #VDRIP_MODE_STORAGE
	jr z,vdrip_dispatch_storage
	jp vdrip_parser_reset

vdrip_dispatch_ready:
	ld a,(vdrip_payload_len)
	or a
	jp nz,vdrip_parser_reset
	ld a,#0x01
	ld (vdrip_proxy_online),a
	ld a,(vdrip_rx_mode)
	cp #VDRIP_MODE_STORAGE
	jp nz,vdrip_parser_reset
	ld (vdrip_reply_error),a
	jr vdrip_parser_reset

vdrip_dispatch_protocol_error:
	xor a
	ld (vdrip_proxy_online),a
	inc a
	ld (vdrip_reply_error),a
	ld (vdrip_reply_status),a
	jp vdrip_parser_reset

vdrip_dispatch_console_packet:
	ld a,b
	cp #PACKET_TERMINAL_RX
	jr z,vdrip_dispatch_console_bytes
	cp #PACKET_TERMINAL_INPUT
	jr nz,vdrip_parser_reset
vdrip_dispatch_console_bytes:
	ld a,(vdrip_payload_len)
	or a
	jr z,vdrip_parser_reset
	ld b,a
	ld hl,#MOVE_BUFFER
vdrip_dispatch_console_loop:
	ld a,(hl)
	push bc
	push hl
	ld c,a
	call vdrip_call_raw_callback
	pop hl
	pop bc
	inc hl
	djnz vdrip_dispatch_console_loop
	jr vdrip_parser_reset

vdrip_dispatch_storage:
	ld a,(vdrip_pending_type)
	cp b
	jr nz,vdrip_parser_reset
	cp #PACKET_STORAGE_READ_REPLY
	jr z,vdrip_check_read_reply
	cp #PACKET_STORAGE_WRITE_REPLY
	jr z,vdrip_check_write_reply
	jr vdrip_parser_reset
vdrip_check_read_reply:
	ld a,(vdrip_payload_len)
	cp #VDRIP_READ_REPLY_LEN
	jr nz,vdrip_storage_reply_bad
	jr vdrip_check_storage_reply
vdrip_check_write_reply:
	ld a,(vdrip_payload_len)
	cp #VDRIP_WRITE_REPLY_LEN
	jr nz,vdrip_storage_reply_bad
vdrip_check_storage_reply:
	ld a,(MOVE_BUFFER)
	ld b,a
	ld a,(vdrip_pending_seq)
	cp b
	jr nz,vdrip_parser_reset
	ld a,(MOVE_BUFFER + 1)
	ld (vdrip_reply_status),a
	or a
	jr nz,vdrip_storage_reply_bad
	ld a,#0x01
	ld (vdrip_reply_ready),a
	jr vdrip_parser_reset
vdrip_storage_reply_bad:
	ld a,#0x01
	ld (vdrip_reply_error),a

vdrip_parser_reset:
	xor a
	ld (vdrip_rx_state),a
	ret

VDRIP_TRANSPORT_CODE_END:

	.area WORK (ABS)
	.org CBIOS_VDRIP_TRANSPORT_WORK_AREA
VDRIP_TRANSPORT_STATE_START:
vdrip_rx_mode:
	.db VDRIP_MODE_RAW
vdrip_idle_mode:
	.db VDRIP_MODE_RAW
vdrip_proxy_online:
	.db 0x00
vdrip_raw_callback:
	.dw 0x0000
vdrip_rx_state:
	.db VDRIP_RX_WAIT_SYNC0
vdrip_declared_len:
	.dw 0x0000
vdrip_payload_len:
	.db 0x00
vdrip_rx_type:
	.db 0x00
vdrip_payload_remaining:
	.db 0x00
vdrip_payload_index:
	.db 0x00
vdrip_pending_type:
	.db 0x00
vdrip_pending_seq:
	.db 0x00
vdrip_reply_ready:
	.db 0x00
vdrip_reply_error:
	.db 0x00
vdrip_reply_status:
	.db 0x00
vdrip_tx_type:
	.db 0x00
vdrip_tx_len:
	.dw 0x0000
vdrip_tx_ptr:
	.dw 0x0000
vdrip_tx_payload0:
	.db 0x00
VDRIP_TRANSPORT_STATE_END:
