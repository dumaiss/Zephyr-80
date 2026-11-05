; license:BSD-3-Clause
; SIO1 lane probe program for the zephyr80 MAME machine.
;
; Runs from flash page 0: copies itself into SRAM bank 0, selects flat mode
; (latch 08h), installs an IM2 table at 8000h whose every entry counts an
; unexpected acknowledge, and serves operations the Lua probe
; (sio1_lanes.lua) posts in a mailbox.  The command-lane sequences are the
; KonaOS driver's (drivers/ioc/ioc_boot.c ioc_hw_init, ioc_io.asm
; ioc_io_wait_ready, ioc_io_tx and the receive arm); the receive side is a
; polling capture that records what the lane delivers byte by byte.
; Assembled with sdasz80/sdldz80/makebin by sio1_lanes.py.

CMD      = 0x7f00          ; operation, cleared when done
HUNT     = 0x7f01          ; tx: 1 = arm the receiver with Enter Hunt
PKTLEN   = 0x7f02          ; tx: packet length (PKT)
STALL_AT = 0x7f03          ; tx: stall after this many packet bytes (0 = none)
STALL_N  = 0x7f04          ; tx: stall length, 26 T-states a count (16-bit)
EVENT_AT = 0x7f06          ; rx: after this many captured bytes other than FFh (0 = none) ...
EVENT_N  = 0x7f07          ; ... pause this many counts of 26 T-states (16-bit) ...
EVENT    = 0x7f09          ; ... (EVENT 1), or channel-reset SIO1/B (EVENT 2)
PKT2LEN  = 0x7f0a          ; op 5: second packet length (PKT2)
WR1VAL   = 0x7f0b          ; op 1: WR1 value written to both channels
RESULT   = 0x7f10          ; 0 ok; 1 READY timeout; 2 send timeout; 3 no reply byte
RR0TX    = 0x7f11          ; RR0 right after the send (before the arm)
RR0END   = 0x7f12          ; RR0 at the end of the capture
RR1END   = 0x7f13          ; RR1 at the end of the capture
READYLO  = 0x7f14          ; 16-bit: READY polls that saw /DCDB deasserted
DRAINED  = 0x7f16          ; bytes the bounded drain removed
RAWLEN   = 0x7f19          ; bytes captured
NONFF    = 0x7f1d          ; bytes captured other than FFh
IRQS     = 0x7f20          ; unexpected interrupt acknowledges (kept across operations)
RR0STALL = 0x7f1b          ; RR0 at the end of a send stall
READYTX  = 0x7f1c          ; RR0 D3 sampled after the request was sent
BLEN     = 0x7f30          ; op 6/7: payload length (16-bit)
BHUNT    = 0x7f32          ; op 6: 1 = arm the bulk receiver with Enter Hunt
BNORTS   = 0x7f33          ; op 6/7: 1 = never assert the bulk RTS (no host)
BSTOP    = 0x7f34          ; op 6: stop reading after this many bytes (16-bit, 0 = all)
BRES     = 0x7f36          ; op 6/7: bulk result (ioc_io_bulk_read / write codes, 5 = abandoned)
BCOUNT   = 0x7f37          ; op 6: bytes of the stream (16-bit)
BCNT     = 0x7f39          ; op 6: the stream's count, low byte
BBLK     = 0x7f3a          ; op 6: ... and its 256-byte blocks
BURSTN   = 0x7f3b          ; op 8: requests left in the burst
BURST    = 0x7f3c          ; op 8: requests to send, back to back
BCRC     = 0x7f3d          ; op 9: the trailer bytes
BHDR     = 0x7f40          ; op 7: the five header bytes (LEN, TYPE, SEQ, STATUS)
BHEAD    = 0x3ffb          ; op 6: the five header bytes land here, the payload at BBUF
BBUF     = 0x4000          ; op 6/7/9: payload buffer (512 bytes)
BZPTR    = 0x7f50          ; op 9: payload destination pointer (the driver reads it from memory)
DOORBELL = 0x7f52          ; op 10: RR0 of SIO1/B after Reset External/Status
PAIRN    = 0x7f60          ; op 12: {port, value} pairs to write (count)
PAIRS    = 0x7f61          ; ... the pairs (up to 15)
SCAN     = 0x7f80          ; op 11: IN over E0h-FFh (32 bytes); op 12: IN FCh after each pair
SCAN2    = 0x7fa0          ; op 12: IN FFh after each pair
PKT      = 0x7e00
PKT2     = 0x7e40
RAW      = 0x7d00          ; up to 64 captured bytes, each with its empty polls
TABLE    = 0x8000

LATCH    = 0x00
SIO1AD   = 0x30
SIO1AC   = 0x31
SIO1BD   = 0x32
SIO1BC   = 0x33

	.area	PROBE (ABS)
	.org	0x0000
	jp	start

	.org	0x0100
start:
	di
	ld	hl,#0
	ld	de,#0
	ld	bc,#code_end
	ldir				; mode 00: flash page 0 -> SRAM bank 0
	ld	a,#0x08
	out	(LATCH),a		; flat mode, bank 0
	ld	sp,#0x7c00
	ld	hl,#TABLE
	ld	b,#0x81
fill:
	ld	(hl),#<unexpected
	inc	hl
	ld	(hl),#>unexpected
	inc	hl
	djnz	fill
	ld	a,#>TABLE
	ld	i,a
	im	2
	xor	a
	ld	(IRQS),a
	ld	(CMD),a

idle:
	ei
	ld	a,(CMD)
	or	a
	jr	z,idle
	di
	cp	#1
	jp	z,op_init
	cp	#4
	jp	z,op_exchange
	cp	#5
	jp	z,op_early
	cp	#6
	jp	z,op_read
	cp	#7
	jp	z,op_write
	cp	#8
	jp	z,op_burst
	cp	#9
	jp	z,op_zread
	cp	#10
	jp	z,op_doorbell
	cp	#11
	jp	z,op_ctrl_scan
	cp	#12
	jp	z,op_ctrl_pairs
done:
	xor	a
	ld	(CMD),a
	jr	idle

unexpected:
	push	af
	ld	a,(IRQS)
	inc	a
	ld	(IRQS),a
	pop	af
	ei
	reti

; ---------------------------------------------------------------- op 1
; ioc_hw_init and ioc_io_bulk_init, with WR1 from the mailbox.
op_init:
	ld	a,#0x18
	out	(SIO1BC),a
	ld	a,#0x01
	out	(SIO1BC),a
	ld	a,(WR1VAL)
	out	(SIO1BC),a
	ld	a,#0x04
	out	(SIO1BC),a
	ld	a,#0x30
	out	(SIO1BC),a
	ld	a,#0x07
	out	(SIO1BC),a
	ld	a,#0xff
	out	(SIO1BC),a
	ld	a,#0x03
	out	(SIO1BC),a
	ld	a,#0xc0
	out	(SIO1BC),a
	ld	a,#0x05
	out	(SIO1BC),a
	ld	a,#0x68
	out	(SIO1BC),a
	ld	a,#0x18
	out	(SIO1AC),a
	ld	a,#0x01
	out	(SIO1AC),a
	ld	a,(WR1VAL)
	out	(SIO1AC),a
	ld	a,#0x04
	out	(SIO1AC),a
	ld	a,#0x30
	out	(SIO1AC),a
	ld	a,#0x06
	out	(SIO1AC),a
	ld	a,#0xaa
	out	(SIO1AC),a
	ld	a,#0x07
	out	(SIO1AC),a
	ld	a,#0xaa
	out	(SIO1AC),a
	ld	a,#0x03
	out	(SIO1AC),a
	ld	a,#0xc9
	out	(SIO1AC),a
	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xe0
	out	(SIO1AC),a
	xor	a
	ld	(RESULT),a
	jp	done

; ---------------------------------------------------------------- op 10
; The HID doorbell as the guests sample it (KonaOS ioc_io_status_sample,
; ZSDOS hid_input_status): unlatch RR0, then read it; D5 is /CTSB.
op_doorbell:
	ld	a,#0x10
	out	(SIO1BC),a
	in	a,(SIO1BC)
	ld	(DOORBELL),a
	jp	done

; ---------------------------------------------------------------- op 11
; The controller latches as the guests read them: IN A,(C) over E0h-FFh
; into SCAN (KonaOS drivers/joy reads FCh and FFh).
op_ctrl_scan:
	ld	c,#0xe0
	ld	hl,#SCAN
ctrl_next:
	in	a,(c)
	ld	(hl),a
	inc	hl
	inc	c
	jr	nz,ctrl_next
	jp	done

; ---------------------------------------------------------------- op 12
; PAIRN {port, value} pairs, each an OUT (C),A followed by IN A,(FCh) into
; SCAN and IN A,(FFh) into SCAN2 (sound writes while the pads are read).
op_ctrl_pairs:
	ld	a,(PAIRN)
	ld	b,a
	ld	hl,#PAIRS
	ld	de,#SCAN
pair_next:
	ld	c,(hl)
	inc	hl
	ld	a,(hl)
	inc	hl
	out	(c),a
	in	a,(0xfc)
	ld	(de),a
	push	de
	ld	a,e
	add	a,#0x20
	ld	e,a
	in	a,(0xff)
	ld	(de),a
	pop	de
	inc	de
	djnz	pair_next
	jp	done

; ---------------------------------------------------------------- op 4
; One exchange: READY, the send, the receive arm, the capture.
op_exchange:
	call	clear_results
	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jr	nz,op_fail
	call	capture
op_fail:
	ld	(RESULT),a
	jp	done

; ---------------------------------------------------------------- op 5
; Two requests back to back: the second waits on READY while the first is
; served, and its reply is captured after the first reply filled the FIFO.
op_early:
	call	clear_results
	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jr	nz,op_fail
	ld	hl,#PKT2
	ld	a,(PKT2LEN)
	call	request
	jr	nz,op_fail
	call	capture
	jr	op_fail

; ---------------------------------------------------------------- op 8
; BURST requests (PKT) back to back, each reply captured; stops at the first
; request that goes unanswered.
op_burst:
	call	clear_results
	ld	a,(BURST)
	ld	(BURSTN),a
1$:	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jp	nz,op_fail
	call	capture
	or	a
	jp	nz,op_fail
	ld	a,(BURSTN)
	dec	a
	ld	(BURSTN),a
	jr	nz,1$
	xor	a
	jp	op_fail

clear_results:
	ld	hl,#RESULT
	ld	b,#16
1$:	ld	(hl),#0
	inc	hl
	djnz	1$
	ret

; In: HL = packet, A = length.  Out: Z and A = 0 sent; A = 1/2 otherwise.
request:
	push	hl
	push	af
	call	wait_ready
	pop	bc			; B = length
	pop	hl
	or	a
	ld	a,#1
	ret	nz
	call	send
	ret

; ioc_io_wait_ready: Reset External/Status, then RR0 D3; counts the polls
; that saw READY deasserted.
wait_ready:
	ld	de,#0
1$:	ld	a,#0x10
	out	(SIO1BC),a
	in	a,(SIO1BC)
	and	#0x08
	jr	nz,2$
	push	hl
	ld	hl,(READYLO)
	inc	hl
	ld	(READYLO),hl
	pop	hl
	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	inc	a
	ret
2$:	xor	a
	ret

; ioc_io_tx: WR5 68h, preload, EOM reset, RTS, the bytes, two FFh trailers,
; WR5 00h, error reset, WR3 D1h/C1h.  A stall after STALL_AT bytes.
; In: HL = packet, B = length.  Out: Z and A = 0, or A = 2 timeout.
send:
	ld	a,#0x05
	out	(SIO1BC),a
	ld	a,#0x68
	out	(SIO1BC),a
	ld	c,(hl)
	call	put_byte
	jr	c,send_fail
	ld	a,#0xc0
	out	(SIO1BC),a
	ld	a,#0x05
	out	(SIO1BC),a
	ld	a,#0x6a
	out	(SIO1BC),a
	inc	hl
	dec	b
	ld	e,#1			; E = bytes sent
3$:	ld	a,(STALL_AT)
	cp	e
	call	z,stall
	ld	c,(hl)
	call	put_byte
	jr	c,send_fail
	inc	hl
	inc	e
	djnz	3$
	ld	c,#0xff
	call	put_byte
	jr	c,send_fail
	ld	c,#0xff
	call	put_byte
	jr	c,send_fail
	ld	a,#0x05
	out	(SIO1BC),a
	xor	a
	out	(SIO1BC),a
	in	a,(SIO1BC)
	ld	(RR0TX),a
	and	#0x08
	ld	(READYTX),a
	ld	a,#0x30
	out	(SIO1BC),a
	ld	a,#0x03
	out	(SIO1BC),a
	ld	a,(HUNT)
	or	a
	ld	a,#0xc1
	jr	z,4$
	ld	a,#0xd1
4$:	out	(SIO1BC),a
	xor	a
	ret
send_fail:
	ld	a,#0x05
	out	(SIO1BC),a
	xor	a
	out	(SIO1BC),a
	ld	a,#2
	or	a
	ret

; The stall: STALL_N counts of 26 T-states, then RR0 for the record.
stall:
	push	de
	ld	de,(STALL_AT + 1)
1$:	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	in	a,(SIO1BC)
	ld	(RR0STALL),a
	pop	de
	ret

; ioc_put_byte: wait for Tx buffer empty, write C.  Carry on timeout.
put_byte:
	push	de
	ld	de,#0x2000
1$:	in	a,(SIO1BC)
	and	#0x04
	jr	nz,2$
	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	pop	de
	scf
	ret
2$:	ld	a,c
	out	(SIO1BD),a
	pop	de
	or	a
	ret

; The receive: error reset, the bounded drain (FIFO depth + 1), error reset,
; then every byte the lane delivers until a 4096-poll gap, stored as pairs:
; the byte and the empty RR0 polls before it (saturating at FFh).  The
; EVENT_AT-th byte other than FFh triggers EVENT: 1 pause, 2 channel reset.
; Out: A = 0, or 3 when no byte came.
capture:
	ld	a,#0x30
	out	(SIO1BC),a
	ld	b,#4
1$:	xor	a
	out	(SIO1BC),a
	in	a,(SIO1BC)
	and	#0x01
	jr	z,2$
	in	a,(SIO1BD)
	ld	a,(DRAINED)
	inc	a
	ld	(DRAINED),a
	djnz	1$
2$:	ld	a,#0x30
	out	(SIO1BC),a
	ld	hl,#RAW
	ld	a,(EVENT_AT)
	or	a
	jr	z,fast
	ld	b,#0			; B = bytes captured
	ld	de,#0			; first byte: a long wait
	ld	c,#0			; C = empty polls before this byte
3$:	in	a,(SIO1BC)
	rrca
	jr	c,4$
	inc	c
	jr	nz,6$
	dec	c
6$:	dec	de
	ld	a,d
	or	e
	jr	nz,3$
	jr	capture_end
4$:	in	a,(SIO1BD)
	ld	(hl),a
	inc	hl
	ld	(hl),c
	inc	hl
	inc	b
	ld	c,#0
	ld	de,#0x1000
	inc	a
	jr	z,9$			; FFh: fill, not counted
	ld	a,(NONFF)
	inc	a
	ld	(NONFF),a
	ld	e,a
	ld	a,(EVENT_AT)
	cp	e
	ld	e,#0
	call	z,rx_event
9$:	ld	a,b
	cp	#64
	jr	nz,3$
capture_end:
	ld	a,b
	ld	(RAWLEN),a
	xor	a
	out	(SIO1BC),a
	in	a,(SIO1BC)
	ld	(RR0END),a
	ld	a,#0x01
	out	(SIO1BC),a
	in	a,(SIO1BC)
	ld	(RR1END),a
	ld	a,b
	or	a
	ld	a,#3
	ret	z
	xor	a
	ret

; Without an event: an INI-shaped loop, 38 T-states an empty poll and 57 a
; byte, so it waits on the lane rather than the lane on it.  A 255-poll gap
; (about 1 ms) ends it; the first byte may take 65536 polls.
fast:
	ld	de,#0
	ld	c,#0
1$:	in	a,(SIO1BC)
	rrca
	jr	c,2$
	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	ld	b,#0
	jr	5$
2$:	ld	b,#64
3$:	in	a,(SIO1BC)
	rrca
	jr	c,4$
	inc	c
	jr	nz,3$
	jr	6$
4$:	in	a,(SIO1BD)
	ld	(hl),a
	inc	hl
	ld	(hl),c
	inc	hl
	ld	c,#0
	djnz	3$
6$:	ld	a,#64
	sub	b
	ld	b,a
5$:	jp	capture_end

rx_event:
	ld	a,(EVENT)
	cp	#2
	jr	z,2$
	push	de
	ld	de,(EVENT_N)
1$:	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	pop	de
	ret
2$:	ld	a,#0x18
	out	(SIO1BC),a
	ret

; ---------------------------------------------------------------- op 6
; A request and its reply, then the bulk read the reply's READY admits
; (ioc_io_bulk_read): the marker scan, the header and BLEN payload bytes into
; BHEAD.., the two trailer bytes, RTS off, /CTSA closing.  BSTOP abandons the
; read after that many bytes (RTS released, no wait for /CTSA).
op_read:
	call	clear_results
	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jp	nz,op_fail
	call	capture
	or	a
	jp	nz,op_fail
	call	bulk_read
	ld	(BRES),a
	xor	a
	jp	op_fail

bulk_read:
	ld	a,#0x30
	out	(SIO1AC),a
	ld	a,#0x03
	out	(SIO1AC),a
	ld	a,(BHUNT)
	or	a
	ld	a,#0xc9
	jr	z,1$
	ld	a,#0xd9
1$:	out	(SIO1AC),a
	ld	b,#4
2$:	in	a,(SIO1AC)
	and	#0x01
	jr	z,3$
	in	a,(SIO1AD)
	djnz	2$
3$:	ld	hl,(BLEN)		; the stream's count, split before admission
	ld	de,#5
	add	hl,de
	ld	de,(BSTOP)
	ld	a,d
	or	e
	jr	z,9$
	ex	de,hl
9$:	ld	a,l
	ld	(BCNT),a
	ld	a,h
	ld	(BBLK),a
	ld	(BCOUNT),hl
	ld	a,(BNORTS)
	or	a
	jp	nz,br_nohost
	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xeb
	out	(SIO1AC),a
	ld	bc,#0
4$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x08
	jr	nz,5$
	dec	bc
	ld	a,b
	or	c
	jr	nz,4$
	jp	br_timeout
5$:	ld	b,#8
	ld	de,#0
scan0:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,scan0_got
	dec	de
	ld	a,d
	or	e
	jr	nz,scan0
	jp	br_timeout
scan0_got:
	in	a,(SIO1AD)
	cp	#0xa5
	jr	z,scan1
	djnz	scan0
	jp	br_marker
scan1:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,scan1_got
	dec	de
	ld	a,d
	or	e
	jr	nz,scan1
	jp	br_timeout
scan1_got:
	in	a,(SIO1AD)
	cp	#0x5a
	jr	z,stream
	cp	#0xa5
	jr	z,scan1
	djnz	scan0
	jp	br_marker
stream:
	ld	hl,#BHEAD
	ld	c,#SIO1AD
	ld	a,(BCNT)
	ld	b,a
	or	a
	jr	nz,poll
chunk:
	ld	a,(BBLK)
	or	a
	jr	z,streamed
	dec	a
	ld	(BBLK),a
	ld	b,#0
poll:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,got
	dec	de
	ld	a,d
	or	e
	jr	nz,poll
	jp	br_timeout
got:
	ini
	jp	nz,poll
	jr	chunk
streamed:
	ld	hl,(BSTOP)
	ld	a,h
	or	l
	jr	nz,br_abandon
	ld	de,#0
	call	get_one
	jp	c,br_timeout
	call	get_one
	jp	c,br_timeout
	call	rts_off_a
	ld	de,#0
7$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x20
	jr	z,8$
	dec	de
	ld	a,d
	or	e
	jr	nz,7$
	ld	a,#4
	ret
8$:	xor	a
	ret
br_abandon:
	call	rts_off_a
	ld	a,#5
	ret
br_nohost:
	ld	a,#6
	ret
br_timeout:
	call	rts_off_a
	ld	a,#1
	ret
br_marker:
	call	rts_off_a
	ld	a,#3
	ret

; One byte from the data port, polling; DE is the stall budget.
get_one:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,1$
	dec	de
	ld	a,d
	or	e
	jr	nz,get_one
	scf
	ret
1$:	in	a,(SIO1AD)
	or	a
	ret

rts_off_a:
	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xe0
	out	(SIO1AC),a
	ret

; ---------------------------------------------------------------- op 7
; A request and its reply, then the bulk write the reply's READY admits
; (ioc_io_bulk_write): lead-in, RTS, /CTSA, marker, BHDR, BLEN payload bytes
; from BBUF (OUTI-shaped), the EOM reset and wait, RTS off, /CTSA closing.
op_write:
	call	clear_results
	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jp	nz,op_fail
	call	capture
	or	a
	jp	nz,op_fail
	call	bulk_write
	ld	(BRES),a
	xor	a
	jp	op_fail

bulk_write:
	ld	a,#0x30
	out	(SIO1AC),a
	ld	a,#0x03
	out	(SIO1AC),a
	ld	a,#0xc1
	out	(SIO1AC),a
	ld	a,#0x06
	out	(SIO1AC),a
	ld	a,#0xaa
	out	(SIO1AC),a
	ld	a,#0x07
	out	(SIO1AC),a
	ld	a,#0xaa
	out	(SIO1AC),a
	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xe9
	out	(SIO1AC),a
	ld	a,#0x80
	out	(SIO1AC),a
	xor	a
	call	bput
	jp	c,bw_stall
	ld	a,(BNORTS)
	or	a
	jp	nz,bw_nohost
	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xeb
	out	(SIO1AC),a
	ld	de,#0
1$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x20
	jr	nz,2$
	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	jp	bw_stall
2$:	ld	a,#0xa5
	call	bput
	jp	c,bw_stall
	ld	a,#0x5a
	call	bput
	jp	c,bw_stall
	ld	hl,#BHDR
	ld	b,#5
3$:	ld	a,(hl)
	call	bput
	jp	c,bw_stall
	inc	hl
	djnz	3$
	ld	hl,#BBUF
	ld	de,(BLEN)
	ld	a,d
	ld	b,e
	push	af
	ld	c,#SIO1AD
	ld	de,#0
	ld	a,b
	or	a
	jp	nz,wpoll
wchunk:
	pop	af
	or	a
	jp	z,wsent
	dec	a
	push	af
	ld	b,#0
wpoll:
	in	a,(SIO1AC)
	and	#0x04
	jr	nz,wgot
	dec	de
	ld	a,d
	or	e
	jr	nz,wpoll
	pop	af
	jp	bw_stall
wgot:
	outi
	jp	nz,wpoll
	jr	wchunk
wsent:
	ld	a,#0xc0
	out	(SIO1AC),a
	ld	de,#0
4$:	in	a,(SIO1AC)
	and	#0x40
	jr	nz,5$
	dec	de
	ld	a,d
	or	e
	jr	nz,4$
	jp	bw_stall
5$:	ld	de,#128
6$:	dec	de
	ld	a,d
	or	e
	jr	nz,6$
	call	rts_off_a
	ld	de,#0
7$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x20
	jr	z,8$
	dec	de
	ld	a,d
	or	e
	jr	nz,7$
	ld	a,#2
	ret
8$:	xor	a
	ret
bw_nohost:
	ld	a,#6
	ret
bw_stall:
	call	rts_off_a
	ld	a,#1
	ret

; bput: wait for Tx buffer empty on channel A, write A.  Carry on timeout.
bput:
	push	bc
	ld	c,a
	ld	de,#0
1$:	in	a,(SIO1AC)
	and	#0x04
	jr	nz,2$
	dec	de
	ld	a,d
	or	e
	jr	nz,1$
	pop	bc
	scf
	ret
2$:	ld	a,c
	out	(SIO1AD),a
	pop	bc
	or	a
	ret

; ---------------------------------------------------------------- op 9
; A request and its reply, then the bulk read in the ZSDOS driver's shape
; (IOCBULK in drivers/transport/ioc_command.asm): drain, RTS, the /DCDA wait,
; a marker scan that calls a one-byte helper (111 T-states a byte), the five
; header bytes in an INI loop, the register setup before the payload INI loop
; (about 17 us), the trailer through the helper.  Same results as op 6.
op_zread:
	call	clear_results
	ld	hl,#PKT
	ld	a,(PKTLEN)
	call	request
	jp	nz,op_fail
	call	capture
	or	a
	jp	nz,op_fail
	call	zsdos_read
	ld	(BRES),a
	xor	a
	jp	op_fail

zsdos_read:
	ld	a,#0x30
	out	(SIO1AC),a
	ld	a,#0x03
	out	(SIO1AC),a
	ld	a,(BHUNT)
	or	a
	ld	a,#0xc9
	jr	z,1$
	ld	a,#0xd9
1$:	out	(SIO1AC),a
	ld	b,#4
2$:	in	a,(SIO1AC)
	and	#0x01
	jr	z,3$
	in	a,(SIO1AD)
	djnz	2$
3$:	ld	a,#0x05
	out	(SIO1AC),a
	ld	a,#0xeb
	out	(SIO1AC),a
	ld	bc,#0
4$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x08
	jr	nz,5$
	dec	bc
	ld	a,b
	or	c
	jr	nz,4$
	jp	zr_timeout
5$:	ld	b,#8
zr_sync0:
	call	zr_get
	jp	c,zr_timeout
	cp	#0xa5
	jr	z,zr_sync1
	djnz	zr_sync0
	jp	zr_marker
zr_sync1:
	call	zr_get
	jp	c,zr_timeout
	cp	#0x5a
	jr	z,zr_header
	cp	#0xa5
	jr	z,zr_sync1
	djnz	zr_sync0
	jp	zr_marker
zr_header:
	call	zr_get_header
	jp	c,zr_timeout
	ld	hl,(BZPTR)
	ld	de,(BLEN)
	ld	a,d
	ld	b,e
	push	af
	ld	c,#SIO1AD
	ld	de,#0
	ld	a,b
	or	a
	jr	nz,zr_poll
zr_chunk:
	pop	af
	or	a
	jr	z,zr_trailer
	dec	a
	push	af
	ld	b,#0
zr_poll:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,zr_got
	dec	de
	ld	a,d
	or	e
	jr	nz,zr_poll
	pop	af
	jp	zr_timeout
zr_got:
	ini
	jp	nz,zr_poll
	jr	zr_chunk
zr_trailer:
	call	zr_get
	jp	c,zr_timeout
	ld	(BCRC + 1),a
	call	zr_get
	jp	c,zr_timeout
	ld	(BCRC),a
	call	rts_off_a
	ld	de,#0
7$:	ld	a,#0x10
	out	(SIO1AC),a
	in	a,(SIO1AC)
	and	#0x20
	jr	z,8$
	dec	de
	ld	a,d
	or	e
	jr	nz,7$
	ld	a,#4
	ret
8$:	xor	a
	ret
zr_marker:
	call	rts_off_a
	ld	a,#3
	ret
zr_timeout:
	call	rts_off_a
	ld	a,#1
	ret

zr_get_header:
	ld	hl,#BHEAD
	ld	b,#5
	ld	c,#SIO1AD
	ld	de,#0
zrh_wait:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,zrh_ready
	dec	de
	ld	a,d
	or	e
	jr	nz,zrh_wait
	scf
	ret
zrh_ready:
	ini
	jp	nz,zrh_wait
	or	a
	ret

zr_get:
	ld	de,#0
zrg_wait:
	in	a,(SIO1AC)
	and	#0x01
	jr	nz,zrg_ready
	dec	de
	ld	a,d
	or	e
	jr	nz,zrg_wait
	scf
	ret
zrg_ready:
	in	a,(SIO1AD)
	or	a
	ret

code_end:
