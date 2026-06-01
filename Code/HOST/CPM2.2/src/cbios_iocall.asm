; Zephyr extended BIOS IOCALL transport.
;
; IOCALL is a BIOS-owned SIO1/A command/reply transaction. The caller owns the
; request block and TX/RX payload buffers in currently visible application
; memory. This module does not reserve a BIOS-side request block, payload
; buffers, or persistent IOCALL pointer state.

	.globl IOCALL
	.globl IOCTRL_CODE_START,IOCTRL_CODE_END
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
	push de
	pop ix

	xor a
	ld IOCALL_STATUS(ix),a
	ld IOCALL_RX_LEN(ix),a

	ld a,IOCALL_TX_LEN(ix)
	cp #0x81
	jr nc,IOCALL_BAD_LEN
	ld a,IOCALL_RX_MAX(ix)
	cp #0x81
	jr nc,IOCALL_BAD_LEN

	ld l,IOCALL_TX_PTR(ix)
	ld h,IOCALL_TX_PTR + 1(ix)

	call sio1_ioc_rts_assert
	or a
	jr nz,IOCALL_FAIL_WITH_RTS

	; Send request header: CHAN CMD TX_LEN.
	ld c,IOCALL_CHAN(ix)
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld c,IOCALL_CMD(ix)
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld c,IOCALL_TX_LEN(ix)
	call sio1_ioc_put_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS

	; Send caller-owned TX payload directly from application memory.
	ld a,IOCALL_TX_LEN(ix)
	or a
	jr z,IOCALL_TX_DONE
	ld b,a
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
	ld IOCALL_STATUS(ix),c

	call sio1_ioc_get_byte
	or a
	jr nz,IOCALL_FAIL_WITH_RTS
	ld IOCALL_RX_LEN(ix),c
	ld b,c
	ld a,IOCALL_RX_MAX(ix)
	cp b
	jr c,IOCALL_BAD_REPLY_WITH_RTS

	; Receive reply payload directly into caller-owned application memory.
	ld l,IOCALL_RX_PTR(ix)
	ld h,IOCALL_RX_PTR + 1(ix)
	ld a,b
	or a
	jr z,IOCALL_RX_DONE
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

	.area CODE (ABS)
