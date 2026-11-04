; license:BSD-3-Clause
; V9958 command-engine probe program for the zephyr80 MAME machine.
;
; Runs from flash page 0: copies itself into SRAM bank 0, selects flat mode
; (latch 08h) and serves one operation the Lua probe (video.lua, vdp-commands)
; posts in a mailbox: load the 15-byte command block into R#32-R#46 through
; the indirect port (R#17 = 20h, auto-increment; R#46, written last, starts
; the command), select S#2 and poll its CE bit until the command is done,
; then select S#0 again.  The sequence is the KonaOS driver's
; (drivers/v9958/v9958_io.asm v9958_io_stream_indirect, v9958_io_wait_command).
; Interrupts stay disabled.  Assembled with sdasz80/sdldz80/makebin by video.py.

CMD      = 0x7f00          ; 1 = run the command block, cleared when done
POLLS    = 0x7f02          ; 16-bit: S#2 reads until CE was clear
BLOCK    = 0x7f10          ; R#32..R#46 (15 bytes)

LATCH    = 0x00
VDPCTRL  = 0xa1
VDPIND   = 0xa3

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
	xor	a
	ld	(CMD),a

idle:
	ld	a,(CMD)
	or	a
	jr	z,idle
	ld	a,#0x20			; R#17 = 20h: R#32, auto-increment
	out	(VDPCTRL),a
	ld	a,#0x91
	out	(VDPCTRL),a
	ld	hl,#BLOCK
	ld	bc,#0x0f00 + VDPIND
	otir				; fifteen bytes; the last one starts the command
	ld	a,#2
	out	(VDPCTRL),a
	ld	a,#0x8f
	out	(VDPCTRL),a		; R#15 = 2: S#2
	ld	de,#0
poll:
	inc	de
	in	a,(VDPCTRL)
	rrca
	jr	c,poll			; CE (S#2 bit 0) set: still running
	ld	(POLLS),de
	xor	a
	out	(VDPCTRL),a
	ld	a,#0x8f
	out	(VDPCTRL),a		; R#15 = 0
	xor	a
	ld	(CMD),a
	jr	idle
code_end:
