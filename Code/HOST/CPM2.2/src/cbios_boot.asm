; UOW-002 boot and memory services.
;
; BOOT may use the firmware stack immediately. WBOOT first executes from
; protected common RAM, selects bank 0 without stack/helper usage, then switches
; to the protected firmware stack before further work.

	.globl boot,wboot,wboot_resident
	.globl init_page_zero
	.globl prepare_runnable_bank
	.globl restore_ccp_from_rom
	.globl runtime_set_default_dma
	.globl runtime_clear_default_dma
	.globl console_init
	.globl sio_console_enable_interrupts
	.globl WBOOT_RESIDENT_START,WBOOT_RESIDENT_END
	.globl RUNTIME_WORK_AREA_START,RUNTIME_WORK_AREA_END
	.globl CURRENT_BANK,cbios_dma_addr
	

; BOOT
; Cold boot entry after ROM has been copied to RAM. Runtime setup hands control
; to the resident CP/M CCP in the selected bank.
boot:
	di
	ld sp,#CBIOS_STACK_TOP
	call select_ram_bank0
	call ctc_disable_interrupts
	call sio_init
	call console_init
	call boot_print_banner
	call prepare_runnable_bank
	xor a
	ld (IOBYTE),a
	ld (TDRIVE),a
	ld (DMA_BANK), a
	call sio_console_enable_interrupts
	
	ld sp,#APP_STACK_TOP
	ld hl,#WBOOT
	push hl

	xor a
	ld c,a
	jp CCP_CLEARBUF_ENTRY

; BIOS WBOOT table target. Keep this as a small trampoline so validation can
; reason about the resident WBOOT body separately.
wboot:
	jp wboot_resident

WBOOT_RESIDENT_START:
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
	call sio_init
	call console_init
	call restore_ccp_from_rom
	call prepare_runnable_bank
	call sio_console_enable_interrupts
	ld a,(TDRIVE)
	ld c,a
	jp CCP_CLEARBUF_ENTRY
WBOOT_RESIDENT_END:

; Restore the CCP on warm boot. Large CP/M transient programs are allowed to
; use memory from 0100h up to the BDOS base and may overwrite the CCP at CBASE.
; WBOOT therefore reloads only CBASE..FBASE-1 from ROM before returning to the
; CCP clear-buffer entry; BDOS and BIOS remain untouched.
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
ctc_disable_interrupts:
	ld a,#CTC_RESET_DISABLE
	out (CTC0_CTRL),a
	out (CTC1_CTRL),a
	out (CTC2_CTRL),a
	out (CTC3_CTRL),a
	ret

; Prepare the currently selected runnable bank for CP/M-style execution.
prepare_runnable_bank:
	xor a
	ld (NMI_DEBOUNCE_ACTIVE),a
	call init_page_zero
	call runtime_set_default_dma
	jp runtime_clear_default_dma

; Install page-zero vectors in the selected low RAM bank:
;   0000h: JP WBOOT
;   0005h: JP FBASE. Programs inspect 0006h as the BDOS/top-of-memory marker.
init_page_zero:
	ld a,#0xc3
	ld (PZWBOOT),a
	ld hl,#WBOOT
	ld (PZWBOOT + 1),hl
	ld (PZBDOS),a
	ld hl,#FBASE
	ld (PZBDOS + 1),hl
	ret

runtime_set_default_dma:
	ld bc,#DEFAULT_DMA
	ld (cbios_dma_addr),bc
	ld a,(CURRENT_BANK)
	ld (DMA_BANK),a
	ret

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

BOOT_BANNER:
	.db CR,LF
	.ascii /CP/
	.db '/'
	.ascii /M 2.2/
	.db CR,LF,0

; Runtime work area. Later storage and launch units may extend this local state.
	.area WORK (ABS)
	.org CBIOS_WORK_AREA
RUNTIME_WORK_AREA_START:
CURRENT_BANK:
	.db 0x00
cbios_dma_addr:
	.dw DEFAULT_DMA
RUNTIME_WORK_AREA_END:
