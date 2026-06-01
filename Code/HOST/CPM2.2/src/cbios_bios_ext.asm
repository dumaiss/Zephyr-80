; Zephyr-80 extended BIOS entry points.
;
; VIDEO_SEND: raw VDrip display/VDP packet transport for CP/M programs.
; Code base: CBIOS_BIOS_EXT_CODE_BASE (DF50h).

	.globl VIDEO_SEND
	.globl BIOS_EXT_CODE_START,BIOS_EXT_CODE_END,BIOS_CODE_END

	.globl vdrip_send_packet
	.globl vdrip_data_write_block
	.globl vdrip_reset_display

	.area CODE (ABS)
	.org CBIOS_BIOS_EXT_CODE_BASE

BIOS_EXT_CODE_START:

; VIDEO_SEND
; Extended BIOS call: send a raw VDrip display/VDP packet.
;
; Inputs:
;   A  = VDrip packet type
;   HL = payload pointer
;   BC = payload length
;
; Special:
;   A = 00h or FFh: reset/reinitialize VDrip display backend.
;   HL and BC are ignored for the reset case.
;
; Returns:
;   A = 00h   success
;   A != 00h  error
;
; Clobbers: AF, BC, DE, HL.
; Preserves: IX, IY.
;
; Warning:
;   Raw VDP/display writes may desynchronize the BIOS console shadow buffer.
;   This call is intended for programs that take over the display while active.
;   WBOOT reinitializes the normal console display before returning to CP/M.
;
; Policy (first-pass):
;   PACKET_VDP_DATA_BLOCK payloads are chunked via vdrip_data_write_block;
;   BC may exceed VDRIP_PACKET_PAYLOAD_MAX for this type only.
;   All other types require BC <= VDRIP_PACKET_PAYLOAD_MAX (10h); larger
;   payloads return BIOS_ERR.
;   Storage packet types (0Dh-10h) are not filtered; this call is trusted
;   and intended for local CP/M programs only.
;   Do not call from interrupt context.
VIDEO_SEND:
	or a
	jr z, vs_reset
	inc a				; FFh wraps to 00h, sets Z
	jr z, vs_reset
	dec a				; restore packet type

	push af				; save type; comparisons clobber A

	cp #PACKET_VDP_DATA_BLOCK
	jr nz, vs_single

	; VDP data block: chunk any size through the existing helper.
	; vdrip_data_write_block input: HL = payload pointer, BC = length.
	pop af				; discard saved type
	call vdrip_data_write_block
	xor a
	ret

vs_single:
	; Single framed packet. BC must fit in one payload (max 10h bytes).
	ld a, b
	or a
	jr nz, vs_err_len		; B != 0 means BC > 255 > max
	ld a, c
	cp #VDRIP_PACKET_PAYLOAD_MAX + 1
	jr nc, vs_err_len

	ld b, c				; vdrip_send_packet: B = payload length
	pop af				; restore packet type to A
	call vdrip_send_packet		; A = type, B = len, HL = payload ptr
	xor a
	ret

vs_err_len:
	pop af				; balance stack
	ld a, #BIOS_ERR
	ret

vs_reset:
	call vdrip_reset_display
	xor a
	ret

BIOS_EXT_CODE_END:
BIOS_CODE_END:

	.area CODE (ABS)
