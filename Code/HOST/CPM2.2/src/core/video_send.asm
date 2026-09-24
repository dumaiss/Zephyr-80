; Zephyr-80 extended BIOS entry points.
;
; VIDEO_SEND: selected-console raw video compatibility entry point.
; Code base: CBIOS_BIOS_EXT_CODE_BASE (DF50h).

	.globl VIDEO_SEND
	.globl BIOS_EXT_CODE_START,BIOS_EXT_CODE_END,BIOS_CODE_END

	.globl console_backend_send_frame
	.globl console_backend_data_write_block
	.globl console_backend_reset_display

VIDEO_TYPE_VDP_DATA_BLOCK = 0x0b
VIDEO_SINGLE_PAYLOAD_MAX  = 0x10

	.area CODE (ABS)
	.org CBIOS_BIOS_EXT_CODE_BASE

BIOS_EXT_CODE_START:

; VIDEO_SEND
; Extended BIOS call: send a raw video request through the selected backend.
;
; Inputs:
;   A  = VDrip packet type
;   HL = payload pointer
;   BC = payload length
;
; Special:
;   A = 00h or FFh: reset/reinitialize the selected display backend.
;   HL and BC are ignored for the reset case.
;
; Returns:
;   A = 00h   success
;   A != 00h  error
;
; Clobbers: AF, BC, DE, HL. Preserves IX, IY. Do not call from an ISR.
; WBOOT reinitializes the selected console after a transient program takes over
; the display. Non-block requests retain the historical 16-byte limit.
VIDEO_SEND:
	or a
	jr z,video_send_reset
	inc a
	jr z,video_send_reset
	dec a

	push af
	cp #VIDEO_TYPE_VDP_DATA_BLOCK
	jr nz,video_send_single
	pop af
	call console_backend_data_write_block
	xor a
	ret

video_send_single:
	ld a,b
	or a
	jr nz,video_send_length_error
	ld a,c
	cp #(VIDEO_SINGLE_PAYLOAD_MAX + 1)
	jr nc,video_send_length_error
	pop af
	jp console_backend_send_frame

video_send_length_error:
	pop af
	ld a,#BIOS_ERR
	ret

video_send_reset:
	call console_backend_reset_display
	xor a
	ret

BIOS_EXT_CODE_END:
BIOS_CODE_END:

	.area CODE (ABS)
