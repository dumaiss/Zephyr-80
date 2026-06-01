; Zephyr-80 Virtual Drip moving smiley sprite demo.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; Load with the Zephyr-80 monitor L command, then run with:
;   G 8000
;
; This program takes over SIO channel B from the monitor and never returns.
; Reset or power cycle the machine to recover the monitor.

	.module vdrip_smiley
	.area CODE (ABS)
	.org 0x8000

; Z80 SIO channel B, matching the monitor console wiring.
VDRIP_DATA		= 0x22
VDRIP_CTRL		= 0x23
SIO_RR0_TX_EMPTY	= 0x04

; Current BIOS helper entry points used by this monitor-loaded test app.
; Keep in sync with CPM2.2 build/firmware.map or docs/symbol-map.md.
BIOS_SIO_CORE_ENABLE_INTERRUPTS = 0xdd91
BIOS_SIO_REGISTER_RX_SINK = 0xdde4
BIOS_SIO_RX_KICK	= 0xde6d
SIO_CH_CONSOLE		= 0x00

; Virtual Drip packet constants.
PACKET_SYNC0		= 0xa5
PACKET_SYNC1		= 0x5a
PACKET_VDP_CTRL_WRITE	= 0x01
PACKET_VDP_DATA_WRITE	= 0x02
PACKET_RESET		= 0x06
PACKET_PING		= 0x07
PACKET_FRAME_MARK	= 0x08

; TMS9928A Graphics I table layout.
PATTERN_TABLE		= 0x0000
SPRITE_PATTERN_TABLE	= 0x1800
COLOR_TABLE		= 0x2000
NAME_TABLE		= 0x3800
SPRITE_ATTRIBUTE_TABLE	= 0x3b00

SPRITE_Y		= 0x58
SPRITE_STEP		= 0x04
SPRITE_WRAP_X		= 0xf8

PACKET_KEYBOARD_EVENT	= 0x05
KEY_EVENT_LEN		= 0x04

KEY_EVENT_FLAG_DOWN	= 0x01

KEY_ASCII_W		= 0x77
KEY_ASCII_S		= 0x73
KEY_ASCII_UPPER_W	= 0x57
KEY_ASCII_UPPER_S	= 0x53
KEY_SPECIAL_UP		= 0x05
KEY_SPECIAL_DOWN	= 0x06

SPRITE_Y_START		= 0x58
SPRITE_Y_MIN		= 0x08
SPRITE_Y_MAX		= 0xb8
SPRITE_Y_STEP		= 0x08
SPRITE_COLOR_NORMAL	= 0x0a
SPRITE_COLOR_RX		= 0x0e

; Parser diagnostic colors.
; These are only sprite color values, not VDP tile colors.
SPRITE_COLOR_SYNC	= 0x0f	; white: saw A5 5A
SPRITE_COLOR_BODY	= 0x09	; red: LEN body completed
SPRITE_COLOR_CRC_FAIL	= 0x04	; dark blue: CRC failed
SPRITE_COLOR_CRC_OK	= 0x0b	; light yellow: CRC passed

VDRIP_RX_WAIT_SYNC0	= 0x00
VDRIP_RX_WAIT_SYNC1	= 0x01
VDRIP_RX_LEN		= 0x02
VDRIP_RX_BODY		= 0x03
VDRIP_WIRE_OVERHEAD	= 0x03
VDRIP_PACKET_PAYLOAD_MAX = 0x10
VDRIP_PACKET_BODY_MAX	= VDRIP_PACKET_PAYLOAD_MAX + VDRIP_WIRE_OVERHEAD

VDRIP_RX_BUFFER_SIZE = 0x40
VDRIP_RX_BUFFER_MASK = VDRIP_RX_BUFFER_SIZE - 1

; SIO0/B RTS control.
; Same WR5 values used by the BIOS helper:
;   0xea = TX enable, 8-bit TX, DTR, RTS asserted
;   0xe8 = TX enable, 8-bit TX, DTR, RTS released
;
; DTR is not used by the hardware, but this preserves the existing WR5 pattern.
SIO0B_WR5_RTS_OFF	= 0xe8
SIO0B_WR5_RTS_ON	= 0xea

; Virtual Drip RX flow-control watermarks.
; Buffer is 64 bytes, so:
;   release RTS at 48 bytes used
;   assert RTS again at 16 bytes used
VDRIP_RX_RTS_HIGH_WATER	= 0x30
VDRIP_RX_RTS_LOW_WATER	= 0x10

; Give the operator time to switch from the monitor console to the proxy
; before this program starts sending Virtual Drip traffic.
STARTUP_DELAY_UNITS	= 0x34
VDRIP_RX_KICK_SPINS	= 0x10

DEBUG_PACKET_MAX	= 0x10

DBG_TILE_07		= 0x08
DBG_TILE_05		= 0x10
DBG_TILE_06		= 0x18
DBG_TILE_73		= 0x20
DBG_TILE_77		= 0x28
DBG_TILE_00		= 0x30
DBG_TILE_A6		= 0x38
DBG_TILE_OTHER		= 0x40

start:
	di

	; Stop host while we take ownership of SIO0/B RX.
	call vdrip_rts_release_raw

	call vdrip_rx_init
	call vdrip_register_rx_sink

	; Ensure the BIOS-owned SIO0/B interrupt path is active for our RX sink.
	call #BIOS_SIO_CORE_ENABLE_INTERRUPTS

	; Give the operator time to switch to the proxy before output starts.
	call delay_before_start

	; Now ready to receive host-to-Zephyr packets.
	call vdrip_rts_assert_raw
	xor a
	ld (vdrip_rx_rts_released),a

	ld a,#SPRITE_Y_START
	ld (sprite_y),a
	ld a,#SPRITE_COLOR_NORMAL
	ld (sprite_color),a

	xor a
	ld (sprite_x),a

	call send_full_state
	call debug_force_body_test
	jp animation_loop

vdrip_rx_init:
	xor a
	ld (vdrip_rx_head),a
	ld (vdrip_rx_tail),a
	ld (vdrip_rx_count),a
	ld (vdrip_parse_state),a
	ld (vdrip_parse_len_store),a
	ld (vdrip_parse_remaining),a
	ld (vdrip_parse_payload_index),a
	ld (vdrip_rx_seen_flag),a
	ld (vdrip_rx_rts_released),a
	ld (vdrip_crc_computed),a
	ld (vdrip_crc_received),a	
	ld (debug_body_count),a
	ld (debug_body_dirty),a
	ret


vdrip_register_rx_sink:
	di                         ; atomic-ish pointer replacement
	ld a,#SIO_CH_CONSOLE
	ld hl,#vdrip_rx_sink
	call #BIOS_SIO_REGISTER_RX_SINK
	ei
	ret

vdrip_rx_sink:
	cp #0x00
	ret nz

	ld a,(vdrip_rx_count)
	cp #VDRIP_RX_BUFFER_SIZE
	jr nc,vdrip_rx_sink_full

	ld hl,#vdrip_rx_buffer
	ld a,(vdrip_rx_head)
	ld e,a
	ld d,#0x00
	add hl,de

	ld (hl),c

	ld a,(vdrip_rx_head)
	inc a
	and #VDRIP_RX_BUFFER_MASK
	ld (vdrip_rx_head),a

	ld a,(vdrip_rx_count)
	inc a
	ld (vdrip_rx_count),a

	call vdrip_rx_maybe_release_rts
	ret


vdrip_rx_sink_full:
	; We are already full. Tell host to stop if not already stopped.
	call vdrip_rts_release_raw
	ld a,#0x01
	ld (vdrip_rx_rts_released),a

	; Drop byte for now.
	ret

vdrip_rx_get_byte:
	di                         ; protect ring against ISR update

	ld a,(vdrip_rx_count)
	or a
	jr nz,vdrip_rx_get_have_byte

	ei
	ld a,#0x01                 ; no byte available
	ret

vdrip_rx_get_have_byte:
	ld hl,#vdrip_rx_buffer
	ld a,(vdrip_rx_tail)
	ld e,a
	ld d,#0x00
	add hl,de

	ld c,(hl)

	ld a,(vdrip_rx_tail)
	inc a
	and #VDRIP_RX_BUFFER_MASK
	ld (vdrip_rx_tail),a

	ld a,(vdrip_rx_count)
	dec a
	ld (vdrip_rx_count),a

	; We just made room in the RX ring.
	; If we had released RTS because the buffer was getting full,
	; assert RTS again once we are below the low watermark.
	call vdrip_rx_maybe_assert_rts

	ei
	xor a                      ; success
	ret

vdrip_move_smiley_up:
	ld a,(sprite_y)
	cp #SPRITE_Y_MIN
	ret z
	ret c

	sub #SPRITE_Y_STEP
	ld (sprite_y),a
	ret


vdrip_move_smiley_down:
	ld a,(sprite_y)
	cp #SPRITE_Y_MAX
	ret z
	ret nc

	add a,#SPRITE_Y_STEP
	ld (sprite_y),a
	ret

animation_loop:
	call vdrip_rx_kick_pending
	call vdrip_poll_rx
	call debug_draw_packet_body
	;call vdrip_handle_rx_seen
	call update_sprite_position
	call vdrip_send_frame_mark
	call delay_frame
	ld a,(sprite_x)
	add a,#SPRITE_STEP
	cp #SPRITE_WRAP_X
	jr c,animation_store_x
	xor a
	ld (sprite_x),a
	jr animation_loop

animation_store_x:
	ld (sprite_x),a
	jr animation_loop


vdrip_rx_kick_pending:
	ld b,#VDRIP_RX_KICK_SPINS
vdrip_rx_kick_pending_loop:
	ld a,#SIO_CH_CONSOLE
	call #BIOS_SIO_RX_KICK
	djnz vdrip_rx_kick_pending_loop
	ret


vdrip_handle_rx_seen:
	ld a,(vdrip_rx_seen_flag)
	or a
	ret z

	xor a
	ld (vdrip_rx_seen_flag),a

	ld a,(sprite_color)
	cp #SPRITE_COLOR_RX
	jr z,vdrip_handle_rx_seen_normal

	ld a,#SPRITE_COLOR_RX
	ld (sprite_color),a
	ret

vdrip_handle_rx_seen_normal:
	ld a,#SPRITE_COLOR_NORMAL
	ld (sprite_color),a
	ret

debug_force_body_test:
	; Draw fixed legend on row 0:
	;   07 05 05 73 00 00 A6
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr

	ld a,#DBG_TILE_07
	call vdp_write_data_byte

	ld a,#DBG_TILE_05
	call vdp_write_data_byte

	ld a,#DBG_TILE_05
	call vdp_write_data_byte

	ld a,#DBG_TILE_73
	call vdp_write_data_byte

	ld a,#DBG_TILE_00
	call vdp_write_data_byte

	ld a,#DBG_TILE_00
	call vdp_write_data_byte

	ld a,#DBG_TILE_A6
	call vdp_write_data_byte

	ret

; ---------------------------------------------------------------------------
; Foreground RX packet poller.
;
; Drains bytes from vdrip_rx_buffer and looks for:
;
;   A5 5A 07 05 FLAGS ASCII SPECIAL MODIFIERS CRC
;
; Meaning:
;   SYNC
;   LEN = 7, the complete body after SYNC: LEN, TYPE, PAYLOAD, CRC
;   TYPE = PACKET_KEYBOARD_EVENT
;   payload[0] = key flags, for example 0x05 for DOWN|HAS_ASCII
;   payload[1] = ASCII
;   payload[2] = special
;   payload[3] = modifiers
;   CRC ignored for bring-up
; ---------------------------------------------------------------------------

vdrip_poll_rx:
	call vdrip_rx_get_byte
	or a
	ret nz                  ; no more bytes

	ld a,c
	call vdrip_parse_rx_byte
	jr vdrip_poll_rx


; ---------------------------------------------------------------------------
; Parse one incoming byte.
;
; Input:
;   A = next received byte
;
; Clobbers:
;   AF
; ---------------------------------------------------------------------------

vdrip_parse_rx_byte:
	ld c,a

	ld a,(vdrip_parse_state)
	cp #VDRIP_RX_WAIT_SYNC0
	jr z,vdrip_parse_wait_sync0

	cp #VDRIP_RX_WAIT_SYNC1
	jr z,vdrip_parse_wait_sync1

	cp #VDRIP_RX_LEN
	jr z,vdrip_parse_len

	cp #VDRIP_RX_BODY
	jr z,vdrip_parse_body

	; Bad state: reset parser.
	xor a
	ld (vdrip_parse_state),a
	ret


vdrip_parse_wait_sync0:
	ld a,c
	cp #PACKET_SYNC0
	ret nz

	ld a,#VDRIP_RX_WAIT_SYNC1
	ld (vdrip_parse_state),a
	ret


vdrip_parse_wait_sync1:
	ld a,c
	cp #PACKET_SYNC1
	jr z,vdrip_parse_wait_sync_have

	cp #PACKET_SYNC0
	jr z,vdrip_parse_wait_sync_keep

	xor a
	ld (vdrip_parse_state),a
	ret

vdrip_parse_wait_sync_keep:
	ld a,#VDRIP_RX_WAIT_SYNC1
	ld (vdrip_parse_state),a
	ret

vdrip_parse_wait_sync_have:
	; DEBUG:
	; We recognized the full sync header A5 5A.
	; If keypresses reach this point, the face changes to SYNC color.
	ld a,#SPRITE_COLOR_SYNC
	ld (sprite_color),a

	ld a,#VDRIP_RX_LEN
	ld (vdrip_parse_state),a
	ret


vdrip_parse_len:
	ld a,c
	cp #VDRIP_WIRE_OVERHEAD
	jp c,vdrip_parse_reset

	cp #VDRIP_PACKET_BODY_MAX + 1
	jp nc,vdrip_parse_reset

	ld hl,#vdrip_packet_body
	ld (hl),c

	ld (vdrip_parse_len_store),a
	dec a
	ld (vdrip_parse_remaining),a

	ld a,#0x01
	ld (vdrip_parse_payload_index),a

	ld a,#VDRIP_RX_BODY
	ld (vdrip_parse_state),a
	ret


vdrip_parse_body:
	; Store body byte N, where body[0] is LEN and body[LEN-1] is CRC.
	ld hl,#vdrip_packet_body
	ld a,(vdrip_parse_payload_index)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld a,(vdrip_parse_payload_index)
	inc a
	ld (vdrip_parse_payload_index),a

	ld a,(vdrip_parse_remaining)
	dec a
	ld (vdrip_parse_remaining),a
	jr z,vdrip_parse_body_done
	ret


vdrip_parse_body_done:
	; Full LEN-described body was buffered.
	call vdrip_debug_capture_body

	ld a,#SPRITE_COLOR_BODY
	ld (sprite_color),a

	call vdrip_packet_crc_valid
	jr nz,vdrip_parse_crc_failed

	ld a,#SPRITE_COLOR_CRC_OK
	ld (sprite_color),a

	ld a,#0x01
	ld (vdrip_rx_seen_flag),a

	call vdrip_parse_apply_key_event
	jp vdrip_parse_reset


vdrip_parse_crc_failed:
	; DEBUG:
	; We got a full LEN-sized body, but the CRC did not match.
	ld a,#SPRITE_COLOR_CRC_FAIL
	ld (sprite_color),a

	jp vdrip_parse_reset

vdrip_packet_crc_valid:
	ld c,#0x00
	ld hl,#vdrip_packet_body
	ld a,(vdrip_parse_len_store)
	dec a
	ld b,a

vdrip_packet_crc_loop:
	ld a,(hl)
	call crc8_update
	inc hl
	djnz vdrip_packet_crc_loop

	; HL now points at the received CRC byte.
	; Store both sides for monitor/debug inspection.
	ld a,c
	ld (vdrip_crc_computed),a

	ld a,(hl)
	ld (vdrip_crc_received),a

	cp c
	ret


; ---------------------------------------------------------------------------
; vdrip_parse_apply_key_event
;
; Diagnostic version.
;
; Called only after a full LEN-described body was buffered.
; During CRC-fail testing, this may also be called from the CRC-fail path.
;
; Expected body for:
;   A5 5A 07 05 05 73 00 00 A6
;
;   body[0] = 07   ; LEN
;   body[1] = 05   ; TYPE = keyboard event
;   body[2] = 05   ; FLAGS
;   body[3] = 73   ; ASCII
;   body[4] = 00   ; SPECIAL
;   body[5] = 00   ; MODIFIERS
;   body[6] = A6   ; CRC
; ---------------------------------------------------------------------------

vdrip_parse_apply_key_event:
	; Mark: semantic parser entered.
	ld a,#0x0d
	ld (sprite_color),a

	; Check LEN.
	ld a,(vdrip_packet_body)
	cp #KEY_EVENT_LEN + VDRIP_WIRE_OVERHEAD
	jr z,vdrip_key_len_ok

	; LEN reject.
	ld a,#0x06
	ld (sprite_color),a
	ret

vdrip_key_len_ok:
	ld a,(vdrip_packet_body + 1)
	cp #PACKET_KEYBOARD_EVENT
	jr z,vdrip_key_type_ok

	; DEBUG:
	; TYPE reject. Show the unexpected TYPE byte as sprite_y.
	; This tells us what body[1] actually contains.
	ld a,(vdrip_packet_body + 1)
	and #0x7f
	ld (sprite_y),a

	ld a,#0x05		; light blue = TYPE reject
	ld (sprite_color),a
	ret

vdrip_key_type_ok:
	; Mark: valid keyboard event body shape.
	ld a,#0x0b
	ld (sprite_color),a

	; For visibility, prove we recognized a keyboard packet body.
	ld a,#0x01
	ld (vdrip_rx_seen_flag),a

	; Only move on key-down.
	ld a,(vdrip_packet_body + 2)
	and #KEY_EVENT_FLAG_DOWN
	cp #KEY_EVENT_FLAG_DOWN
	jr z,vdrip_key_down_ok

	; Valid keyboard packet, but not key-down.
	ld a,#0x0e
	ld (sprite_color),a
	ret

vdrip_key_down_ok:
	; Check ASCII candidate.
	ld a,(vdrip_packet_body + 3)
	call vdrip_apply_key_candidate
	ret z

	; Check special-key candidate.
	ld a,(vdrip_packet_body + 4)
	cp #KEY_SPECIAL_UP
	jp z,vdrip_apply_key_up

	cp #KEY_SPECIAL_DOWN
	jp z,vdrip_apply_key_down

	; Key-down packet, but not W/S and not special up/down.
	ld a,#0x08
	ld (sprite_color),a
	ret


vdrip_apply_key_candidate:
	cp #KEY_ASCII_W
	jr z,vdrip_apply_key_up

	cp #KEY_ASCII_UPPER_W
	jr z,vdrip_apply_key_up

	cp #KEY_ASCII_S
	jr z,vdrip_apply_key_down

	cp #KEY_ASCII_UPPER_S
	jr z,vdrip_apply_key_down

	or #0xff
	ret

vdrip_apply_key_up:
	call vdrip_move_smiley_up
	xor a
	ret

vdrip_apply_key_down:
	call vdrip_move_smiley_down
	xor a
	ret


vdrip_parse_reset:
	xor a
	ld (vdrip_parse_state),a
	ret

vdrip_transport_putc:
	push af

vdrip_transport_wait_tx:
	in a,(VDRIP_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,vdrip_transport_wait_tx

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
	jr z,vdrip_send_packet_send_crc
	ld b,a
vdrip_send_packet_payload_loop:
	ld a,(hl)
	call vdrip_transport_putc
	inc hl
	djnz vdrip_send_packet_payload_loop

vdrip_send_packet_send_crc:
	ld a,(packet_crc_store)
	call vdrip_transport_putc

	pop hl
	pop de
	pop bc
	ret

vdrip_debug_classify_body_byte:
	cp #0x07
	jr z,vdrip_debug_byte_07

	cp #0x05
	jr z,vdrip_debug_byte_05

	cp #0x06
	jr z,vdrip_debug_byte_06

	cp #KEY_ASCII_S
	jr z,vdrip_debug_byte_73

	cp #KEY_ASCII_W
	jr z,vdrip_debug_byte_77

	cp #0x00
	jr z,vdrip_debug_byte_00

	cp #0xa6
	jr z,vdrip_debug_byte_a6

	ld a,#DBG_TILE_OTHER
	ret

vdrip_debug_byte_07:
	ld a,#DBG_TILE_07
	ret

vdrip_debug_byte_05:
	ld a,#DBG_TILE_05
	ret

vdrip_debug_byte_06:
	ld a,#DBG_TILE_06
	ret

vdrip_debug_byte_73:
	ld a,#DBG_TILE_73
	ret

vdrip_debug_byte_77:
	ld a,#DBG_TILE_77
	ret

vdrip_debug_byte_00:
	ld a,#DBG_TILE_00
	ret

vdrip_debug_byte_a6:
	ld a,#DBG_TILE_A6
	ret	

vdrip_debug_capture_body:
	ld a,(vdrip_parse_len_store)
	cp #DEBUG_PACKET_MAX + 1
	jr c,vdrip_debug_capture_len_ok
	ld a,#DEBUG_PACKET_MAX

vdrip_debug_capture_len_ok:
	ld (debug_body_count),a

	ld b,a
	ld hl,#vdrip_packet_body
	ld de,#debug_body_tiles

vdrip_debug_capture_loop:
	ld a,b
	or a
	jr z,vdrip_debug_capture_done

	ld a,(hl)
	call vdrip_debug_classify_body_byte
	ld (de),a

	inc hl
	inc de
	djnz vdrip_debug_capture_loop

vdrip_debug_capture_done:
	ld a,#0x01
	ld (debug_body_dirty),a
	ret	

; ---------------------------------------------------------------------------
; vdrip_rts_assert_raw
;
; Tell host/proxy that Zephyr is ready to receive more bytes.
; Direct SIO0/B WR5 access for this monitor-loaded test app.
; ---------------------------------------------------------------------------

vdrip_rts_assert_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_ON
	out (VDRIP_CTRL),a
	xor a
	ret


; ---------------------------------------------------------------------------
; vdrip_rts_release_raw
;
; Tell host/proxy to stop sending bytes.
; Direct SIO0/B WR5 access for this monitor-loaded test app.
; ---------------------------------------------------------------------------

vdrip_rts_release_raw:
	ld a,#0x05
	out (VDRIP_CTRL),a
	ld a,#SIO0B_WR5_RTS_OFF
	out (VDRIP_CTRL),a
	xor a
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

; ---------------------------------------------------------------------------
; vdrip_rx_maybe_release_rts
;
; Called after enqueueing RX bytes.
; If RX ring is near full, deassert RTS so host pauses.
; ---------------------------------------------------------------------------

vdrip_rx_maybe_release_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret nz				; already released

	ld a,(vdrip_rx_count)
	cp #VDRIP_RX_RTS_HIGH_WATER
	ret c				; count < high water

	call vdrip_rts_release_raw

	ld a,#0x01
	ld (vdrip_rx_rts_released),a
	ret


; ---------------------------------------------------------------------------
; vdrip_rx_maybe_assert_rts
;
; Called after foreground drains RX bytes.
; If RX ring has enough room again, assert RTS so host resumes.
; ---------------------------------------------------------------------------

vdrip_rx_maybe_assert_rts:
	ld a,(vdrip_rx_rts_released)
	or a
	ret z				; already asserted

	ld a,(vdrip_rx_count)
	cp #VDRIP_RX_RTS_LOW_WATER + 1
	ret nc				; count > low water

	call vdrip_rts_assert_raw

	xor a
	ld (vdrip_rx_rts_released),a
	ret

send_full_state:
	call vdrip_send_reset
	call vdrip_send_ping
	call init_vdp_graphics1
	call init_background
	call init_sprite_tables
	call update_sprite_position
	call vdrip_send_frame_mark
	ret

debug_draw_packet_body:
	ld a,(debug_body_dirty)
	or a
	ret z

	xor a
	ld (debug_body_dirty),a

	; Clear second row.
	ld hl,#NAME_TABLE + 0x20
	call vdp_set_vram_write_addr

	ld b,#0x20
debug_packet_clear_loop:
	xor a
	call vdp_write_data_byte
	djnz debug_packet_clear_loop

	; Draw captured body byte classes on second row.
	ld a,(debug_body_count)
	or a
	ret z

	ld b,a
	ld hl,#NAME_TABLE + 0x20
	call vdp_set_vram_write_addr
	ld hl,#debug_body_tiles

debug_packet_draw_loop:
	ld a,(hl)
	call vdp_write_data_byte
	inc hl
	djnz debug_packet_draw_loop

	ret

debug_write_solid_tile:
	; Input: A = tile id
	ld h,#0x00
	ld l,a
	add hl,hl
	add hl,hl
	add hl,hl
	call vdp_set_vram_write_addr

	ld b,#0x08
debug_write_solid_tile_loop:
	ld a,#0xff
	call vdp_write_data_byte
	djnz debug_write_solid_tile_loop
	ret


debug_init_tiles:
	ld a,#DBG_TILE_07
	call debug_write_solid_tile
	ld a,#DBG_TILE_05
	call debug_write_solid_tile
	ld a,#DBG_TILE_06
	call debug_write_solid_tile
	ld a,#DBG_TILE_73
	call debug_write_solid_tile
	ld a,#DBG_TILE_77
	call debug_write_solid_tile
	ld a,#DBG_TILE_00
	call debug_write_solid_tile
	ld a,#DBG_TILE_A6
	call debug_write_solid_tile
	ld a,#DBG_TILE_OTHER
	call debug_write_solid_tile
	ret

debug_init_colors:
	ld hl,#COLOR_TABLE + 1
	call vdp_set_vram_write_addr

	; group 1: DBG_TILE_07
	ld a,#0xf4
	call vdp_write_data_byte

	; group 2: DBG_TILE_05
	ld a,#0xe4
	call vdp_write_data_byte

	; group 3: DBG_TILE_06
	ld a,#0xa4
	call vdp_write_data_byte

	; group 4: DBG_TILE_73
	ld a,#0x24
	call vdp_write_data_byte

	; group 5: DBG_TILE_77
	ld a,#0xc4
	call vdp_write_data_byte

	; group 6: DBG_TILE_00
	ld a,#0x84
	call vdp_write_data_byte

	; group 7: DBG_TILE_A6
	ld a,#0xb4
	call vdp_write_data_byte

	; group 8: DBG_TILE_OTHER
	ld a,#0x64
	call vdp_write_data_byte

	ret	


; Graphics I, display on, 16 KiB VRAM, 8x8 sprites.
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

init_background:
	; Pattern 0 and 1.
	ld hl,#PATTERN_TABLE
	call vdp_set_vram_write_addr

	ld b,#0x08
init_pattern0_loop:
	xor a
	call vdp_write_data_byte
	djnz init_pattern0_loop

	ld b,#0x08
	ld e,#0xaa
init_pattern1_loop:
	ld a,e
	call vdp_write_data_byte
	ld a,e
	xor #0xff
	ld e,a
	djnz init_pattern1_loop

	; Debug tile patterns.
	; IMPORTANT: this changes the VRAM write address.
	call debug_init_tiles

	; Color table default.
	ld hl,#COLOR_TABLE
	call vdp_set_vram_write_addr
	ld b,#0x20
init_color_loop:
	ld a,#0xf4
	call vdp_write_data_byte
	djnz init_color_loop

	; Debug tile color groups.
	; IMPORTANT: this also changes the VRAM write address.
	call debug_init_colors

	; Name table.
	ld hl,#NAME_TABLE
	call vdp_set_vram_write_addr
	ld b,#0x18
	ld d,#0x00

init_name_row:
	ld c,#0x20
	ld e,d
init_name_col:
	ld a,e
	call vdp_write_data_byte
	ld a,e
	xor #0x01
	ld e,a
	dec c
	jr nz,init_name_col
	ld a,d
	xor #0x01
	ld d,a
	djnz init_name_row
	ret

init_sprite_tables:
	call write_smiley_sprite_pattern
	; Initialize attributes once; animation rewrites only this small area.
	call update_sprite_position
	ret

write_smiley_sprite_pattern:
	ld hl,#SPRITE_PATTERN_TABLE
	call vdp_set_vram_write_addr
	ld hl,#smiley_sprite_patterns
	ld bc,#0x0010
	call vdp_write_data_block
	ret

; Update two overlaid 8x8 sprites: yellow face plus dark facial details.
; Per frame this writes only sprite attribute bytes, not screen/tile data.
update_sprite_position:
	ld hl,#SPRITE_ATTRIBUTE_TABLE
	call vdp_set_vram_write_addr

	ld a,(sprite_y)
	call vdp_write_data_byte
	ld a,(sprite_x)
	call vdp_write_data_byte
	xor a
	call vdp_write_data_byte
	ld a,(sprite_color)
	call vdp_write_data_byte

	ld a,(sprite_y)
	call vdp_write_data_byte
	ld a,(sprite_x)
	call vdp_write_data_byte
	ld a,#0x01
	call vdp_write_data_byte
	ld a,#0x04		; dark blue details
	call vdp_write_data_byte

	ld a,#0xd0		; sprite terminator
	call vdp_write_data_byte
	ret

delay_before_start:
	ld b,#STARTUP_DELAY_UNITS
delay_before_start_loop:
	call delay_unit
	djnz delay_before_start_loop
	ret

delay_frame:
	ld b,#0x03
delay_frame_loop:
	call delay_unit
	djnz delay_frame_loop
	ret

delay_unit:
	ld de,#0xffff
delay_unit_loop:
	dec de
	ld a,d
	or e
	jr nz,delay_unit_loop
	ret

smiley_sprite_patterns:
	; Sprite 0: yellow face silhouette.
	.db 0x3c,0x7e,0xff,0xff,0xff,0xff,0x7e,0x3c
	; Sprite 1: overlaid eyes and smile.
	.db 0x00,0x00,0x24,0x24,0x00,0x42,0x3c,0x00

sprite_x:
	.db 0x00
sprite_y:
	.db SPRITE_Y_START
sprite_color:
	.db SPRITE_COLOR_NORMAL
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
vdrip_rx_head:
	.db 0x00

vdrip_rx_tail:
	.db 0x00

vdrip_rx_count:
	.db 0x00

vdrip_rx_buffer:
	.ds VDRIP_RX_BUFFER_SIZE

vdrip_rx_seen_flag:
	.db 0x00
vdrip_parse_state:
	.db VDRIP_RX_WAIT_SYNC0

vdrip_parse_len_store:
	.db 0x00

vdrip_parse_remaining:
	.db 0x00

vdrip_parse_payload_index:
	.db 0x00

vdrip_packet_body:
	.ds VDRIP_PACKET_BODY_MAX

vdrip_rx_rts_released:
	.db 0x00
vdrip_crc_computed:
	.db 0x00

vdrip_crc_received:
	.db 0x00

debug_body_count:
	.db 0x00

debug_body_dirty:
	.db 0x00

debug_body_tiles:
	.ds DEBUG_PACKET_MAX