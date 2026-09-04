; UOW-002 boot and memory services.
;
; BOOT may use the firmware stack immediately. WBOOT first executes from
; protected common RAM, selects bank 0 without stack/helper usage, then switches
; to the protected firmware stack before further work.

	.globl boot,wboot,wboot_resident
	.globl init_page_zero
	.globl prepare_runnable_bank
	.globl restore_ccp_from_rom
	.globl console_backend_restore_font_from_rom
	.globl runtime_set_default_dma
	.globl runtime_clear_default_dma
	.globl console_init
	.globl console_backend_cold_init
	.globl sio_core_init,sio1_ioc_init,ioc_link_bringup,ctc_disable_interrupts,sio_core_enable_interrupts
	.globl WBOOT_RESIDENT_START,WBOOT_RESIDENT_END
	.globl RUNTIME_WORK_AREA_START,RUNTIME_WORK_AREA_END
	.globl CURRENT_BANK,cbios_dma_addr

; BOOT
; Purpose:
;   Cold boot entry after the ROM image has been shadow-copied into RAM. This
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
	di
	ld sp,#CBIOS_STACK_TOP
	call select_ram_bank0
	call ctc_disable_interrupts
	call sio_core_init

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
	call boot_print_banner
	call prepare_runnable_bank
	xor a
	ld (IOBYTE),a
	ld (TDRIVE),a
	ld (DMA_BANK), a
	call sio_core_enable_interrupts
	
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
	di

	; No stack or helper calls before bank 0 is selected.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a
	xor a
	ld (CURRENT_BANK),a
	ld (DMA_BANK), a

	; Protected stack handoff happens immediately after bank 0 selection.
	ld sp,#CBIOS_STACK_TOP
	call ctc_disable_interrupts
	; Rebuild the console only.  SIO1/A deliberately retains its receiver state
	; and persistent External-Sync character boundary across CP/M warm boots.
	call sio_core_init
	call console_backend_restore_font_from_rom
	call restore_ccp_from_rom
	call prepare_runnable_bank
	; Keep console initialization after all bank-sensitive CCP/page-zero
	; restoration. The VDrip backend may temporarily enable SIO RX for its READY
	; handshake; the direct V9958 backend performs only physical VDP/HID setup.
	call console_init
	call sio_core_enable_interrupts
	ld a,(TDRIVE)
	ld c,a
	jp CCP_CLEARBUF_ENTRY
WBOOT_RESIDENT_END:

; Restore the CCP on warm boot. Large CP/M transient programs are allowed to
; use memory from 0100h up to the BDOS base and may overwrite the CCP at CBASE.
; WBOOT therefore reloads only CBASE..FBASE-1 from ROM before returning to the
; CCP clear-buffer entry; BDOS and BIOS remain untouched.
;
; For MEM=56, CBASE is C400h. C000h-C3FFh is protected/common TPA that remains
; application-owned, so the CCP restore starts at C400h and does not treat the
; lower common window as BIOS storage.
;
; This routine runs from protected high/common BIOS RAM after WBOOT has selected
; bank 0 and installed CBIOS_STACK_TOP, so CALL/RET and LDIR are safe here.
; CBASE is in the C000h-FFFFh common window for MEM=56. In shadow/copy mode
; that window reads SRAM bank 0, not ROM, so use normal ROM-visible bank 0 for
; this high-common copy. Reads then come from ROM page 0 while writes update the
; SRAM underneath; after LDIR, immediately return to RAM-only bank 0.
restore_ccp_from_rom:
	ld a,#ROM_VISIBLE_BANK0
	out (BANK_PORT),a
	ld hl,#CBASE
	ld de,#CBASE
	ld bc,#FBASE-CBASE
	ldir

	; Leave shadow/copy mode and record the selected bank accurately. The RAM
	; disk lives in banks 2-7; CCP restore must not select or alter those banks.
	ld a,#RAM_ONLY_BANK0
	out (BANK_PORT),a
	xor a
	ld (CURRENT_BANK),a
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

boot_print_banner:
	ld hl,#BOOT_BANNER
boot_print_banner_loop:
	ld a,(hl)
	or a
	ret z
	ld c,a
	call conout
	inc hl
	jr boot_print_banner_loop

; NOTE: the core BIOS block (DA00h-DB78h) is packed solid against the console
; facade at CBIOS_CONSOLE_CODE_BASE (DB79h). This banner is the last item before
; that boundary, so it must end at DB78h or lower. Keep it <= 10 bytes including
; the NUL terminator, or reclaim space elsewhere; check_overlap.py enforces it.
BOOT_BANNER:
	.ascii /CP/
	.db '/'
	.ascii /M 2.2/
	.db LF,0

; Runtime work area. Later storage and launch units may extend this local state.
	.area WORK (ABS)
	.org CBIOS_WORK_AREA
RUNTIME_WORK_AREA_START:
CURRENT_BANK:
	.db 0x00
cbios_dma_addr:
	.dw DEFAULT_DMA
RUNTIME_WORK_AREA_END:
