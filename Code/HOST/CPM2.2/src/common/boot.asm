; UOW-002 boot and memory services.
;
; BOOT may use the firmware stack immediately. WBOOT first executes from
; protected common RAM, selects bank 0 without stack/helper usage, then switches
; to the protected firmware stack before further work.

	.globl boot,wboot,wboot_resident
	.globl init_page_zero
	.globl prepare_runnable_bank
	.globl restore_ccp_from_os
	.globl facade_reset,irq_reset,bank7_check
	.globl xing_os_call_ix,fat_context_reset
	.globl runtime_set_default_dma
	.globl runtime_clear_default_dma
	.globl console_init
	.globl console_backend_cold_init
	.ifeq VDRIP_TRANSPORT_LINKED
	.globl sercon_init,sercon_install
	.endif
	.globl console_wait_key
	.globl sio_core_init,sio1_ioc_init,ioc_link_bringup,ctc_disable_interrupts,sio_core_enable_interrupts
	.globl BOOT_BANNER_CODE_START,BOOT_BANNER_CODE_END
	.globl BOOT_BANNER_TEXT,BOOT_BANNER_TEXT_END
	.globl WBOOT_RESIDENT_START,WBOOT_RESIDENT_END
	.globl RUNTIME_WORK_AREA_START,RUNTIME_WORK_AREA_END
	.globl IM2_VECTOR_FF_HIGH,CURRENT_BANK,cbios_dma_addr

; BOOT
; Purpose:
;   Cold boot entry after the ROM image has been copied into RAM. This
;   path establishes the firmware stack, initializes core hardware, prepares
;   bank 0 as a runnable CP/M environment, and enters the CCP.
; Inputs:
;   None. Execution arrives from cbios_boot_after_rom_copy with ROM disabled.
; Outputs:
;   Does not return; jumps to CCP_CLEARBUF_ENTRY with C = selected drive.
; Clobbers:
;   All primary registers are available for boot-time setup.
; Important invariants:
;   Page zero gets JP WBOOT at 0000h and JP FBASE at 0005h before applications
;   run. DEFAULT_DMA at 0080h is recorded and cleared. The cold console init
;   establishes the build-selected display/input backend. Interrupts are enabled
;   only after console state, banking state, and page zero are coherent.
boot:
	jp irq_boot_entry
boot_masked:
	; Boot runs in mode 11: the drivers it initialises are in bank 7, and so
	; is the BIOS stack.  This code is common and page zero is in the caller
	; window, so both are visible there too.  Latch first, then stack.
	ld a,#OS_EXEC_LATCH
	out (BANK_PORT),a
	ld sp,#CBIOS_STACK_TOP
	xor a
	ld (CURRENT_BANK),a
	call irq_boot_prepare
	call sound_silence_psgs
	call sio_core_init

	; Nothing in bank 7 may be called until it is known to hold this build's
	; image.  The check reports over SIO0/B, which is common, and halts.
	call bank7_check

	; SIO1/A is a cold-init device.  WBOOT must not repeat this call: its
	; channel reset would destroy the persistent Bulk character boundary while
	; the host and MCU sync flags remain set.
	call sio1_ioc_init

	; Establish IOCALL character synchronisation here, while the SIO channels
	; are being configured, rather than lazily on whichever IOCALL happens
	; first.  The MCU's reply to this request carries the falling /SYNC edge
	; that fixes the receiver's character boundary; after it, neither side
	; touches synchronisation again.
	;
	; Failure is non-fatal and deliberately unchecked: SIO1 shares nothing with
	; the console or the A: drive, so an unsynchronised IOCALL link costs
	; storage on B: and leaves the machine fully usable.
	call ioc_link_bringup

	call console_backend_cold_init
	.ifeq VDRIP_TRANSPORT_LINKED
	; Install the serial console tee.  After the backend, because it copies
	; the backend's driver table; before the banner, so a terminal that has
	; already armed the tee sees the boot messages.
	call sercon_init
	.endif
	call boot_print_banner
	call prepare_runnable_bank
	call facade_reset
	call boot_fat_context_reset
	xor a
	ld (IOBYTE),a
	ld (TDRIVE),a
	ld (DMA_BANK), a
	call sio_core_enable_interrupts
	call irq_enable

	; Back to application execution for the CCP.  The BIOS stack is in bank 7,
	; so move to a common stack first: an interrupt between the switch and the
	; CCP setting its own would otherwise push onto bank 0's C000h-DFFFh.
	ld sp,#FAC_STACK_TOP
	ld a,#MEM_MODE_APPLICATION
	out (BANK_PORT),a
	ld sp,#APP_STACK_TOP
	ld hl,#WBOOT
	push hl

	xor a
	ld c,a
	jp CCP_CLEARBUF_ENTRY

; WBOOT
; Purpose:
;   CP/M warm boot entry from the BIOS jump table and page-zero JP at 0000h.
;   This stays a small trampoline so validation can reason about the protected
;   resident warm-boot body separately.
; Outputs:
;   Does not return; wboot_resident re-enters the CCP.
wboot:
	jp wboot_resident

WBOOT_RESIDENT_START:
; WBOOT resident path
; Purpose:
;   Rebuild the CP/M runtime environment after a transient program exits or
;   jumps through page zero. It restores the CCP, reinstalls safe hardware
;   state, preserves the selected drive, and returns through the CCP warm
;   entry at CBASE+3.
; Inputs:
;   TDRIVE contains the current CP/M drive number.
; Outputs:
;   Does not return; C = TDRIVE at CCP_CLEARBUF_ENTRY.
; Clobbers:
;   All primary registers may be used during warm boot.
; Important invariants:
;   No stack use or helper CALL occurs until bank 0 is selected. This protects
;   WBOOT when it is entered from an arbitrary application bank. Bank 0 and the
;   protected firmware stack are established before any normal subroutine call.
wboot_resident:
	jp irq_wboot_entry
wboot_masked:

	; No stack or helper calls before the latch is set.  Mode 11 with bank 0:
	; the caller window is bank 0's page zero, bank 7 holds the drivers this
	; path reinitialises, and common memory holds this code and its stack.
	ld a,#OS_EXEC_LATCH
	out (BANK_PORT),a
	xor a
	ld (CURRENT_BANK),a
	ld (DMA_BANK), a

	; Protected stack handoff happens immediately after the latch is set.
	ld sp,#CBIOS_STACK_TOP
	; Return application devices and callbacks to CP/M ownership.
	call irq_boot_prepare
	call sound_silence_psgs

	; Hold the screen before console_init clears it, so the operator can read
	; what the program left.  Interrupts are on for the wait: SIO0/B receive
	; and its sink are still live here, which is what lets a serial console
	; answer, and the CTC and program callbacks are already reset above.  The
	; wait gives up on its own, so a program that broke console input cannot
	; strand the machine.
	call irq_enable
	call console_wait_key
	call irq_disable

	; Rebuild the console only.  SIO1/A deliberately retains its receiver state
	; and persistent External-Sync character boundary across CP/M warm boots.
	call sio_core_init
	call restore_ccp_from_os
	call prepare_runnable_bank
	call facade_reset
	call boot_fat_context_reset
	; The font is in bank 7, where no program can overwrite it, so console
	; initialisation needs no restore from ROM first.  The VDrip backend may
	; temporarily enable SIO RX for its READY handshake; the direct V9958
	; backend performs only physical VDP/HID setup.
	call console_init
	.ifeq VDRIP_TRANSPORT_LINKED
	; Rebind the serial console.  console_init() just reset CONSOLE_DRIVER to
	; the backend table and sio_core_init() above cleared the RX sink, so
	; without this the tee and the serial input die on the first warm boot.
	; sercon_install preserves the armed flags; sercon_init would clear them.
	call sercon_install
	.endif
	call sio_core_enable_interrupts
	call irq_enable

	; Back to application execution for the CCP.  The BIOS stack is in bank 7,
	; so move to a common stack first: an interrupt between the switch and the
	; CCP setting its own would otherwise push onto bank 0's C000h-DFFFh.
	ld sp,#FAC_STACK_TOP
	ld a,#MEM_MODE_APPLICATION
	out (BANK_PORT),a
	ld a,(TDRIVE)
	ld c,a
	jp CCP_CLEARBUF_ENTRY
WBOOT_RESIDENT_END:

 ; Restore the pristine CCP from protected OS SRAM. Called in mode 11 with
; bank 7 and the common destination both visible. Clobbers BC/DE/HL; no mode
; transition, no VDP traffic, not ISR-safe. The 2 KiB source is never TPA.
restore_ccp_from_os:
	ld hl,#CCP_RESTORE_BASE
	ld de,#CBASE
	ld bc,#CCP_RESTORE_SIZE
	ldir
	ret

; Reset all Z80 CTC channels with interrupt enable clear. The firmware and
; CP/M app launch path are polling-only at this stage.
; Prepare the currently selected runnable bank for CP/M-style execution.
; Purpose:
;   Install page zero and default DMA state expected by CP/M transient programs.
; Inputs:
;   CURRENT_BANK records the bank being prepared.
; Outputs:
;   Page zero contains CP/M vectors; cbios_dma_addr and DMA_BANK point at 0080h.
; Clobbers:
;   AF, BC, HL.
prepare_runnable_bank:
	xor a
	call init_page_zero
	call runtime_set_default_dma
	jp runtime_clear_default_dma

; Install page-zero vectors in the selected low RAM bank:
;   0000h: JP WBOOT
;   0005h: JP FBASE. Programs inspect 0006h as the BDOS/top-of-memory marker.
; DEFAULT_DMA at 0080h is not installed here; runtime_set_default_dma records
; the DMA address and runtime_clear_default_dma clears the command-tail area.
init_page_zero:
	ld a,#0xc3
	ld (PZWBOOT),a
	ld hl,#WBOOT
	ld (PZWBOOT + 1),hl
	ld (PZBDOS),a
	ld hl,#FBASE
	ld (PZBDOS + 1),hl
	ret

; Record the CP/M default DMA buffer.
; Inputs: none.
; Outputs: cbios_dma_addr = 0080h, DMA_BANK = CURRENT_BANK.
; Clobbers: AF, BC.
runtime_set_default_dma:
	ld bc,#DEFAULT_DMA
	ld (cbios_dma_addr),bc
	ld a,(CURRENT_BANK)
	ld (DMA_BANK),a
	ret

; Clear the default DMA/command-tail buffer at 0080h.
; Inputs: none.
; Outputs: 128 bytes at DEFAULT_DMA are zeroed in the selected bank.
; Clobbers: AF, B, HL.
runtime_clear_default_dma:
	xor a
	ld hl,#DEFAULT_DMA
	ld b,#DEFAULT_DMA_LEN
runtime_clear_default_dma_loop:
	ld (hl),a
	inc hl
	djnz runtime_clear_default_dma_loop
	ret

; Cold and warm boot discard transient FAT/FS2 handles while preserving the
; bank-7 per-drive current directory.  Reuse the established mode crossing;
; no additional common stub or stack is introduced.
boot_fat_context_reset:
	push ix
	ld ix,#fat_context_reset
	call xing_os_call_ix
	pop ix
	ret

; Silence all four Afternoon Blend PSGs.
; Inputs: none.
; Outputs: PSG0-PSG3 tone and noise channels are set to maximum attenuation.
; Clobbers: AF, BC. Does not block and is not ISR-safe.
; The channel command advances 9Fh/BFh/DFh/FFh; adding 20h carries only after
; FFh and ends the inner loop. PSG ports are contiguous at E0h-E3h.
sound_silence_psgs:
	ld c,#SOUND_PSG0_PORT
	ld b,#SOUND_PSG_COUNT
sound_silence_psgs_device:
	ld a,#SOUND_PSG_MUTE_TONE0
sound_silence_psgs_channel:
	out (c),a
	add a,#0x20
	jr nc,sound_silence_psgs_channel
	inc c
	djnz sound_silence_psgs_device
	ret

; Runtime work area. Later storage and launch units may extend this local state.
	.area WORK (ABS)
	.org CBIOS_WORK_AREA
RUNTIME_WORK_AREA_START:
; An IM2 vector byte of FFh reads its low pointer byte at FDFFh and its high
; pointer byte here.  FDFFh is F7h, so keep FE00h at F7h to select the dedicated
; EI/RETI stub at F7F7h.  This byte is immutable after the ROM image is loaded.
IM2_VECTOR_FF_HIGH:
	.db 0xf7
CURRENT_BANK:
	.db 0x00
cbios_dma_addr:
	.dw DEFAULT_DMA
RUNTIME_WORK_AREA_END:
