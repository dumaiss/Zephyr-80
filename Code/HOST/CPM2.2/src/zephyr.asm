; Zephyr-80 CP/M 2.2 local runtime wrapper.
;
; This wrapper keeps stock CP/M source immutable and supplies local runtime
; boot and memory services for the Zephyr-80 memory model.

	.module zephyr80_cpm22_runtime

	.include "platform_zephyr80.inc"
	.include "cbios_defs.inc"

MEM	= CPM_MEM_K

	.globl cpm_rom_entry_high
	.globl boot,wboot
	.globl bdos_entry_shim
	.globl const,conin,conout,list,punch,reader,listst
	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl MOVE,XMOVE,SELMEM,SETBNK,LAUNCH
	.globl ZBIOS_EXT_BASE

	.area RESET (ABS)
	.org 0x0000
reset_vector:
	jp cpm_rom_entry_high

cpm:
; Stock CP/M 2.2 source remains read-only in cpm-2.2.
	.include "../cpm-2.2/src/cpm22.asm"

; CP/M BIOS jump table. UOW-002 owns BOOT/WBOOT surfaces. Other BIOS entries
; are declared as future-unit surfaces and are implemented by later units.
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
	jp LAUNCH
bdos_entry_shim:
	jp FBASE

	.include "boot_shadow_copy.asm"
	.include "cbios_bank_select.asm"
	.include "cbios_sio_init.asm"
	.include "cbios_boot.asm"
	.include "cbios_console.asm"
	.include "cbios_nmi.asm"
	.include "cbios_storage_stub.asm"
	.include "cbios_ramdisk.asm"
	.include "cbios_bank.asm"
