; Boot-time SIO channel B base initialization.
;
; UOW-002 owns the serial format reset only. Console backends own any later
; buffering, vector, or interrupt policy.

	.globl sio_init

; Initialize SIO channel B for 115200 8N1 and leave SIO interrupts disabled.
; Input: none.
; Output: SIO channel B configured with SIO interrupts disabled.
; Clobbers: AF.
sio_init:
	; WR0: channel reset.
	ld a,#0x18
	out (SIOB_CTRL),a

	; WR4: x16 clock, 1 stop bit, no parity.
	ld a,#0x04
	out (SIOB_CTRL),a
	ld a,#0x44
	out (SIOB_CTRL),a

	; WR3: RX enable, 8-bit RX, Auto Enables off.
	ld a,#0x03
	out (SIOB_CTRL),a
	ld a,#0xc1
	out (SIOB_CTRL),a

	; WR5: DTR, 8-bit TX, TX enable, RTS.
	ld a,#0x05
	out (SIOB_CTRL),a
	ld a,#0xea
	out (SIOB_CTRL),a

	; WR1: interrupts disabled until the console backend is ready.
	ld a,#0x01
	out (SIOB_CTRL),a
	xor a
	out (SIOB_CTRL),a
	ret
