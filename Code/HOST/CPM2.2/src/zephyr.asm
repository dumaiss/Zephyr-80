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

; FAT drive selection gate.  The Makefile rewrites this line from
; FAT_BIOS_M1; normal milestone-4 builds use one, while zero remains a recovery
; configuration that parks D: without changing linked placement.
FAT_BIOS_M1_ENABLED = 0

; CP/M addresses the BIOS uses.  They came from the stock CP/M source, which is
; no longer assembled.  CBASE holds the CCP; FBASE, six bytes past the CCP slot,
; is the BDOS entry every program calls through page zero.
CBASE			= 0xe400
FBASE			= CBASE + 0x0806
IOBYTE			= 0x0003
TDRIVE			= 0x0004

	.include "layout/platform.inc"
	.include "layout/memory.inc"

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
	.include "common/bios_table.asm"

	.include "common/rom_copy.asm"
	.include "common/bank_select.asm"
	.include "common/boot.asm"
	.include "core/banner.asm"
	.include "common/native_stage.asm"
	.include "core/console.asm"
	.include "common/sio.asm"
	.include "core/sio.asm"
	.include "common/crossing.asm"
; The Makefile rewrites the next transport/console/storage includes according
; to CONSOLE and STORAGE_A. This source remains the VDrip compatibility
; template so it can still be assembled directly for that legacy target.
	.include "common/vdrip.asm"
	.include "drivers/transport/vdrip.asm"
	.include "core/video_send.asm"
	.include "core/iocall.asm"
	.include "drivers/transport/ioc_command.asm"
	.include "drivers/console/hid_input.asm"
	.ifeq VDRIP_TRANSPORT_LINKED
	.include "common/sercon.asm"
	.include "drivers/console/sercon.asm"
	.endif
	.include "drivers/console/vdrip.asm"
	.include "core/storage.asm"
	.include "drivers/storage/vdrip.asm"
	.include "drivers/storage/sd.asm"
	.include "common/banking.asm"
	.include "drivers/storage/fat.asm"
	.include "common/gates.asm"
	.include "common/irq.asm"
	.include "common/facade.asm"
	.include "common/native_gate.asm"
	.include "core/bios7_table.asm"
