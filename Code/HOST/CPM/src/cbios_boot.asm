; Initial CP/M CBIOS boot skeleton.
;
; This is a controlled placeholder after the ROM-to-RAM copy. It is not a real
; CP/M boot path because BDOS, CCP, and storage are not present yet.

	.globl boot,wboot,bdos_stub

; BOOT
; Cold boot entry. Assumes ROM has already been copied to RAM, ROM is disabled,
; RAM bank 0 is selected, and SP is valid in high common RAM.
boot:
	di
	call sio_init

	ld hl,#DEFAULT_DMA
	ld (cbios_dma_addr),hl

	call init_page_zero

	ld hl,#boot_banner
	call bios_puts

	jp boot_idle_loop

; WBOOT
; Warm boot entry. Stub: no CCP/BDOS reload exists yet.
wboot:
	ld hl,#wboot_banner
	call bios_puts
	jp boot_idle_loop

; Placeholder only. Real BDOS is not present yet.
bdos_stub:
	ret

; Install minimal CP/M page-zero vectors in selected low RAM bank 0:
;   0000h: JP WBOOT
;   0005h: JP BDOS_STUB
init_page_zero:
	ld a,#0xc3
	ld (PAGE_ZERO_WBOOT),a
	ld hl,#wboot
	ld (PAGE_ZERO_WBOOT + 1),hl
	ld (PAGE_ZERO_BDOS),a
	ld hl,#bdos_stub
	ld (PAGE_ZERO_BDOS + 1),hl
	ret

boot_idle_loop:
	ld hl,#boot_prompt
	call bios_puts
boot_echo_loop:
	call conin
	cp #CR
	jr z,boot_echo_newline
	ld c,a
	call conout
	jr boot_echo_loop

boot_echo_newline:
	ld c,#CR
	call conout
	ld c,#LF
	call conout
	jr boot_idle_loop

boot_banner:
	.db CR,LF
	.ascii /Zephyr-80 CP/
	.db 0x2f
	.ascii /M CBIOS skeleton/
	.db CR,LF
	.ascii /ROM copied to RAM/
	.db CR,LF
	.ascii /No BDOS, CCP, or storage yet/
	.db CR,LF,0

wboot_banner:
	.db CR,LF
	.ascii /WBOOT/
	.db CR,LF,0

boot_prompt:
	.ascii /CBIOS> /
	.db 0
