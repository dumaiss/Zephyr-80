; Local Zephyr-80 CP/M storage BIOS stubs.
;
; This file owns the CP/M BIOS storage entry points.  B: is the SD card and A: is
; whichever backend the build selected; every other drive reports no device.
;
; A: is a build-time choice (STORAGE_A in the Makefile) because the BIOS common
; window has no room for two backends at once.  All of them .org at
; CBIOS_STORAGE_A_CODE_BASE and export the same stg_a_* entry points, so the
; dispatcher never names one:
;
;   rom      read-only CP/M volume in flash pages 1-3 (default)
;   vdrip    proxy storage over the host serial link
;   ramdisk  banked RAM disk, retained but not maintained
;
; Two backends are linked -- A: and the SD card -- and the dispatcher routes on
; the drive SELDSK last selected, which is how CP/M sequences disk I/O: SELDSK
; always precedes the SETTRK/SETSEC/READ/WRITE that act on it.
;
; Storage facade flow:
;   SELDSK selects a drive and returns its DPH. B: first probes SD block 0.
;   SETTRK/SETSEC record the logical CP/M address in backend state.
;   SETDMA records the destination/source buffer address in cbios_dma_addr.
;   READ/WRITE ask the active backend to transfer one 128-byte CP/M record.
;   SECTRAN is identity mapping because this fixed disk has no skew table.
;
; Current state variables are split between common runtime state
; (cbios_dma_addr and DMA_BANK) and storage state in CBIOS_STORAGE_WORK_AREA.
; The VDrip and SD backends use MOVE_BUFFER as transaction scratch; the ROM
; backend needs none, because its LDIR reads flash and writes SRAM in one pass.

	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl STORAGE_STUB_CODE_START,STORAGE_STUB_CODE_END
	.globl CCP_QOL_CODE_START,CCP_QOL_CODE_END,ccp_clear_redraw
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

; ---------------------------------------------------------------------------
; CCP quality-of-life display helper.
;
; Physically occupies the otherwise-unused core-BIOS gap before the fixed
; banking region. It is called only by the CCP-specific BDOS input path.
;
; ccp_clear_redraw
; Purpose: clear the screen and redraw the current drive/user prompt at 0,0.
; Inputs: ACTIVE and USERNO contain the current CP/M drive and user.
; Outputs: CURPOS and STARTING are both reset to the three-character prompt.
; Clobbers: AF, BC. The caller preserves BC around this routine.
; Blocking: may block in CONOUT while the display clear completes.
; VDrip traffic: emits one clear-screen operation and three prompt characters.
; ISR-safe: no.
; ---------------------------------------------------------------------------
CCP_QOL_CODE_START:
ccp_clear_redraw:
	ld c,#FF
	call CONOUT
	ld a,(ACTIVE)
	add a,#'A'
	ld c,a
	call CONOUT
	ld a,(USERNO)
	add a,#'0'
	ld c,a
	call CONOUT
	ld c,#'>'
	call CONOUT
	ld a,#3
	ld (CURPOS),a
	ld (STARTING),a
	ret
CCP_QOL_CODE_END:
