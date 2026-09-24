; The table ZSDOS calls, and the BANK7OS1 image marker.  Bank 7, core: it
; defines the contract ZSDOS uses to reach the BIOS.  bank7_check compares the
; marker before anything calls into bank 7.
; Split out of zephyr.asm; included last, as it was emitted last.


; ZSDOS's BIOS jump table, bank 7.
;
; ZSDOS computes its BIOS as ZSDOS+1000h and calls it in mode 11, so this table
; points straight at the bank 7 implementation.  BOOT and WBOOT go through the
; warm-boot trap, which restores mode 10 first (plan F1).
	.area CODE (ABS)
	.org BIOS7_BASE

BIOS7_TABLE:
	jp wbtrap			; BOOT
	jp wbtrap			; WBOOT
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

; Signature bank7_check compares at boot, before anything calls into bank 7.
BIOS7_MAGIC:
	.ascii "BANK7OS1"
BIOS7_TABLE_END:

	.ifgt (BIOS7_TABLE_END - BIOS7_TABLE) - (CBIOS_CONSOLE_CODE_BASE - BIOS7_BASE)
	.error 1			; the bank 7 table runs into the console dispatch
	.endif
