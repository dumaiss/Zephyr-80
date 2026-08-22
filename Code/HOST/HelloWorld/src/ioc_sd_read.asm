; IOC_SDRD.COM — Read block 0 from the SD card via the IO Controller.
;
; Uses the IOCALL BIOS extension at DA3Fh (ZBIOS_EXT_BASE + 0Ch), same as
; IOC_PING.COM.  Builds a 32-byte fixed frame with CMD_SD_READ (03h), issues it,
; and dumps the first 16 bytes of the card's block 0 as hex and ASCII.
;
; Frame layout (32 bytes, Z80 -> MCU):
;   byte  0  command class:  CMD_SD_READ = 03h
;   byte  1  sequence:       01h
;   byte  2  status/flags:   00h (filled by MCU in reply)
;   byte  3  payload length: 00h (the request carries no payload)
;   bytes 4-31               zeroes
;
; Reply (32 bytes, MCU -> Z80):
;   byte  0  RSP_SD_READ = 83h
;   byte  1  sequence echoed
;   byte  2  status: 00h OK, else an SD failure code (see below)
;   byte  3  payload length: 10h on success, 00h on failure
;   bytes 4-19  first 16 bytes of block 0
;
; On a FAT-formatted card those 16 bytes are the boot sector's jump instruction
; (EB xx 90) followed by the OEM name at offset 3 — "MSDOS5.0", "mkfs.fat" and
; so on — so a successful read is readable at a glance in the ASCII column.
;
; The first SD_READ after MCU reset also runs card initialisation, which can
; take up to about a second.  IOCALL's per-byte timeout is far longer than that,
; so the delay is invisible apart from the pause.

	.module ioc_sd_read
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02		; output char in E; no useful return
BDOS_PRINT	= 0x09		; print '$'-terminated string at DE
IOCALL		= 0xDA3F	; BIOS extended entry: IOC fixed-frame transport

CMD_SD_READ	= 0x03
RSP_SD_READ	= 0x83
SD_READ_BYTES	= 16

start:
	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; Zero the TX frame; fill the RX frame with A5h so untouched bytes are
	; obvious if the transport gives up part way through.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx:
	ld (hl),a
	inc hl
	djnz zero_rx

	; Fill frame header.  Bytes 2 and 3 stay zero: no status, no payload.
	ld hl,#tx_frame
	ld a,#CMD_SD_READ
	ld (hl),a		; byte 0: command class
	inc hl
	ld a,#0x01
	ld (hl),a		; byte 1: sequence number

	; IOCALL: HL = TX frame, DE = RX buffer.
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,xport_err

	; Reply class must be RSP_SD_READ.
	ld a,(rx_frame + 0)
	cp #RSP_SD_READ
	jr nz,bad_reply

	; Status byte non-zero means the MCU reached the card but the card said
	; no.  Report the code rather than dumping a payload that is not there.
	ld a,(rx_frame + 2)
	or a
	jr nz,sd_err

	; Length must be the 16 bytes we expect.
	ld a,(rx_frame + 3)
	cp #SD_READ_BYTES
	jr nz,bad_reply

	call dump_block_bytes

	ld de,#msg_ok
	ld c,#BDOS_PRINT
	call BDOS
	ret

xport_err:
	push af
	ld de,#msg_xport_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	call dump_rx_frame
	ret

sd_err:
	push af
	ld de,#msg_sd_err
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_sd_key
	ld c,#BDOS_PRINT
	call BDOS
	ret

bad_reply:
	push af
	ld de,#msg_bad_reply
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	call dump_rx_frame
	ret

; Print the 16 payload bytes as hex, then the same bytes as ASCII with
; unprintable characters shown as '.'.
; Clobbers: AF, BC, DE, HL.
dump_block_bytes:
	ld de,#msg_hex
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 4)
	ld b,#SD_READ_BYTES
dump_hex_loop:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz dump_hex_loop

	ld de,#msg_ascii
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#(rx_frame + 4)
	ld b,#SD_READ_BYTES
dump_ascii_loop:
	push bc
	ld a,(hl)
	inc hl
	push hl
	cp #0x20		; below space is unprintable
	jr c,dump_ascii_dot
	cp #0x7f		; DEL and above likewise
	jr nc,dump_ascii_dot
	jr dump_ascii_out
dump_ascii_dot:
	ld a,#0x2e		; '.'
dump_ascii_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	djnz dump_ascii_loop
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print the byte in A as two uppercase hex digits via BDOS CONOUT (fn 2).
; Clobbers: AF, BC, DE (via BDOS).
print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
	; fall through — this ret also serves as print_hex_byte's return
print_hex_nibble:
	add a,#0x30		; bias to '0'
	cp #0x3a		; past '9'?
	jr c,phx_out
	add a,#0x07		; shift into 'A'-'F'
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

; Dump the 32-byte IOCALL RX frame buffer as hex bytes.
; Useful after a transport error, where IOCALL may have stored the reply start
; and some partial body bytes before timing out.
; Clobbers: AF, BC, DE, HL.
dump_rx_frame:
	ld de,#msg_rx_dump
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame
	ld b,#32
dump_rx_loop:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz dump_rx_loop
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

msg_banner:
	.ascii "IOC SD READ - block 0"
	.db 0x0d, 0x0a, '$'
msg_hex:
	.ascii "HEX:"
	.db '$'
msg_ascii:
	.db 0x0d, 0x0a
	.ascii "ASC: "
	.db '$'
msg_ok:
	.ascii "OK"
	.db 0x0d, 0x0a, '$'
msg_xport_err:
	.ascii " - transport error 0x"
	.db '$'
msg_bad_reply:
	.ascii " - unexpected reply 0x"
	.db '$'
msg_sd_err:
	.ascii " - SD error 0x"
	.db '$'
msg_sd_key:
	.db 0x0d, 0x0a
	.ascii "10=no response 11=unusable 12=not ready 13=read failed 14=bus"
	.db 0x0d, 0x0a, '$'
msg_crlf:
	.db 0x0d, 0x0a, '$'
msg_rx_dump:
	.db 0x0d, 0x0a
	.ascii "RX:"
	.db '$'

tx_frame:
	.ds 32
rx_frame:
	.ds 32
