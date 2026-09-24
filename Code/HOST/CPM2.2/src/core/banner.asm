; Boot banner: the printer and the text it prints, both bank 7.
; Split out of common/boot.asm so that file belongs to one memory class.
; Runs once from cold boot, in mode 11, after the console backend is up.

	.globl BOOT_BANNER_CODE_START,BOOT_BANNER_CODE_END
	.globl BOOT_BANNER_TEXT,BOOT_BANNER_TEXT_END
	.globl boot_puts,conout


; Print the banner and the BIOS version.  Located at
; CBIOS_BOOT_BANNER_CODE_BASE, not inline here: the old ten-byte banner slot is
; packed against the console facade and a version number needs a hex converter.
	.area CODE (ABS)
	.org CBIOS_BOOT_BANNER_CODE_BASE
BOOT_BANNER_CODE_START:
boot_print_banner:
	ld hl,#BOOT_BANNER_TEXT
	call boot_puts
	ld a,#ZBIOS_XPORT_LEVEL
	call boot_print_hex
	; CR as well as LF.  The console advances the line on LF and returns the
	; column on CR, exactly as CP/M expects; emitting only LF walks each line
	; one column further right.  The old one-line banner never showed this.
	ld c,#CR
	call conout
	ld c,#LF
	jp conout

; Print the NUL-terminated string at HL through the console facade.
; conout owns every register, so the pointer is kept on the stack.
boot_puts:
	ld a,(hl)
	or a
	ret z
	ld c,a
	push hl
	call conout
	pop hl
	inc hl
	jr boot_puts

; Print A as two uppercase hex digits.  The high nibble is printed by a call
; that returns here, then the low nibble falls through into the same code.
boot_print_hex:
	push af
	rrca
	rrca
	rrca
	rrca
	call boot_print_nibble
	pop af
boot_print_nibble:
	and #0x0f
	add a,#0x30			; bias to '0'
	cp #0x3a			; past '9'?
	jr c,boot_print_nibble_out
	add a,#0x07			; shift into 'A'-'F'
boot_print_nibble_out:
	ld c,a
	jp conout
BOOT_BANNER_CODE_END:

; ---------------------------------------------------------------------------
; Boot banner text, bank 0 read-only data at BOOT_BANNER_ROM_BASE (8800h).
;
; Immediately after the 2 KiB font at 8000h, which sets the precedent: data the
; BIOS reads once at boot does not belong in the common window where drivers
; are fighting for bytes.  Read after select_ram_bank0 and the console cold
; init, so bank 0 holds the installed OS image by then.
;
; The text is CP850, matching the console's atlas -- the e-acute is 82h, not
; UTF-8.  Writing it as source-file UTF-8 would put two bytes on the wire and
; render as two wrong glyphs.
;
; Printed as: text, then the BIOS transport level in hex, then a newline.
	.area CODE (ABS)
	.org BOOT_BANNER_ROM_BASE
BOOT_BANNER_TEXT:
	.ascii /Zephyr-80 CP/
	.db '/'
	.ascii /M 2.2/
	.db CR,LF
	.ascii /BIOS Copyright S/
	.db 0x82			; CP850 e-acute
	.ascii /bastien Dumais 2026/
	.db CR,LF
	.ascii /BIOS /
	.db 0
BOOT_BANNER_TEXT_END:
