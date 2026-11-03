; license:BSD-3-Clause
; Clock and interrupt probe program for the zephyr80 MAME machine.
;
; Runs from flash page 0: copies itself into SRAM bank 0, selects flat mode
; (latch 08h) and waits until the Lua probe stores a case number at CASE.
; IM2 table at 8000h (I = 80h); every entry not listed below vectors to
; `unexpected`.  Handlers report through mailboxes the probe taps:
;   ENTRY  vector on handler entry       EXIT  vector just before EI/RETI
;   MARK   scenario markers              RXDATA  received SIO0/A byte
;   NMICNT NMI handler entry count
; Assembled with sdasz80/sdldz80/makebin by clocks_irqs.py.

CASE    = 0x7f00            ; set by the probe
TC1     = 0x7f01            ; baud case: first CTC ch0 constant
TC2     = 0x7f02            ; baud case: second CTC ch0 constant
GO      = 0x7f03            ; route case: nonzero enables interrupts
NESTED  = 0x7f04            ; nested case: 1 armed, 2 CTC handler in service
NMIHOLD = 0x7f05            ; route case: nonzero leaves the V9958 request asserted
ENTRY   = 0x9000
EXIT    = 0x9002
MARK    = 0x9003
RXDATA  = 0x9001
NMICNT  = 0x9004
RXCOUNT = 0x9010
TABLE   = 0x8000

LATCH   = 0x00
SIO0AD  = 0x20
SIO0AC  = 0x21
SIO0BD  = 0x22
SIO0BC  = 0x23
SIO1BD  = 0x32
SIO1BC  = 0x33
CTC0    = 0x40              ; physical channel 0
CTC2    = 0x41              ; physical channel 2 (CS0 = A1, CS1 = A0)
CTC3    = 0x43
VDPS    = 0xa1              ; V9958 status read / register write

	.area	PROBE (ABS)
	.org	0x0000
	jp	start

	.org	0x0066
nmi:					; the Z80 NMI vector; no acknowledge cycle
	push	af
	ld	a,(NMIHOLD)
	or	a
	jr	nz,nmi_count
	in	a,(VDPS)		; status read releases the request
nmi_count:
	ld	a,(NMICNT)
	inc	a
	ld	(NMICNT),a
	pop	af
	retn

	.org	0x0100
start:
	di
	ld	hl,#0
	ld	de,#0
	ld	bc,#code_end
	ldir				; mode 00: flash page 0 -> SRAM bank 0
	ld	a,#0x08
	out	(LATCH),a		; flat mode, bank 0
	ld	sp,#0x7e00
	ld	hl,#TABLE
	ld	b,#0x81			; 129 words: vectors 00h-FFh
fill:
	ld	(hl),#<unexpected
	inc	hl
	ld	(hl),#>unexpected
	inc	hl
	djnz	fill

	.macro	vector v, handler
	ld	hl,#handler
	ld	(TABLE + v),hl
	.endm

	vector	0x00, isr_00
	vector	0x02, isr_02
	vector	0x04, isr_04
	vector	0x06, isr_06
	vector	0x10, isr_10
	vector	0x1c, isr_1c
	vector	0x20, isr_20
	vector	0xff, isr_ff
	ld	a,#>TABLE
	ld	i,a
	im	2

wait_case:
	ld	a,(CASE)
	or	a
	jr	z,wait_case
	cp	#1
	jp	z,case_idle
	cp	#2
	jp	z,case_timer
	cp	#3
	jp	z,case_baud
	cp	#4
	jp	z,case_overlap
	cp	#5
	jp	z,case_daisy
	cp	#6
	jp	z,case_pty
	cp	#7
	jp	z,case_route
	cp	#8
	jp	z,case_nested
	halt

; ---------------------------------------------------------------- cases

case_idle:				; the probe programs the CTC itself
	ld	a,#0x01
	ld	(MARK),a
idle_ei:
	ei
idle:
	halt
	jr	idle

tick:					; KonaOS timer_boot.c sequence, ch2 156.25 Hz
	ld	a,#0x03
	out	(CTC3),a
	out	(CTC2),a
	xor	a
	out	(CTC0),a		; vector base 00h
	ld	a,#0xa5			; int, timer, prescaler 256, constant follows
	out	(CTC2),a
	ld	a,#250
	out	(CTC2),a
	ret

case_timer:
	call	tick
	ld	a,#0x02
	ld	(MARK),a
	jr	idle_ei

case_baud:
	ld	a,#0x18
	out	(SIO0AC),a		; channel resets
	out	(SIO0BC),a
	ld	a,#2
	out	(SIO0BC),a
	ld	a,#0x10
	out	(SIO0BC),a		; WR2 vector base 10h
	ld	a,#1
	out	(SIO0BC),a
	ld	a,#0x04
	out	(SIO0BC),a		; WR1B status affects vector
	ld	hl,#sio_async
	ld	b,#sio_async_end - sio_async
	ld	c,#SIO0AC
	otir
	ld	a,#1
	out	(SIO0AC),a
	ld	a,#0x18
	out	(SIO0AC),a		; WR1A: interrupt on every received character
	ei
	ld	a,(TC1)
	call	baud_run
	ld	a,(TC2)
	call	baud_run
	ld	a,#0xee
	ld	(MARK),a
	jr	idle

baud_run:				; A = CTC ch0 constant; send 8 bytes, wait for 8
	ld	c,a
	ld	a,#0x47			; counter, constant follows, reset, no interrupt
	out	(CTC0),a
	ld	a,c
	out	(CTC0),a
	xor	a
	ld	(RXCOUNT),a
	ld	a,c
	ld	(MARK),a
	ld	hl,#pattern
	ld	b,#8
baud_send:
	in	a,(SIO0AC)
	bit	2,a			; transmit buffer empty
	jr	z,baud_send
	ld	a,(hl)
	out	(SIO0AD),a
	inc	hl
	djnz	baud_send
baud_wait:
	ld	a,(RXCOUNT)
	cp	#8
	jr	nz,baud_wait
	ret

case_overlap:
	call	tick
	ld	a,#0x20
	out	(VDPS),a
	ld	a,#0x81
	out	(VDPS),a		; R#1 = 20h: vertical retrace interrupt
	in	a,(VDPS)
	call	wait_20ms
	in	a,(VDPS)		; release the V9958 request; CTC still pending
	ld	a,#0xa1
	ld	(MARK),a
	ei
	ld	hl,#38
	call	wait_hl			; 100 us
	di
	ld	b,#10
overlap_rep:				; both pending, then enable
	push	bc
	call	wait_20ms
	ld	a,#0xb0
	ld	(MARK),a
	ei
	ld	hl,#77
	call	wait_hl			; 200 us
	di
	pop	bc
	djnz	overlap_rep
	ld	a,#0xee
	ld	(MARK),a
	jp	idle_ei

case_daisy:
	ld	a,#0x18
	out	(SIO0BC),a
	out	(SIO1BC),a
	ld	hl,#sio_daisy0
	ld	b,#sio_daisy_end - sio_daisy0
	ld	c,#SIO0BC
	otir
	ld	hl,#sio_daisy1
	ld	b,#sio_daisy_end - sio_daisy0
	ld	c,#SIO1BC
	otir
	xor	a
	out	(CTC0),a
	ld	a,#0x85			; int, timer, prescaler 16, constant follows
	out	(CTC2),a
	ld	a,#63			; 100.8 us
	out	(CTC2),a
	ld	a,#0x5a
	out	(SIO0BD),a		; transmit buffer empties: TxIP
	out	(SIO1BD),a
	ld	hl,#770
	call	wait_hl			; 2 ms: CTC, SIO0 and SIO1 all pending
	ld	a,#0xe0
	ld	(MARK),a
	jp	idle_ei

case_route:				; interrupts stay off until the probe sets GO
	ld	a,#0x01
	ld	(MARK),a
route_wait:
	ld	a,(GO)
	or	a
	jr	z,route_wait
	ei
route_idle:
	halt
	jr	route_idle

case_nested:				; CTC, SIO1 and V9958 all requesting
	call	tick
	ld	a,#0x18
	out	(SIO1BC),a
	ld	hl,#sio_daisy1
	ld	b,#sio_daisy_end - sio_daisy0
	ld	c,#SIO1BC
	otir
	ld	a,#0x20
	out	(VDPS),a
	ld	a,#0x81
	out	(VDPS),a		; R#1 = 20h: vertical retrace interrupt
	in	a,(VDPS)
	ld	a,#1
	ld	(NESTED),a		; the next CTC handler runs the scenario
	ld	a,#0xc0
	ld	(MARK),a
	jp	idle_ei

case_pty:
	ld	a,#0x18
	out	(SIO0BC),a
	ld	hl,#sio_async
	ld	b,#sio_async_end - sio_async
	ld	c,#SIO0BC
	otir
pty_line:
	ld	hl,#banner
pty_char:
	ld	a,(hl)
	or	a
	jr	z,pty_pause
pty_wait:
	in	a,(SIO0BC)
	bit	2,a
	jr	z,pty_wait
	ld	a,(hl)
	out	(SIO0BD),a
	inc	hl
	jr	pty_char
pty_pause:
	ld	b,#5
pty_delay:
	call	wait_20ms
	djnz	pty_delay
	jr	pty_line

; ---------------------------------------------------------------- helpers

wait_20ms:
	ld	hl,#7700
wait_hl:				; 26 T-states (2.6 us) per count
	dec	hl
	ld	a,h
	or	l
	jr	nz,wait_hl
	ret

; ---------------------------------------------------------------- handlers

	.macro	stub v
	push	af
	ld	a,#v
	jp	isr_common
	.endm

isr_00:	stub	0x00
isr_02:	stub	0x02
isr_04:	stub	0x04
isr_06:	stub	0x06
isr_10:	stub	0x10
isr_1c:	stub	0x1c
isr_20:	stub	0x20
isr_ff:	stub	0xff
unexpected:
	push	af
	ld	a,#0x99
	ld	(ENTRY),a
	halt				; the probe fails on entry code 99h

isr_common:
	ld	(ENTRY),a
	cp	#0xff
	jr	z,svc_vdp
	cp	#0x04
	jr	z,svc_ctc
	cp	#0x10
	jr	z,svc_sio0b
	cp	#0x1c
	jr	z,svc_sio0a_rx
	cp	#0x20
	jr	z,svc_sio1b
isr_exit:
	ld	(EXIT),a
	pop	af
	ei
	reti

svc_vdp:
	in	a,(VDPS)		; status S#0 read releases the request
	ld	a,(NESTED)
	cp	#2
	ld	a,#0xff
	jr	nz,isr_exit
	ld	(EXIT),a		; inside the CTC handler: return without RETI,
	pop	af			; which every daisy device would decode as
	ei				; the end of the CTC's service
	ret

svc_ctc:
	ld	a,(NESTED)
	cp	#1
	ld	a,#0x04
	jr	nz,isr_exit
	ld	a,#2
	ld	(NESTED),a
	ld	a,#0x5a
	out	(SIO1BD),a		; SIO1 TxIP rises while the CTC is in service
	ei				; nest: lower daisy devices stay blocked
	push	hl
	ld	hl,#9600
	call	wait_hl			; 25 ms: a V9958 frame request arrives
	pop	hl
	xor	a
	ld	(NESTED),a
	ld	a,#0x04
	jr	isr_exit

svc_sio0b:
	ld	a,#0x28
	out	(SIO0BC),a		; reset TxIP
	ei				; nest: higher priority may interrupt
	push	hl
	ld	hl,#115
	call	wait_hl			; 300 us in service
	pop	hl
	ld	a,#0x10
	jr	isr_exit

svc_sio0a_rx:
	push	hl
	in	a,(SIO0AD)
	ld	(RXDATA),a
	ld	hl,#RXCOUNT
	inc	(hl)
	pop	hl
	ld	a,#0x1c
	jr	isr_exit

svc_sio1b:
	ld	a,#0x28
	out	(SIO1BC),a
	ld	a,#0x20
	jr	isr_exit

; ---------------------------------------------------------------- data

sio_async:				; register, value pairs: x16 8N1, rx/tx on
	.db	4, 0x44, 3, 0xc1, 5, 0xea
sio_async_end:
sio_daisy0:				; tx on, TxIE, vector 10h, status affects vector
	.db	4, 0x44, 5, 0x68, 2, 0x10, 1, 0x06
sio_daisy_end:
sio_daisy1:				; same for SIO1, vector 20h
	.db	4, 0x44, 5, 0x68, 2, 0x20, 1, 0x06
pattern:
	.db	0x55, 0xaa, 0x00, 0xff, 0x5a, 0xa5, 0x12, 0x80
banner:
	.ascii	"ZEPHYR80 SIO0B PTY 115200"
	.db	13, 10, 0
code_end:
