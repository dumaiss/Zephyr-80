; Phase 10 Zephyr-80 SIO0 host serial and COFFEE-IO stub test
;
; Source format: SDCC/ASxxxx Z80 assembly, assembled with sdasz80.
; zephyr80 maps the real MAME Z80SIOs using cd_ba order:
; A0 = B/A and A1 = C/D, so each SIO block is DA, DB, CA, CB.

	.module zephyr80
	.optsdcc -mz80

	.area _CODE

	.globl reset

MEM_LATCH	= 0x00

SIO0A_DATA	= 0x20
SIO0B_DATA	= 0x21
SIO0A_CTRL	= 0x22
SIO0B_CTRL	= 0x23

SIO1A_DATA	= 0x30
SIO1B_DATA	= 0x31
SIO1A_CTRL	= 0x32
SIO1B_CTRL	= 0x33

RR0_RX_AVAIL	= 0x01
RR0_TX_EMPTY	= 0x04

REQ_SYNC	= 0x55
RESP_SYNC	= 0xaa

CMD_PING	= 0x00
CMD_ECHO	= 0x01
CMD_VERSION	= 0x02

pkt_cmd		= 0x6000
pkt_chk		= 0x6001
resp_cmd	= 0x6002
resp_len	= 0x6003
resp_chk	= 0x6004
fail_code	= 0x6005
fail_got	= 0x6006
resp_buf	= 0x6010

reset:
	di
	ld	sp, #0xffff
	xor	a, a
	out	(#MEM_LATCH), a
	ld	a, #0x3f
	ld	(fail_code), a

	call	init_sio0a
	call	init_sio0b
	call	init_sio1a
	call	init_sio1b

	ld	hl, #msg_boot
	call	sio0a_puts

	ld	hl, #msg_sio0b
	call	sio0b_puts

	call	coffee_ping
	call	coffee_echo
	call	coffee_version

	ld	hl, #msg_pass
	call	sio0a_puts

done:
	halt
	jr	done

init_sio0a:
	ld	c, #SIO0A_CTRL
	call	sio_init_async_8n1
	ret

init_sio0b:
	ld	c, #SIO0B_CTRL
	call	sio_init_async_8n1
	ret

; SIO1 is the internal sync-mode link on real hardware.  Phase 10 keeps the
; channel in async-compatible 8N1 mode so the protocol stub can validate CPU
; access through the real MAME Z80SIO.
init_sio1a:
	ld	c, #SIO1A_CTRL
	call	sio_init_async_8n1
	ret

init_sio1b:
	ld	c, #SIO1B_CTRL
	call	sio_init_async_8n1
	ret

; C = control port.  Minimal conventional async 8N1 setup for MAME Z80SIO.
sio_init_async_8n1:
	ld	a, #0x18	; WR0: channel reset
	out	(c), a

	ld	a, #0x04	; select WR4
	out	(c), a
	ld	a, #0x44	; x16 clock, 1 stop bit, no parity
	out	(c), a

	ld	a, #0x03	; select WR3
	out	(c), a
	ld	a, #0xc1	; receiver enable, 8-bit receive
	out	(c), a

	ld	a, #0x05	; select WR5
	out	(c), a
	ld	a, #0xea	; transmitter enable, 8-bit transmit, RTS/DTR
	out	(c), a
	ret

sio0a_putc:
	push	af
sio0a_wait_tx:
	in	a, (#SIO0A_CTRL)
	bit	2, a
	jr	Z, sio0a_wait_tx
	pop	af
	out	(#SIO0A_DATA), a
	ret

sio0a_puts:
	ld	a, (hl)
	or	a, a
	ret	Z
	call	sio0a_putc
	inc	hl
	jr	sio0a_puts

sio0b_putc:
	push	af
sio0b_wait_tx:
	in	a, (#SIO0B_CTRL)
	bit	2, a
	jr	Z, sio0b_wait_tx
	pop	af
	out	(#SIO0B_DATA), a
	ret

sio0b_puts:
	ld	a, (hl)
	or	a, a
	ret	Z
	call	sio0b_putc
	inc	hl
	jr	sio0b_puts

sio1a_putc:
	push	af
sio1a_wait_tx:
	in	a, (#SIO1A_CTRL)
	bit	2, a
	jr	Z, sio1a_wait_tx
	pop	af
	out	(#SIO1A_DATA), a
	ret

sio1a_getc:
sio1a_wait_rx:
	in	a, (#SIO1A_CTRL)
	bit	0, a
	jr	Z, sio1a_wait_rx
	in	a, (#SIO1A_DATA)
	ret

; A = command, HL = payload pointer, B = payload length.
coffee_send_packet:
	ld	(pkt_cmd), a
	ld	a, #REQ_SYNC
	call	sio1a_putc

	ld	a, (pkt_cmd)
	call	sio1a_putc

	ld	a, b
	call	sio1a_putc

	ld	a, (pkt_cmd)
	add	a, b
	ld	(pkt_chk), a

coffee_send_payload:
	ld	a, b
	or	a, a
	jr	Z, coffee_send_chk

	ld	a, (hl)
	call	sio1a_putc

	push	hl
	ld	hl, #pkt_chk
	add	a, (hl)
	ld	(hl), a
	pop	hl

	inc	hl
	dec	b
	jr	coffee_send_payload

coffee_send_chk:
	ld	a, (pkt_chk)
	call	sio1a_putc
	ret

; D = expected command.  Returns B = response length and HL = resp_buf.
coffee_recv_response:
	call	sio1a_getc
	ld	(fail_got), a
	ld	a, #0x53
	ld	(fail_code), a
	ld	a, (fail_got)
	cp	#RESP_SYNC
	jp	NZ, fail

	call	sio1a_getc
	ld	(fail_got), a
	ld	a, #0x43
	ld	(fail_code), a
	ld	a, (fail_got)
	cp	d
	jp	NZ, fail
	ld	(resp_cmd), a

	call	sio1a_getc
	ld	b, a
	ld	(resp_len), a

	ld	a, (resp_cmd)
	add	a, b
	ld	(resp_chk), a

	ld	hl, #resp_buf
	ld	c, b

coffee_read_payload:
	ld	a, c
	or	a, a
	jr	Z, coffee_read_chk

	call	sio1a_getc
	ld	(hl), a

	push	hl
	ld	hl, #resp_chk
	add	a, (hl)
	ld	(hl), a
	pop	hl

	inc	hl
	dec	c
	jr	coffee_read_payload

coffee_read_chk:
	call	sio1a_getc
	ld	c, a
	ld	(fail_got), a
	ld	a, #0x58
	ld	(fail_code), a
	ld	a, (resp_chk)
	cp	c
	jp	NZ, fail

	ld	hl, #resp_buf
	ld	a, (resp_len)
	ld	b, a
	ret

coffee_ping:
	ld	a, #CMD_PING
	ld	hl, #empty_payload
	ld	b, #0
	call	coffee_send_packet

	ld	d, #CMD_PING
	call	coffee_recv_response

	ld	a, b
	ld	(fail_got), a
	ld	a, #0x4c
	ld	(fail_code), a
	ld	a, (fail_got)
	cp	#2
	jp	NZ, fail

	ld	a, (resp_buf)
	ld	(fail_got), a
	ld	a, #0x4f
	ld	(fail_code), a
	ld	a, (fail_got)
	cp	#0x4f
	jp	NZ, fail

	ld	a, (resp_buf+1)
	ld	(fail_got), a
	ld	a, #0x4b
	ld	(fail_code), a
	ld	a, (fail_got)
	cp	#0x4b
	jp	NZ, fail
	ret

coffee_echo:
	ld	a, #CMD_ECHO
	ld	hl, #echo_payload
	ld	b, #echo_len
	call	coffee_send_packet

	ld	d, #CMD_ECHO
	call	coffee_recv_response

	ld	a, b
	cp	#echo_len
	jp	NZ, fail

	ld	hl, #resp_buf
	ld	de, #echo_payload
	ld	b, #echo_len

coffee_echo_compare:
	ld	a, (de)
	cp	(hl)
	jp	NZ, fail
	inc	hl
	inc	de
	djnz	coffee_echo_compare
	ret

coffee_version:
	ld	a, #CMD_VERSION
	ld	hl, #empty_payload
	ld	b, #0
	call	coffee_send_packet

	ld	d, #CMD_VERSION
	call	coffee_recv_response

	ld	hl, #msg_version
	call	sio0a_puts

	ld	hl, #resp_buf
coffee_version_print:
	ld	a, b
	or	a, a
	jr	Z, coffee_version_done
	ld	a, (hl)
	call	sio0a_putc
	inc	hl
	dec	b
	jr	coffee_version_print

coffee_version_done:
	ld	a, #0x0a
	call	sio0a_putc
	ret

fail:
	ld	hl, #msg_fail
	call	sio0a_puts
	ld	a, (fail_code)
	call	sio0a_putc
	ld	a, #0x20
	call	sio0a_putc
	ld	a, (fail_got)
	call	print_hex_a
	ld	a, #0x0a
	call	sio0a_putc

fail_loop:
	halt
	jr	fail_loop

print_hex_a:
	push	af
	rrca
	rrca
	rrca
	rrca
	call	print_hex_nibble
	pop	af
print_hex_nibble:
	and	#0x0f
	add	a, #0x30
	cp	#0x3a
	jr	C, print_hex_digit
	add	a, #0x07
print_hex_digit:
	call	sio0a_putc
	ret

msg_boot:
	.ascii	"Zephyr-80 Phase 10 serial/coffeeio test"
	.db	0x0a, 0x00

msg_sio0b:
	.ascii	"SIO0-B external channel alive"
	.db	0x0a, 0x00

msg_version:
	.ascii	"COFFEE-IO version: "
	.db	0x00

msg_pass:
	.db	0x0a
	.ascii	"PASS"
	.db	0x0a, 0x00

msg_fail:
	.db	0x0a
	.ascii	"FAIL"
	.db	0x0a, 0x00

empty_payload:
	.db	0

echo_payload:
	.ascii	"abc"
echo_len = 3
