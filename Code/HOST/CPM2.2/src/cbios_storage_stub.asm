; Local Zephyr-80 CP/M storage BIOS stubs.
;
; This file owns the CP/M BIOS storage entry points. Drive A is routed to the
; RAM disk backend; all other drives keep deterministic no-device behavior.

	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl STORAGE_STUB_CODE_START,STORAGE_STUB_CODE_END
	.globl cbios_dma_addr
	.globl ramdisk_home,ramdisk_seldsk,ramdisk_seldsk_unsupported
	.globl ramdisk_settrk,ramdisk_setsec,ramdisk_read,ramdisk_write
	.globl ramdisk_sectran

	.area CODE (ABS)
	.org CBIOS_STORAGE_CODE_BASE

STORAGE_STUB_CODE_START:

home:
	push hl
	call ramdisk_home
	pop hl
	ret

settrk:
	jp ramdisk_settrk

setsec:
	jp ramdisk_setsec

; SELDSK
; Input: C = disk number. Returns HL = DPH for drive A, or 0000h for no disk.
seldsk:
	ld a,c
	cp #RAMDISK_DRIVE
	jp z,ramdisk_seldsk
	jp ramdisk_seldsk_unsupported

; SETDMA
; Input: BC = DMA address.
setdma:
	ld (cbios_dma_addr),bc
	ret

; READ and WRITE
read:
	push bc
	push de
	push hl
	call ramdisk_read
	pop hl
	pop de
	pop bc
	ret

write:
	push bc
	push de
	push hl
	call ramdisk_write
	pop hl
	pop de
	pop bc
	ret

; SECTRAN
; Input: BC = logical sector. Returns HL = untranslated logical sector.
sectran:
	jp ramdisk_sectran

STORAGE_STUB_CODE_END:
