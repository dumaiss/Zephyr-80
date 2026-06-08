; Zephyr-80 packetized-terminal Virtual Drip console BIOS driver.
;
; Build-time alternative to cbios_console_vdrip.asm. This backend exposes the
; CP/M console as raw terminal bytes carried inside Virtual Drip packets:
;
;   CONOUT byte -> PACKET_TERMINAL_TX -> proxy PTY master
;   proxy PTY master -> PACKET_TERMINAL_RX -> textq -> CONIN
;
; It deliberately contains no terminal emulator, screen buffer, ANSI parser,
; cursor tracking, font rendering, or proxy-side display model. The external
; terminal emulator attached to the proxy PTY owns terminal behavior.

	.module pt_vdrip_console

	.globl vdrip_console_driver
	.globl vdrip_console_init,vdrip_console_const
	.globl vdrip_console_conin,vdrip_console_conout
	.globl vdrip_rx_sink
	.globl vdrip_send_packet,vdrip_rts_assert_raw,crc8_update
	.globl vdrip_reset_display,vdrip_data_write_block
	.globl vdrip_rx_rts_released
	.globl restore_font_from_rom
	.globl VDRIP_CONSOLE_CODE_START,VDRIP_CONSOLE_CODE_END

	.globl sio_core_enable_interrupts,sio_register_rx_sink,sio_rx_kick
	.globl sio_send_byte
	.globl SIO_CH_CONSOLE

; SIO0/B port aliases matching platform_zephyr80.inc / sio_core.asm.
VDRIP_DATA		= SIOB_DATA
VDRIP_CTRL		= SIOB_CTRL
SIO_RR0_TX_EMPTY	= 0x04

; Virtual Drip packet protocol.
PACKET_SYNC0		= 0xa5
PACKET_SYNC1		= 0x5a
PACKET_TERMINAL_INPUT	= 0x05
PACKET_RESET		= 0x06
PACKET_PING		= 0x07
PACKET_PROXY_READY	= 0x0a
PACKET_VDP_DATA_BLOCK	= 0x0b
PACKET_STORAGE_READ_REQ	= 0x0d
PACKET_STORAGE_READ_REPLY = 0x0e
PACKET_STORAGE_WRITE_REQ = 0x0f
PACKET_STORAGE_WRITE_REPLY = 0x10
PACKET_TERMINAL_TX	= 0x11
PACKET_TERMINAL_RX	= 0x12

; Packet sizing.
VDRIP_WIRE_OVERHEAD	= 0x03
VDRIP_PACKET_PAYLOAD_MAX = 0x10
VDRIP_DATA_BLOCK_MAX	= 240
PT_RX_PAYLOAD_MAX	= VDRIP_PACKET_PAYLOAD_MAX

; Packet parser states.
PT_RX_WAIT_SYNC0	= 0x00
PT_RX_WAIT_SYNC1	= 0x01
PT_RX_LEN		= 0x02
PT_RX_TYPE		= 0x03
PT_RX_PAYLOAD		= 0x04
PT_RX_CRC		= 0x05

; Console input queue.
TEXTQ_SIZE		= 0x80
TEXTQ_MASK		= TEXTQ_SIZE - 1
TEXTQ_RTS_HIGH_WATER	= 0x20
TEXTQ_RTS_LOW_WATER	= 0x10

CONSOLE_EOF		= 0x1a
CONSOLE_READY		= 0xff
CONST_HAS_CHAR		= 0xff

	.area CODE (ABS)
	.org CBIOS_DRIVER_SLOT0_BASE

VDRIP_CONSOLE_CODE_START:

vdrip_console_driver:
	.dw vdrip_console_const
	.dw vdrip_console_conin
	.dw vdrip_console_conout
	.dw vdrip_console_list
	.dw vdrip_console_punch
	.dw vdrip_console_reader
	.dw vdrip_console_listst


; ===========================================================================
; Public CP/M console backend
; ===========================================================================

vdrip_console_init:
	call vdrip_rts_release_raw
	call pt_rx_init
	call pt_register_rx_sink
	call sio_core_enable_interrupts

	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	ld a,(pt_handshake_done)
	or a
	jr nz,pt_init_ready

	call pt_wait_for_proxy_ready
	ld a,#0x01
	ld (pt_handshake_done),a

pt_init_ready:
	ld a,#0x01
	ld (pt_proxy_ready_flag),a
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


vdrip_console_const:
	push hl
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr z,pt_const_empty
	ld a,#CONST_HAS_CHAR
	pop hl
	ret
pt_const_empty:
	xor a
	pop hl
	ret


vdrip_console_conin:
	push bc
	push de
	push hl

pt_conin_wait:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(textq_count)
	or a
	jr z,pt_conin_wait

	di
	ld hl,#textq_buffer
	ld a,(textq_tail)
	ld e,a
	ld d,#0x00
	add hl,de
	ld a,(hl)
	push af

	ld a,(textq_tail)
	inc a
	and #TEXTQ_MASK
	ld (textq_tail),a

	ld a,(textq_count)
	dec a
	ld (textq_count),a

	call app_maybe_resume_rts
	ei

	pop af
	pop hl
	pop de
	pop bc
	ret


vdrip_console_conout:
	push bc
	push de
	push hl

	ld e,c
	ld a,#PACKET_TERMINAL_TX
	call vdrip_send_packet1

	pop hl
	pop de
	pop bc
	ret


vdrip_console_list:
	ret

vdrip_console_punch:
	ret

vdrip_console_reader:
	ld a,#CONSOLE_EOF
	ret

vdrip_console_listst:
	ld a,#CONSOLE_READY
	ret


; ===========================================================================
; Startup readiness and RX integration
; ===========================================================================

pt_wait_for_proxy_ready:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(pt_proxy_ready_flag)
	or a
	jr z,pt_wait_for_proxy_ready
	ret


pt_rx_init:
	xor a
	ld (vdrip_rx_rts_released),a
	ld (textq_head),a
	ld (textq_tail),a
	ld (textq_count),a
	ld (pt_proxy_ready_flag),a
	ld (pt_rx_state),a
	ld (pt_rx_len),a
	ld (pt_rx_payload_len),a
	ld (pt_rx_remaining),a
	ld (pt_rx_index),a
	ld (pt_rx_crc),a
	ld (pt_rx_type),a

	ld hl,#textq_buffer
	ld bc,#TEXTQ_SIZE
pt_rx_init_ztextq:
	ld (hl),a
	inc hl
	dec bc
	ld a,b
	or c
	ld a,#0x00
	jr nz,pt_rx_init_ztextq
	ret


pt_register_rx_sink:
	di
	ld a,#SIO_CH_CONSOLE
	ld hl,#vdrip_rx_sink
	call sio_register_rx_sink
	ei
	ret


; SIO RX sink for packetized PTY console mode.
; Input from sio_core: A = SIO channel id, C = received byte.
vdrip_rx_sink:
	push af
	push bc
	push de
	push hl

	cp #SIO_CH_CONSOLE
	jr nz,pt_rx_sink_done

	ld a,c
	call pt_rx_parse_byte

pt_rx_sink_done:
	pop hl
	pop de
	pop bc
	pop af
	ret


pt_rx_parse_byte:
	ld c,a
	ld a,(pt_rx_state)
	cp #PT_RX_WAIT_SYNC0
	jr z,pt_parse_wait_sync0
	cp #PT_RX_WAIT_SYNC1
	jr z,pt_parse_wait_sync1
	cp #PT_RX_LEN
	jr z,pt_parse_len
	cp #PT_RX_TYPE
	jr z,pt_parse_type
	cp #PT_RX_PAYLOAD
	jp z,pt_parse_payload
	cp #PT_RX_CRC
	jp z,pt_parse_crc
	xor a
	ld (pt_rx_state),a
	ret

pt_parse_wait_sync0:
	ld a,c
	cp #PACKET_SYNC0
	ret nz
	ld a,#PT_RX_WAIT_SYNC1
	ld (pt_rx_state),a
	ret

pt_parse_wait_sync1:
	ld a,c
	cp #PACKET_SYNC1
	jr z,pt_parse_sync_done
	cp #PACKET_SYNC0
	jr z,pt_parse_keep_sync1
	xor a
	ld (pt_rx_state),a
	ret

pt_parse_keep_sync1:
	ld a,#PT_RX_WAIT_SYNC1
	ld (pt_rx_state),a
	ret

pt_parse_sync_done:
	ld a,#PT_RX_LEN
	ld (pt_rx_state),a
	ret

pt_parse_len:
	ld a,c
	cp #VDRIP_WIRE_OVERHEAD
	jp c,pt_parse_reset
	ld (pt_rx_len),a
	ld c,#0x00
	call crc8_update
	ld a,c
	ld (pt_rx_crc),a

	ld a,(pt_rx_len)
	sub #VDRIP_WIRE_OVERHEAD
	cp #(PT_RX_PAYLOAD_MAX + 1)
	jp nc,pt_parse_reset
	ld (pt_rx_payload_len),a
	ld (pt_rx_remaining),a
	xor a
	ld (pt_rx_index),a
	ld a,#PT_RX_TYPE
	ld (pt_rx_state),a
	ret

pt_parse_type:
	ld a,c
	ld (pt_rx_type),a
	ld e,a
	ld a,(pt_rx_crc)
	ld c,a
	ld a,e
	call crc8_update
	ld a,c
	ld (pt_rx_crc),a

	ld a,(pt_rx_payload_len)
	or a
	jr z,pt_parse_expect_crc
	ld a,#PT_RX_PAYLOAD
	ld (pt_rx_state),a
	ret

pt_parse_expect_crc:
	ld a,#PT_RX_CRC
	ld (pt_rx_state),a
	ret

pt_parse_payload:
	ld hl,#pt_rx_payload_buffer
	ld a,(pt_rx_index)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld e,c
	ld a,(pt_rx_crc)
	ld c,a
	ld a,e
	call crc8_update
	ld a,c
	ld (pt_rx_crc),a

	ld a,(pt_rx_index)
	inc a
	ld (pt_rx_index),a
	ld a,(pt_rx_remaining)
	dec a
	ld (pt_rx_remaining),a
	jr z,pt_parse_expect_crc
	ret

pt_parse_crc:
	ld a,(pt_rx_crc)
	cp c
	jr nz,pt_parse_reset

	ld a,(pt_rx_type)
	cp #PACKET_TERMINAL_RX
	jr z,pt_dispatch_terminal_rx
	cp #PACKET_PROXY_READY
	jr z,pt_dispatch_proxy_ready
	cp #PACKET_TERMINAL_INPUT
	jr z,pt_dispatch_terminal_rx

pt_parse_reset:
	xor a
	ld (pt_rx_state),a
	ret

pt_dispatch_proxy_ready:
	ld a,#0x01
	ld (pt_proxy_ready_flag),a
	xor a
	ld (pt_rx_state),a
	ret

pt_dispatch_terminal_rx:
	ld a,(pt_rx_payload_len)
	or a
	jr z,pt_parse_reset
	ld b,a
	ld hl,#pt_rx_payload_buffer

pt_dispatch_terminal_rx_loop:
	ld a,(hl)
	push bc
	push hl
	call textq_put_ascii
	pop hl
	pop bc
	inc hl
	djnz pt_dispatch_terminal_rx_loop
	jr pt_parse_reset


; ===========================================================================
; Textq FIFO and RTS flow control
; ===========================================================================

textq_put_ascii:
	ld c,a

	ld a,(textq_count)
	cp #TEXTQ_SIZE
	jr nc,textq_full

	ld hl,#textq_buffer
	ld a,(textq_head)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld a,(textq_head)
	inc a
	and #TEXTQ_MASK
	ld (textq_head),a

	ld a,(textq_count)
	inc a
	ld (textq_count),a
	cp #TEXTQ_RTS_HIGH_WATER
	ret c

	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret

textq_full:
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret


app_maybe_resume_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret z

	ld a,(textq_count)
	cp #(TEXTQ_RTS_LOW_WATER + 1)
	ret nc

	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a
	ret


vdrip_rts_assert_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_ON
	out (VDRIP_CTRL),a
	xor a
	ret


vdrip_rts_release_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (VDRIP_CTRL),a
	xor a
	ret


; ===========================================================================
; Shared VDrip packet output helpers
; ===========================================================================

vdrip_reset_display:
	ld a,#PACKET_RESET
	call vdrip_send_packet0
	ld a,#PACKET_PING
	jp vdrip_send_packet0


vdrip_data_write_block:
	ld a,b
	or c
	ret z

	ld (block_ptr_store),hl
	ld (block_count_store),bc

pt_data_block_chunk:
	ld hl,(block_count_store)
	ld a,h
	or l
	ret z

	ld a,h
	or a
	jr nz,pt_data_block_use_max
	ld a,l
	cp #VDRIP_DATA_BLOCK_MAX
	jr nc,pt_data_block_use_max
	ld b,a
	jr pt_data_block_send

pt_data_block_use_max:
	ld b,#VDRIP_DATA_BLOCK_MAX

pt_data_block_send:
	push bc
	ld a,#PACKET_VDP_DATA_BLOCK
	ld hl,(block_ptr_store)
	call vdrip_send_packet
	pop bc

	ld e,b
	ld d,#0x00
	ld hl,(block_ptr_store)
	add hl,de
	ld (block_ptr_store),hl

	ld hl,(block_count_store)
	or a
	sbc hl,de
	ld (block_count_store),hl
	jr pt_data_block_chunk


vdrip_send_packet0:
	ld b,#0x00
	ld hl,#packet_payload0
	jp vdrip_send_packet


vdrip_send_packet1:
	push af
	ld a,e
	ld (packet_payload0),a
	pop af
	ld b,#0x01
	ld hl,#packet_payload0
	jp vdrip_send_packet


; Input: A = type, B = payload length, HL = payload pointer.
; Preserves BC, DE, HL.
vdrip_send_packet:
	ld (packet_type_store),a

	ld a,b
	ld (packet_len_store),a
	add a,#VDRIP_WIRE_OVERHEAD
	ld (packet_wire_len_store),a
	ld (packet_ptr_store),hl

	push bc
	push de
	push hl

	ld c,#0x00
	ld a,(packet_wire_len_store)
	call crc8_update
	ld a,(packet_type_store)
	call crc8_update

	ld hl,(packet_ptr_store)
	ld a,(packet_len_store)
	or a
	jr z,pt_send_packet_crc_done

	ld b,a
pt_send_packet_crc_loop:
	ld a,(hl)
	call crc8_update
	inc hl
	djnz pt_send_packet_crc_loop

pt_send_packet_crc_done:
	ld a,c
	ld (packet_crc_store),a

	ld a,#PACKET_SYNC0
	call vdrip_transport_putc
	ld a,#PACKET_SYNC1
	call vdrip_transport_putc
	ld a,(packet_wire_len_store)
	call vdrip_transport_putc
	ld a,(packet_type_store)
	call vdrip_transport_putc

	ld hl,(packet_ptr_store)
	ld a,(packet_len_store)
	or a
	jr z,pt_send_packet_send_crc

	ld b,a
pt_send_packet_payload_loop:
	ld a,(hl)
	call vdrip_transport_putc
	inc hl
	djnz pt_send_packet_payload_loop

pt_send_packet_send_crc:
	ld a,(packet_crc_store)
	call vdrip_transport_putc

	pop hl
	pop de
	pop bc
	ret


vdrip_transport_putc:
	ld c,a
	xor a
	out (VDRIP_CTRL),a
	ld a,#SIO_CH_CONSOLE
	call sio_send_byte
	or a
	ret z

	xor a
	out (VDRIP_CTRL),a
pt_transport_wait_tx_empty:
	in a,(VDRIP_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,pt_transport_wait_tx_empty
	ld a,c
	out (VDRIP_DATA),a
	xor a
	ret


crc8_update:
	xor c
	ld c,a
	ld e,#0x08

pt_crc8_update_bit:
	bit 7,c
	jr z,pt_crc8_update_shift

	sla c
	ld a,c
	xor #0x07
	ld c,a
	jr pt_crc8_update_next

pt_crc8_update_shift:
	sla c

pt_crc8_update_next:
	dec e
	jr nz,pt_crc8_update_bit
	ret


restore_font_from_rom:
	ret


; ===========================================================================
; Driver state
; ===========================================================================

packet_len_store:
	.db 0x00
packet_wire_len_store:
	.db 0x00
packet_type_store:
	.db 0x00
packet_crc_store:
	.db 0x00
packet_payload0:
	.ds 0x01
packet_ptr_store:
	.dw 0x0000

block_ptr_store:
	.dw 0x0000
block_count_store:
	.dw 0x0000

vdrip_rx_rts_released:
	.db 0x00
pt_proxy_ready_flag:
	.db 0x00
pt_handshake_done:
	.db 0x00

pt_rx_state:
	.db PT_RX_WAIT_SYNC0
pt_rx_len:
	.db 0x00
pt_rx_type:
	.db 0x00
pt_rx_payload_len:
	.db 0x00
pt_rx_remaining:
	.db 0x00
pt_rx_index:
	.db 0x00
pt_rx_crc:
	.db 0x00
pt_rx_payload_buffer:
	.ds PT_RX_PAYLOAD_MAX

textq_head:
	.db 0x00
textq_tail:
	.db 0x00
textq_count:
	.db 0x00
textq_buffer:
	.ds TEXTQ_SIZE

VDRIP_CONSOLE_CODE_END:

	.area CODE (ABS)
