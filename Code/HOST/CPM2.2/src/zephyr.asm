; Zephyr-80 CP/M 2.2 local runtime wrapper: banked OS, Phase 1.
;
; One assembly produces both halves of the system, and addresses decide which
; half a byte belongs to: 2000h-BFFFh is bank 7, the OS body, visible in latch
; mode 11; C000h-FFFFh is common memory, visible in both RAM modes.
; tools/split_banked_image.py cuts the linked image into the ROM page 0 image
; (common memory and the reset vector) and the bank 7 payload, and installs
; ZCPR2 at CBASE and ZSDOS at ZSDOS_ORG.  See "Banked OS layout" in
; cbios_defs.inc and docs/Zephyr-80_OS_Execution_Memory_Architecture.md.
;
; The stock CP/M 2.2 CCP and BDOS in ../cpm22 are no longer assembled: ZSDOS in
; bank 7 is the BDOS, ZCPR2 is the CCP, and the BDOS facade owns FBASE.

	.module zephyr80_cpm22_runtime

; Whether the shared VDrip transport is linked into this build.  The Makefile
; rewrites this line alongside the .include it tracks.
;
; Defined BEFORE cbios_defs.inc, not after: slot 5's layout depends on it.  With
; the transport linked, the drive A: backend and the SD probe must clear it at
; F680h; without it, they start at the top of the slot and the 649 bytes the
; transport used to reserve become theirs.  sio_core.asm needs it too, for the
; SIO0/B diagnostics that only the transport reads.  This source stays the VDrip
; template, so 1.
VDRIP_TRANSPORT_LINKED = 1

; CP/M addresses the BIOS uses.  They came from the stock CP/M source, which is
; no longer assembled.  CBASE holds the CCP; FBASE, six bytes past the CCP slot,
; is the BDOS entry every program calls through page zero.
CBASE			= 0xe400
FBASE			= CBASE + 0x0806
IOBYTE			= 0x0003
TDRIVE			= 0x0004

	.include "platform_zephyr80.inc"
	.include "cbios_defs.inc"

	.globl cpm_rom_entry_high
	.globl boot,wboot
	.globl IOCBULK
	.globl const,conin,conout,list,punch,reader,listst
	.globl home,seldsk,settrk,setsec,setdma,read,write,sectran
	.globl MOVE,XMOVE,SELMEM,SETBNK,IOCALL,VIDEO_SEND
	.globl gate_const,gate_conin,gate_conout
	.globl gate_iocall,gate_video_send,gate_iocbulk,gate_iocbulkw
	.globl wbtrap
	.globl ZBIOS_EXT_BASE,BIOS7_MAGIC

	.area RESET (ABS)
	.org 0x0000
reset_vector:
	jp cpm_rom_entry_high

; CP/M BIOS jump table, common memory.
;
; This table serves programs running in mode 10.  The order is the CP/M 2.2
; ABI.  Programs find the table through page zero's JP WBOOT, and ZCPR2, which
; calls BIOS+6 and BIOS+9 directly, is assembled against its address
; (zcpr2/build-zcpr2.sh, from CBIOS_BASE).
;
; Only boot and the console are live (plan F6).  CONST, CONIN and CONOUT are
; gates into the bank 7 console.  The disk and auxiliary entries are inert: the
; disk structures live in bank 7, and ZSDOS uses its own table there.
;
; ZBIOS_EXT_BASE is the Zephyr extension table immediately after it:
;   MOVE / XMOVE / SELMEM / SETBNK   bank primitives, common code
;   IOCALL / VIDEO_SEND /            gates into bank 7 that stage the caller's
;   IOCBULK / IOCBULKW               buffers through common memory
; It is not published: programs reach these eight as BDOS functions 210-217
; (cbios_facade.asm), which call through it.
	.area CODE (ABS)
	.org CBIOS_BASE

BIOS_CODE_START:
BOOT:
	jp boot
WBOOT:
	jp wboot
CONST:
	jp gate_const
CONIN:
	jp gate_conin
CONOUT:
	jp gate_conout
LIST:
	jp bios_inert_ret
PUNCH:
	jp bios_inert_ret
READER:
	jp bios_inert_reader
HOME:
	jp bios_inert_ret
SELDSK:
	jp bios_inert_seldsk
SETTRK:
	jp bios_inert_ret
SETSEC:
	jp bios_inert_ret
SETDMA:
	jp bios_inert_ret
READ:
	jp bios_inert_error
WRITE:
	jp bios_inert_error
LISTST:
	jp bios_inert_listst
SECTRAN:
SECTRN:
	jp bios_inert_sectran
ZBIOS_EXT_BASE:
	jp MOVE
	jp XMOVE
	jp SELMEM
	jp SETBNK
	jp gate_iocall
	jp gate_video_send
	jp gate_iocbulk
	jp gate_iocbulkw

	.include "boot_shadow_copy.asm"
	.include "cbios_bank_select.asm"
	.include "cbios_boot.asm"
	.include "cbios_console.asm"
	.include "sio_core.asm"
	.include "cbios_xing.asm"
; The Makefile rewrites the next transport/console/storage includes according
; to CONSOLE and STORAGE_A. This source remains the VDrip compatibility
; template so it can still be assembled directly for that legacy target.
	.include "vdrip_transport.asm"
	.include "cbios_bios_ext.asm"
	.include "cbios_iocall.asm"
	.include "cbios_ioc_command.asm"
	.include "cbios_hid_input.asm"
	.ifeq VDRIP_TRANSPORT_LINKED
	.include "cbios_sercon.asm"
	.endif
	.include "cbios_console_vdrip.asm"
	.include "cbios_storage.asm"
	.include "cbios_storage_vdrip.asm"
	.include "cbios_storage_sd.asm"
	.include "cbios_bank.asm"
	.include "cbios_gate.asm"
	.include "cbios_irq.asm"
	.include "cbios_facade.asm"

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
