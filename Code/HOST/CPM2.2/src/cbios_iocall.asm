; Zephyr extended BIOS IOCALL transport.
;
; IOCALL is a BIOS-owned SIO1/A command/reply transaction. The caller owns the
; request block and TX/RX payload buffers in currently visible application
; memory. This module keeps only small pointer/length state; it does not reserve
; a BIOS-side request block or payload buffers.

	.globl IOCALL
	.globl IOCTRL_CODE_START,IOCTRL_CODE_END
	.globl IOCTRL_STATE_START,IOCTRL_STATE_END
	.globl IOCALL_REQ_PTR_STATE,IOCALL_TX_PTR_STATE,IOCALL_RX_PTR_STATE
	.globl IOCALL_TX_LEN_STATE,IOCALL_RX_MAX_STATE,IOCALL_RX_LEN_STATE
	.globl sio1_ioc_rts_assert,sio1_ioc_rts_release
	.globl sio1_ioc_put_byte,sio1_ioc_get_byte

	.area CODE (ABS)
	.org CBIOS_IOCTRL_CODE_BASE

IOCTRL_CODE_START:

; IOCALL
; In:
;   DE = pointer to caller-owned IOCALL request block in visible application RAM.
; Out:
;   A = BIOS transport/API status.
; Request protocol:
;   TX: CHAN CMD LEN PAYLOAD...
;   RX: STATUS LEN PAYLOAD...
IOCALL:
	ld (IOCALL_REQ_PTR_STATE),de

	; Clear caller-visible completion fields before starting.
	ld h,d
	ld l,e
	ld de,#IOCALL_STATUS
	add hl,de
	xor a
	ld (hl),a
	inc hl
	ld (hl),a

	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_TX_LEN
	add hl,de
	ld a,(hl)
	cp #0x81
	jp nc,IOCALL_BAD_LEN
	ld (IOCALL_TX_LEN_STATE),a

	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_RX_MAX
	add hl,de
	ld a,(hl)
	cp #0x81
	jp nc,IOCALL_BAD_LEN
	ld (IOCALL_RX_MAX_STATE),a

	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_TX_PTR
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (IOCALL_TX_PTR_STATE),de

	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_RX_PTR
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld (IOCALL_RX_PTR_STATE),de

	call sio1_ioc_rts_assert
	or a
	jp nz,IOCALL_FAIL_WITH_RTS

	; Send request header: CHAN CMD TX_LEN.
	ld hl,(IOCALL_REQ_PTR_STATE)
	ld c,(hl)
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS

	ld hl,(IOCALL_REQ_PTR_STATE)
	inc hl
	ld c,(hl)
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS

	ld a,(IOCALL_TX_LEN_STATE)
	ld c,a
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS

	; Send caller-owned TX payload directly from application memory.
	ld a,(IOCALL_TX_LEN_STATE)
	or a
	jr z,IOCALL_TX_DONE
	ld b,a
	ld hl,(IOCALL_TX_PTR_STATE)
IOCALL_TX_LOOP:
	ld c,(hl)
	push bc
	push hl
	call sio1_ioc_put_byte
	pop hl
	pop bc
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	inc hl
	djnz IOCALL_TX_LOOP
IOCALL_TX_DONE:

	; Receive response header: STATUS RX_LEN.
	call sio1_ioc_get_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld a,c
	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_STATUS
	add hl,de
	ld (hl),a

	call sio1_ioc_get_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld a,c
	ld (IOCALL_RX_LEN_STATE),a
	ld b,a
	ld a,(IOCALL_RX_MAX_STATE)
	cp b
	jr c,IOCALL_BAD_REPLY_WITH_RTS

	; Receive reply payload directly into caller-owned application memory.
	ld a,(IOCALL_RX_LEN_STATE)
	or a
	jr z,IOCALL_RX_DONE
	ld b,a
	ld hl,(IOCALL_RX_PTR_STATE)
IOCALL_RX_LOOP:
	push bc
	push hl
	call sio1_ioc_get_byte
	ld e,c
	pop hl
	pop bc
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld (hl),e
	inc hl
	djnz IOCALL_RX_LOOP
IOCALL_RX_DONE:
	ld a,(IOCALL_RX_LEN_STATE)
	ld hl,(IOCALL_REQ_PTR_STATE)
	ld de,#IOCALL_RX_LEN
	add hl,de
	ld (hl),a

	call sio1_ioc_rts_release
	xor a
	ret

IOCALL_BAD_LEN:
	ld a,#BIOS_ERR_BAD_LEN
	ret

IOCALL_BAD_REPLY_WITH_RTS:
	ld a,#BIOS_ERR_BAD_REPLY

IOCALL_FAIL_WITH_RTS:
	ld b,a
	call sio1_ioc_rts_release
	ld a,b
	ret

IOCTRL_CODE_END:

	.area WORK (ABS)
	.org CBIOS_IOCTRL_WORK_AREA
IOCTRL_STATE_START:
IOCALL_REQ_PTR_STATE:
	.dw 0x0000
IOCALL_TX_PTR_STATE:
	.dw 0x0000
IOCALL_RX_PTR_STATE:
	.dw 0x0000
IOCALL_TX_LEN_STATE:
	.db 0x00
IOCALL_RX_MAX_STATE:
	.db 0x00
IOCALL_RX_LEN_STATE:
	.db 0x00
IOCTRL_STATE_END:

	.area CODE (ABS)
