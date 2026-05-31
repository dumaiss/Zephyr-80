; Local Zephyr-80 CP/M storage BIOS stubs.
;
; This file owns the CP/M BIOS storage entry points. Drive A is routed to the
; VDrip storage backend; all other drives keep deterministic no-device behavior.
;
; Storage facade flow:
;   SELDSK selects a drive and returns its DPH. Only drive A is present.
;   SETTRK/SETSEC record the logical CP/M address in backend state.
;   SETDMA records the destination/source buffer address in cbios_dma_addr.
;   READ/WRITE ask the active backend to transfer one 128-byte CP/M record.
;   SECTRAN is identity mapping because this fixed disk has no skew table.
;
; Current state variables are split between common runtime state
; (cbios_dma_addr and DMA_BANK) and storage state in CBIOS_STORAGE_WORK_AREA.
; The VDrip backend uses MOVE_BUFFER only as transaction scratch.

	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl STORAGE_STUB_CODE_START,STORAGE_STUB_CODE_END
	.globl cbios_dma_addr
	.globl ramdisk_home,ramdisk_seldsk,ramdisk_seldsk_unsupported
	.globl ramdisk_settrk,ramdisk_setsec,ramdisk_read,ramdisk_write
	.globl ramdisk_sectran
	.globl storage_caller_sp

	.area CODE (ABS)
	.org CBIOS_STORAGE_CODE_BASE

STORAGE_STUB_CODE_START:

; HOME
; Purpose: select track 0 on the active backend.
; Inputs: none.
; Outputs: ramdisk_track = 0.
; Clobbers: backend-defined; HL preserved for conservative CP/M callers.
home:
	push hl
	call ramdisk_home
	pop hl
	ret

; SETTRK
; Input: BC = CP/M track number.
; Output: selected track recorded by backend.
settrk:
	jp ramdisk_settrk

; SETSEC
; Input: BC = CP/M logical sector number, zero-based after SECTRAN.
; Output: selected sector recorded by backend.
setsec:
	jp ramdisk_setsec

; SELDSK
; Purpose:
;   Select a CP/M drive and return its disk parameter header.
; Input:
;   C = disk number.
; Output:
;   HL = DPH for drive A, or 0000h for no disk.
; Clobbers: AF, HL.
seldsk:
	ld a,c
	cp #RAMDISK_DRIVE
	jp z,ramdisk_seldsk
	jp ramdisk_seldsk_unsupported

; SETDMA
; Input: BC = DMA address.
; Output: cbios_dma_addr updated. DMA_BANK is set separately by SETBNK or boot.
setdma:
	ld (cbios_dma_addr),bc
	ret

; READ and WRITE
; Purpose:
;   Transfer one CP/M 128-byte record through the VDrip storage backend.
; Inputs:
;   ramdisk_track, ramdisk_sector, cbios_dma_addr, and DMA_BANK hold the active
;   CP/M disk address and caller buffer bank/address.
; Outputs:
;   A = 0 on success, nonzero on backend error.
; Clobbers:
;   Backend may use AF/BC/DE/HL; the facade preserves BC/DE/HL for callers.
; Stack:
;   CP/M BDOS calls BIOS disk I/O with a small private stack. The VDrip storage
;   backend can nest packet TX/RX, polling, and temporary diagnostics deeply, so
;   run the backend on the BIOS-owned stack window and restore the caller stack
;   before returning.
read:
	push bc
	push de
	push hl
	ld hl,#ramdisk_read
	jr storage_call_backend

write:
	push bc
	push de
	push hl
	ld hl,#ramdisk_write

storage_call_backend:
	ld (storage_caller_sp),sp
	ld sp,#CBIOS_CONSOLE_STACK_TOP
	ld de,#storage_call_return
	push de
	jp (hl)

storage_call_return:
	ld hl,(storage_caller_sp)
	ld sp,hl
	pop hl
	pop de
	pop bc
	ret

; SECTRAN
; Input: BC = logical sector. Returns HL = untranslated logical sector.
sectran:
	jp ramdisk_sectran

STORAGE_STUB_CODE_END:
