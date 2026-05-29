; Zephyr-80 Virtual Drip checkerboard demo.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Load with the Zephyr-80 monitor L command, then run with:
;   G 8000
;
; This program takes over SIO channel B from the monitor and never returns.
; Reset or power cycle the machine to recover the monitor.

	.module vdrip_checkerboard
	.area CODE (ABS)
	.org 0x8000

; Z80 SIO channel B, matching the monitor console wiring.
VDRIP_DATA		= 0x22
VDRIP_CTRL		= 0x23
SIO_RR0_TX_EMPTY	= 0x04

; Virtual Drip packet constants.
PACKET_SYNC0		= 0xa5
PACKET_SYNC1		= 0x5a
PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_RESET		= 0x06
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08
PACKET_WIRE_OVERHEAD	= 0x03

; TMS9928A Graphics I table layout.
PATTERN_TABLE		= 0x0000
SPRITE_PATTERN_TABLE	= 0x1800
COLOR_TABLE		= 0x2000
NAME_TABLE		= 0x3800
SPRITE_ATTRIBUTE_TABLE	= 0x3b00

start:
	di
	call sio_init_vdrip
	call delay_before_start

main_loop:
	call vdrip_send_reset
	call vdrip_send_ping
	call init_vdp_graphics1
	call draw_checkerboard
	call vdrip_send_frame_mark
	call delay_between_replays
	jp main_loop

; Initialize SIO channel B for 115200 8N1 using x16 async clocking.
; WR3 keeps Auto Enables off for the FT230X /DCDB wiring on this board.
sio_init_vdrip:
	; WR0: channel reset
	ld a,#0x18
	out (VDRIP_CTRL),a

	; WR4: x16 clock, 1 stop bit, no parity
	ld a,#0x04
	out (VDRIP_CTRL),a
	ld a,#0x44
	out (VDRIP_CTRL),a

	; WR3: RX enable, 8-bit RX, Auto Enables off
	ld a,#0x03
	out (VDRIP_CTRL),a
	ld a,#0xc1
	out (VDRIP_CTRL),a

	; WR5: DTR, TX 8-bit, TX enable, RTS
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#0xea
	out (VDRIP_CTRL),a

	; WR1: interrupts disabled
	ld a,#0x01
	out (VDRIP_CTRL),a
	xor a
	out (VDRIP_CTRL),a
	ret

; Write A to SIOB after RR0 Tx Buffer Empty is set.
; Preserves: BC, DE, HL.
sio_putc_vdrip:
	push af
sio_putc_vdrip_wait:
	in a,(VDRIP_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,sio_putc_vdrip_wait
	pop af
	out (VDRIP_DATA),a
	ret

; Update Virtual Drip CRC8 with one byte.
; Input: C = current CRC, A = next byte.
; Output: C = updated CRC.
; Clobbers: AF, E.
crc8_update:
	xor c
	ld c,a
	ld e,#0x08
crc8_update_bit:
	bit 7,c
	jr z,crc8_update_shift
	sla c
	ld a,c
	xor #0x07
	ld c,a
	jr crc8_update_next
crc8_update_shift:
	sla c
crc8_update_next:
	dec e
	jr nz,crc8_update_bit
	ret

; Send a Virtual Drip packet.
; Input: A = type, B = payload length, HL = payload pointer.
; Sends SYNC, LEN, TYPE, payload bytes, and CRC8 over SIOB.
; Preserves: BC, DE, HL. Clobbers: AF.
vdrip_send_packet:
	ld (packet_type_store),a
	ld a,b
	ld (packet_len_store),a
	add a,#PACKET_WIRE_OVERHEAD
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
	jr z,vdrip_send_packet_crc_done
	ld b,a
vdrip_send_packet_crc_loop:
	ld a,(hl)
	call crc8_update
	inc hl
	djnz vdrip_send_packet_crc_loop
vdrip_send_packet_crc_done:
	ld a,c
	ld (packet_crc_store),a

	ld a,#PACKET_SYNC0
	call sio_putc_vdrip
	ld a,#PACKET_SYNC1
	call sio_putc_vdrip
	ld a,(packet_wire_len_store)
	call sio_putc_vdrip
	ld a,(packet_type_store)
	call sio_putc_vdrip

	ld hl,(packet_ptr_store)
	ld a,(packet_len_store)
	or a
	jr z,vdrip_send_packet_send_crc
	ld b,a
vdrip_send_packet_payload_loop:
	ld a,(hl)
	call sio_putc_vdrip
	inc hl
	djnz vdrip_send_packet_payload_loop

vdrip_send_packet_send_crc:
	ld a,(packet_crc_store)
	call sio_putc_vdrip

	pop hl
	pop de
	pop bc
	ret

; Send zero-payload packet type A.
vdrip_send_packet0:
	ld b,#0x00
	ld hl,#packet_payload0
	jp vdrip_send_packet

; Send one-payload-byte packet. Input: A = type, E = payload byte.
vdrip_send_packet1:
	push af
	ld a,e
	ld (packet_payload0),a
	pop af
	ld b,#0x01
	ld hl,#packet_payload0
	jp vdrip_send_packet

vdrip_send_reset:
	ld a,#PACKET_RESET
	jp vdrip_send_packet0

vdrip_send_ping:
	ld a,#PACKET_PING
	jp vdrip_send_packet0

vdrip_send_frame_mark:
	ld a,#PACKET_FRAME_MARK
	jp vdrip_send_packet0

; Wrap one TMS9928A control-port byte as a Virtual Drip packet.
; Input: A = control byte.
; Preserves: BC, DE, HL.
vdrip_ctrl_write:
	push bc
	push de
	push hl
	ld e,a
	ld a,#PACKET_VDP_CTRL_WRITE
	call vdrip_send_packet1
	pop hl
	pop de
	pop bc
	ret

; Wrap one TMS9928A data-port byte as a Virtual Drip packet.
; Input: A = data byte.
; Preserves: BC, DE, HL.
vdrip_data_write:
	push bc
	push de
	push hl
	ld e,a
	ld a,#PACKET_VDP_DATA_WRITE
	call vdrip_send_packet1
	pop hl
	pop de
	pop bc
	ret

; Write TMS9928A register B with value A.
vdp_write_register:
	call vdrip_ctrl_write
	ld a,b
	or #0x80
	call vdrip_ctrl_write
	ret

; Set TMS9928A VRAM write address to HL.
vdp_set_vram_write_addr:
	ld a,l
	call vdrip_ctrl_write
	ld a,h
	and #0x3f
	or #0x40
	call vdrip_ctrl_write
	ret

; Write one byte to the TMS9928A data port.
; Input: A = data byte.
vdp_write_data_byte:
	jp vdrip_data_write

; Write BC bytes from HL to the current TMS9928A data port address.
; This still sends one Virtual Drip DATA_WRITE packet per byte because the
; current Virtual Drip TMS9928A backend requires one-byte payloads.
vdp_write_data_block:
	ld (block_ptr_store),hl
	ld (block_count_store),bc
vdp_write_data_block_loop:
	ld hl,(block_count_store)
	ld a,h
	or l
	ret z
	ld hl,(block_ptr_store)
	ld a,(hl)
	inc hl
	ld (block_ptr_store),hl
	call vdp_write_data_byte
	ld hl,(block_count_store)
	dec hl
	ld (block_count_store),hl
	jr vdp_write_data_block_loop

; Graphics I, display on, 16 KiB VRAM.
init_vdp_graphics1:
	ld b,#0x00
	ld a,#0x00
	call vdp_write_register
	ld b,#0x01
	ld a,#0xc0
	call vdp_write_register
	ld b,#0x02
	ld a,#(NAME_TABLE >> 10)
	call vdp_write_register
	ld b,#0x03
	ld a,#(COLOR_TABLE >> 6)
	call vdp_write_register
	ld b,#0x04
	ld a,#(PATTERN_TABLE >> 11)
	call vdp_write_register
	ld b,#0x05
	ld a,#(SPRITE_ATTRIBUTE_TABLE >> 7)
	call vdp_write_register
	ld b,#0x06
	ld a,#(SPRITE_PATTERN_TABLE >> 11)
	call vdp_write_register
	ld b,#0x07
	ld a,#0xf4
	call vdp_write_register
	ret

draw_checkerboard:
	; Pattern 0: blue/white pixel checker.
	ld hl,#PATTERN_TABLE
	call vdp_set_vram_write_addr
	ld b,#0x08
	ld e,#0xaa
draw_pattern0_loop:
	ld a,e
	call vdp_write_data_byte
	ld a,e
	xor #0xff
	ld e,a
	djnz draw_pattern0_loop

	; Pattern 1: inverse checker, so the name table creates a larger grid too.
	ld b,#0x08
	ld e,#0x55
draw_pattern1_loop:
	ld a,e
	call vdp_write_data_byte
	ld a,e
	xor #0xff
	ld e,a
	djnz draw_pattern1_loop

	; Color table: white foreground on blue background for all pattern groups.
	ld hl,#COLOR_TABLE
	call vdp_set_vram_write_addr
	ld b,#0x20
draw_color_loop:
	ld a,#0xf4
	call vdp_write_data_byte
	djnz draw_color_loop

	; Hide sprites with the TMS9918 sprite terminator.
	ld hl,#SPRITE_ATTRIBUTE_TABLE
	call vdp_set_vram_write_addr
	ld a,#0xd0
	call vdp_write_data_byte

	; Name table: 32 columns x 24 rows, alternating tile IDs 0 and 1.
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr
	ld b,#0x18
	ld d,#0x00
draw_name_row:
	ld c,#0x20
	ld e,d
draw_name_col:
	ld a,e
	call vdp_write_data_byte
	ld a,e
	xor #0x01
	ld e,a
	dec c
	jr nz,draw_name_col
	ld a,d
	xor #0x01
	ld d,a
	djnz draw_name_row
	ret

delay_before_start:
	ld b,#0x14
delay_before_start_loop:
	call delay_unit
	djnz delay_before_start_loop
	ret

delay_between_replays:
	ld b,#0x05
delay_between_replays_loop:
	call delay_unit
	djnz delay_between_replays_loop
	ret

delay_unit:
	ld de,#0xffff
delay_unit_loop:
	dec de
	ld a,d
	or e
	jr nz,delay_unit_loop
	ret

packet_len_store:
	.db 0x00
packet_wire_len_store:
	.db 0x00
packet_type_store:
	.db 0x00
packet_crc_store:
	.db 0x00
packet_payload0:
	.db 0x00
packet_ptr_store:
	.dw 0x0000
block_ptr_store:
	.dw 0x0000
block_count_store:
	.dw 0x0000
