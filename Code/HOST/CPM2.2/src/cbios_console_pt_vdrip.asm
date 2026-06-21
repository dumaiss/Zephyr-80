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
	.globl vdrip_send_packet,vdrip_send_packet0,vdrip_send_packet1
	.globl vdrip_rts_assert_raw
	.globl vdrip_reset_display,vdrip_data_write_block
	.globl vdrip_rx_rts_released
	.globl restore_font_from_rom
	.globl VDRIP_CONSOLE_CODE_START,VDRIP_CONSOLE_CODE_END

	.globl sio_core_enable_interrupts,sio_register_rx_sink,sio_rx_kick
	.globl sio_send_byte
	.globl SIO_CH_CONSOLE
	.globl vdrip_transport_register_sink
	.globl vdrip_transport_set_raw_callback,vdrip_transport_set_idle_mode
	.globl vdrip_transport_wait_ready

; SIO0/B port aliases matching platform_zephyr80.inc / sio_core.asm.
VDRIP_DATA		= SIOB_DATA
VDRIP_CTRL		= SIOB_CTRL
SIO_RR0_TX_EMPTY	= 0x04

; Packet sizing.
VDRIP_PACKET_PAYLOAD_MAX = 0x10
VDRIP_DATA_BLOCK_MAX	= 240

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
	ld hl,#textq_put_ascii
	call vdrip_transport_set_raw_callback
	ld a,#0x03
	call vdrip_transport_set_idle_mode
	call vdrip_transport_register_sink
	call sio_core_enable_interrupts

	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	call vdrip_transport_wait_ready
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


pt_rx_init:
	xor a
	ld (vdrip_rx_rts_released),a
	ld (textq_head),a
	ld (textq_tail),a
	ld (textq_count),a

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


restore_font_from_rom:
	ret


; ===========================================================================
; Driver state
; ===========================================================================

block_ptr_store:
	.dw 0x0000
block_count_store:
	.dw 0x0000

vdrip_rx_rts_released:
	.db 0x00

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
