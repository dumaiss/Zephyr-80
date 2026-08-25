; Local Zephyr-80 CP/M storage BIOS stubs.
;
; This file owns the CP/M BIOS storage entry points.  A: is the SD card and B:
; is the VDrip proxy volume; every other drive reports no device.
;
; Both backends are linked and the dispatcher routes on the drive SELDSK last
; selected, which is how CP/M sequences disk I/O: SELDSK always precedes the
; SETTRK/SETSEC/READ/WRITE that act on it.
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
	.globl stg_home,stg_seldsk,stg_settrk,stg_setsec
	.globl stg_read,stg_write,stg_sectran
	.globl storage_caller_sp

	.area CODE (ABS)
	.org CBIOS_STORAGE_CODE_BASE

STORAGE_STUB_CODE_START:

; HOME
; Purpose: select track 0 on the active backend.
; Inputs: none.
; Outputs: vdrip_storage_track = 0.
; Clobbers: backend-defined; HL preserved for conservative CP/M callers.
; Every entry is a jump into the dispatcher, which lives with the SD backend.
;
; The facade region is 63 bytes, between the core BIOS and the banking code, and
; there is no room here for drive routing plus a stack switch.  These have to sit
; at fixed addresses because they are the CP/M jump table's targets; the logic
; does not.
home:
	jp stg_home
settrk:
	jp stg_settrk
setsec:
	jp stg_setsec
seldsk:
	jp stg_seldsk
read:
	jp stg_read
write:
	jp stg_write
sectran:
	jp stg_sectran

; SETDMA
; Input: BC = DMA address.
; Output: cbios_dma_addr updated. DMA_BANK is set separately by SETBNK or boot.
setdma:
	ld (cbios_dma_addr),bc
	ret

STORAGE_STUB_CODE_END:
