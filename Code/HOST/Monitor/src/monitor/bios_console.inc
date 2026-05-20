; Zephyr-80 resident BIOS console services.
;
; The ROM monitor calls the CP/M-style BIOS jump table for console I/O. This
; keeps monitor command parsing and line editing separate from the SIO hardware
; implementation.

cbios_jump_table:
	jp boot
	jp wboot
	jp const
	jp conin
	jp conout
	jp list
	jp punch
	jp reader
	jp home
	jp seldsk
	jp settrk
	jp setsec
	jp setdma
	jp read
	jp write
	jp listst
	jp sectran

; BOOT
; Input: none.
; Output: SIO channel B initialized for polled console I/O.
; Clobbers: AF.
; In this monitor ROM, BOOT is callable and returns to the monitor startup path.
boot:
	call bios_sio_init
	ret

; WBOOT
; Warm boot placeholder for the BIOS ABI. Reinitialize the console and return.
wboot:
	jp boot

; Initialize SIO channel B for 115200 8N1 using x16 async clocking.
; Input: none.
; Output: SIO channel B configured for polled 115200 8N1 console I/O.
; Clobbers: AF.
bios_sio_init:
	; WR0: channel reset.
	ld a,#0x18
	out (SIOB_CTRL),a

	; WR4: x16 clock, 1 stop bit, no parity.
	ld a,#0x04
	out (SIOB_CTRL),a
	ld a,#0x44
	out (SIOB_CTRL),a

	; WR3: RX enable, 8-bit RX, auto-enables disabled.
	ld a,#0x03
	out (SIOB_CTRL),a
	ld a,#0xc1
	out (SIOB_CTRL),a

	; WR5: DTR, TX 8-bit, TX enable, RTS.
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

; CONST
; Output: A = 00h if no console character is available, FFh if one is pending.
; Non-blocking. Does not consume the character. Clobbers: AF.
const:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #SIO_RR0_RX_AVAIL
	jr z,const_no_char
	ld a,#0xff
	ret
const_no_char:
	xor a
	ret

; CONIN
; Output: A = received console character.
; Blocking. Does not echo. Clobbers: AF.
conin:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #SIO_RR0_RX_AVAIL
	jr z,conin
	in a,(SIOB_DATA)
	ret

; CONOUT
; Input: C = character to transmit.
; Blocking. Clobbers: AF.
conout:
	xor a
	out (SIOB_CTRL),a
	in a,(SIOB_CTRL)
	and #SIO_RR0_TX_EMPTY
	jr z,conout
	ld a,c
	out (SIOB_DATA),a
	ret

; LIST/PUNCH/READER currently alias the console. PUNCH and READER can later
; become machine-readable HEX export/import streams without changing monitor
; command code.
list:
	jp conout

punch:
	jp conout

reader:
	jp conin

listst:
	ld a,#0xff
	ret

; Disk-related BIOS ABI stubs. Storage is not implemented in the monitor ROM.
home:
	ret

seldsk:
	ld hl,#0x0000
	ret

settrk:
	ret

setsec:
	ret

setdma:
	ret

read:
	ld a,#0x01
	ret

write:
	ld a,#0x01
	ret

sectran:
	ld h,b
	ld l,c
	ret
