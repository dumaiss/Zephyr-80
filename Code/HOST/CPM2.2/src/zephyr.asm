; Zephyr-80 CP/M 2.2 local runtime wrapper.
;
; This wrapper keeps stock CP/M source immutable and supplies local runtime
; boot and memory services for the Zephyr-80 memory model.

	.module zephyr80_cpm22_runtime

	.include "platform_zephyr80.inc"
	.include "cbios_defs.inc"

	.globl cpm_rom_entry_high
	.globl boot,wboot
	.globl IOCBULK
	.globl const,conin,conout,list,punch,reader,listst
	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl MOVE,XMOVE,SELMEM,SETBNK,IOCALL,VIDEO_SEND
	.globl ZBIOS_EXT_BASE

	.area RESET (ABS)
	.org 0x0000
reset_vector:
	jp cpm_rom_entry_high

cpm:
; Stock CP/M 2.2 source remains read-only in cpm-2.2.
	.include "../cpm-2.2/src/cpm22.asm"

; CP/M BIOS jump table.
;
; CP/M enters the BIOS only through this fixed sequence of three-byte jumps.
; The order is the CP/M 2.2 ABI, so exported labels and spacing are part of
; the operating-system contract:
;   BOOT/WBOOT            cold and warm boot entry points
;   CONST/CONIN/CONOUT    console status, blocking input, blocking output
;   LIST/PUNCH/READER     legacy auxiliary character devices
;   HOME..SECTRAN         disk selection, address setup, and sector I/O
;
; ZBIOS_EXT_BASE is a Zephyr extension table placed immediately after the
; standard CP/M entries. It exposes memory services used by bank-aware tools:
;   MOVE                  copy bytes, honoring a pending XMOVE if one exists
;   XMOVE                 set source/destination banks for the next MOVE
;   SELMEM/SETBNK         select execution bank / record disk DMA bank
;   IOCALL                perform a BIOS-owned SIO1 IO Controller transaction
;   VIDEO_SEND            send a selected-backend raw video request
;
; Banking and XMOVE live in the core BIOS range because they define how CP/M
; itself crosses banks. They are not replaceable card drivers.
	.area CODE (ABS)
	.org CBIOS_BASE

BIOS_CODE_START:
BOOT:
	jp boot
WBOOT:
	jp wboot
CONST:
	jp const
CONIN:
	jp conin
CONOUT:
	jp conout
LIST:
	jp list
PUNCH:
	jp punch
READER:
	jp reader
HOME:
	jp home
SELDSK:
	jp seldsk
SETTRK:
	jp settrk
SETSEC:
	jp setsec
SETDMA:
	jp setdma
READ:
	jp read
WRITE:
	jp write
LISTST:
	jp listst
SECTRAN:
SECTRN:
	jp sectran
ZBIOS_EXT_BASE:
	jp MOVE
	jp XMOVE
	jp SELMEM
	jp SETBNK
	jp IOCALL
	jp VIDEO_SEND
	jp IOCBULK
	jp IOCBULKW

	.include "boot_shadow_copy.asm"
	.include "cbios_bank_select.asm"
	.include "cbios_boot.asm"
	.include "cbios_console.asm"
	.include "sio_core.asm"
; The Makefile rewrites the next transport/console/storage includes according
; to CONSOLE and STORAGE_A. This source remains the VDrip compatibility
; template so it can still be assembled directly for that legacy target.
	.include "vdrip_transport.asm"
	.include "cbios_bios_ext.asm"
	.include "cbios_iocall.asm"
	.include "cbios_ioc_command.asm"
	.include "cbios_hid_input.asm"
	.include "cbios_console_vdrip.asm"
	.include "cbios_storage.asm"
	.include "cbios_storage_vdrip.asm"
	.include "cbios_storage_sd.asm"
	.include "cbios_bank.asm"
