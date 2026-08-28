; IOC_RESET.COM — Send a RESET command to the IO Controller.
;
; Uses the IOCALL BIOS extension at DA3Fh (ZBIOS_EXT_BASE + 0Ch).
; CMD_RESET (02h) causes the MCU to assert the host reset lines (~10 ms)
; and then self-reset.  The machine is expected to reboot before IOCALL
; receives a reply, so a timeout or non-return from IOCALL is the normal
; outcome.  See cbios_iocall.asm RESET note.
;
; Frame layout (32 bytes, Z80 -> MCU):
;   byte  0  command class:  CMD_RESET = 02h
;   byte  1  sequence:       01h
;   byte  2  status/flags:   00h
;   byte  3  payload length: 00h
;   bytes 4-31: zeroes
;
; If IOCALL returns at all:
;   A = IOC_XPORT_TIMEOUT (01h) — transport timed out (reset may be in progress)
;   A = IOC_XPORT_OK      (00h) — unexpected; MCU responded without resetting

	.module ioc_reset
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_PRINT	= 0x09		; print '$'-terminated string at DE
IOCALL		= 0xDA3F	; BIOS extended entry: IOC compatibility transport

CMD_RESET	= 0x02

start:
	ld de,#msg_resetting
	ld c,#BDOS_PRINT
	call BDOS

	; Zero the entire TX frame before filling header fields.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx

	; Fill frame header.
	ld hl,#tx_frame
	ld a,#CMD_RESET
	ld (hl),a		; byte 0: command class
	inc hl
	ld a,#0x01
	ld (hl),a		; byte 1: sequence number

	; Issue IOCALL.  Normal outcome: machine resets; we do not return here.
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL

	; If we reach here the MCU returned a frame instead of resetting us.
	or a
	jr nz,timed_out

	; A = IOC_XPORT_OK — MCU replied without asserting reset.
	ld de,#msg_no_reset
	ld c,#BDOS_PRINT
	call BDOS
	ret

timed_out:
	; A = IOC_XPORT_TIMEOUT — expected if the host was reset mid-exchange.
	ld de,#msg_timeout
	ld c,#BDOS_PRINT
	call BDOS
	ret

msg_resetting:
	.ascii "Resetting system..."
	.db 0x0d, 0x0a, '$'
msg_timeout:
	.ascii "Timed out (reset in progress)."
	.db 0x0d, 0x0a, '$'
msg_no_reset:
	.ascii "Warning: MCU replied without asserting reset."
	.db 0x0d, 0x0a, '$'

tx_frame:
	.ds 32
rx_frame:
	.ds 32
