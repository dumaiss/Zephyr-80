; license:BSD-3-Clause
; Sound card probe program for the zephyr80 MAME machine.
;
; Runs from flash page 0: copies itself into SRAM bank 0, selects flat mode
; (latch 08h) and serves operations the Lua probe (sound.lua) posts in a
; mailbox.  Every access is a real Z80 I/O instruction.
;   op 1  OTIR: COUNT bytes from SRC to port PORT (the driver's reset idiom)
;   op 2  IN A,(C) over E0h-FFh into SCAN (32 bytes)
;   op 3  COUNT {port, value} pairs from SRC, each OUT (C),A
; Assembled with sdasz80/sdldz80/makebin by sound.py.

CMD     = 0x7f00           ; operation, cleared when done
PORT    = 0x7f01
COUNT   = 0x7f02
SRC     = 0x7f10           ; the operands
SCAN    = 0x7f80           ; op 2 result

LATCH   = 0x00

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
	cp	#1
	jr	z,op_otir
	cp	#2
	jr	z,op_scan
	cp	#3
	jr	z,op_pairs
done:
	xor	a
	ld	(CMD),a
	jr	idle

op_otir:
	ld	a,(PORT)
	ld	c,a
	ld	a,(COUNT)
	ld	b,a
	ld	hl,#SRC
	otir
	jr	done

op_scan:
	ld	c,#0xe0
	ld	hl,#SCAN
scan_next:
	in	a,(c)
	ld	(hl),a
	inc	hl
	inc	c
	jr	nz,scan_next
	jr	done

op_pairs:
	ld	a,(COUNT)
	ld	b,a
	ld	hl,#SRC
pair_next:
	ld	c,(hl)
	inc	hl
	ld	a,(hl)
	inc	hl
	out	(c),a
	djnz	pair_next
	jr	done

code_end:
