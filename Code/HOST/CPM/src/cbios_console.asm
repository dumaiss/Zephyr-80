; Console-oriented CP/M CBIOS routines for Zephyr-80 SIO channel B.
;
; These routines do not call monitor code. BOOT calls sio_init before using the
; console.

	.globl sio_init,bios_putc_a,bios_puts
	.globl const,conin,conout,list,punch,reader,listst

; Initialize SIO channel B for 115200 8N1 with interrupts disabled.
; Input: none.
; Output: SIO channel B configured for polled 115200 8N1 console I/O.
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

	; WR1: interrupts disabled.
	ld a,#0x01
	out (SIOB_CTRL),a
	xor a
	out (SIOB_CTRL),a
	ret

; BIOS-local helper, not a CP/M jump-table entry.
; Input: A = byte to transmit.
; Output: byte written to SIOB_DATA.
; Blocks until TX is ready. Clobbers: AF.
bios_putc_a:
	ld c,a
	jp conout

; BIOS-local helper, not a CP/M jump-table entry.
; Input: HL = NUL-terminated string.
; Output: all bytes before the NUL are sent to the console.
; Blocks in CONOUT for each byte. Clobbers: AF, C, HL.
bios_puts:
	ld a,(hl)
	or a
	ret z
	call bios_putc_a
	inc hl
	jr bios_puts

; CONST
; Input: none.
; Output: A = 00h when no console character is available.
;         A = FFh when a console character is available.
; Non-blocking. Does not consume the character. Clobbers: AF.
const:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #RR0_RX_AVAILABLE
	jr z,const_no_char
	ld a,#CONST_HAS_CHAR
	ret
const_no_char:
	xor a
	ret

; CONIN
; Input: none.
; Output: A = received console character.
; Blocking. Does not echo. Clobbers: AF.
conin:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #RR0_RX_AVAILABLE
	jr z,conin
	in a,(SIOB_DATA)
	ret

; CONOUT
; Input: C = character to transmit.
; Output: byte written to SIOB_DATA.
; Blocking. Clobbers: AF.
conout:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #RR0_TX_EMPTY
	jr z,conout
	ld a,c
	out (SIOB_DATA),a
	ret

; LIST
; Input: C = character.
; Output: byte written through CONOUT.
; Blocking. For now, LIST aliases console output; it may later become a
; printer/log output path.
list:
	jp conout

; PUNCH
; Input: C = character.
; Output: byte written through CONOUT.
; Blocking. For now, PUNCH aliases console output; this may later become an
; Intel HEX or machine-readable output stream.
punch:
	jp conout

; READER
; Input: none.
; Output: A = character.
; Blocking. For now, READER aliases console input; this may later become an
; Intel HEX or machine-readable input stream.
reader:
	jp conin

; LISTST
; Input: none.
; Output: A = FFh.
; Non-blocking. Since LIST currently aliases console output, report ready.
; Clobbers: AF.
listst:
	ld a,#CONST_HAS_CHAR
	ret
