; Zephyr-80 first boot ROM
;
; Source format: SDCC/ASxxxx Z80 assembly, assembled with sdasz80.
; The linker places the _CODE area at 0x0000.

	.module firstboot
	.optsdcc -mz80

	.area _CODE

	.globl start

start:
	ld	hl, #msg

print_loop:
	ld	a, (hl)
	or	a, a
	jr	Z, halt_loop
	out	(#0), a
	inc	hl
	jr	print_loop

halt_loop:
	halt
	jr	halt_loop

msg:
	.ascii	"Hello from Zephyr-80"
	.db	0x0a, 0x00
