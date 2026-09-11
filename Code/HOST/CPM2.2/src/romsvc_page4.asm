; Zephyr-80 ROM service page (ROM page 4).
;
; Assembled standalone, not linked into the firmware: this is a separate binary
; that the image builder attaches at ROM page 4, and it is executed in place
; while the gate holds the machine in shadow/copy mode.  See src/romsvc_abi.inc
; for the contract and for what a service may and may not touch.
;
; Phase 2 of docs/Zephyr80_Executable_ROM_Service_Architecture.md.  The three
; services here do no useful work; they exist to prove the mechanism on hardware
; before any real driver is moved behind it:
;
;   IDENT      the gate reached ROM and returned
;   ECHO       arguments cross in both directions
;   WRITE_SIG  a service can write the caller's hidden low RAM
;
; Rules this file has to keep, all of them consequences of running from ROM with
; the caller's memory hidden:
;
;   No writes to itself.  A write to 0000h-BFFFh goes to the SELECTED SRAM BANK,
;   not to ROM, so a variable here would silently land in whatever the caller
;   had at that address.  Mutable state belongs in the common window above
;   C000h, owned by the resident side.
;
;   No reads of the caller's memory below C000h.  That is ROM now.
;
;   The stack is the gate's, in the common window.  CALL, PUSH and POP are fine;
;   the gate switched SP before entering shadow mode precisely so they would be.

	.module romsvc_page4
	.include "romsvc_abi.inc"
	.include "romsvc_bios.inc"
	.include "platform_zephyr80.inc"

; Inner iterations per delay unit.  Each pass is about 24 T-states, so this is
; roughly a millisecond at the Zephyr's CPU clock.
ROMSVC_SPIN_INNER = 300

	.area CODE (ABS)
	.org ROMSVC_SIGNATURE

; Sixteen bytes of text at page offset 0.  ROMSVC_WRITE_SIG copies this, and a
; human reading a hex dump of the flash can see which page they are looking at.
signature:
	.ascii "ZEPHYR80 ROMSVC1"

	.org ROMSVC_IM1_PAD

; IM1 landing pad -- see romsvc_abi.inc.  Not a handler: it acknowledges the
; interrupt to the Z80 daisy chain and returns, leaving the device still
; requesting.  The gate re-enables interrupts on the way out and the real
; handler runs then, so the interrupt is deferred by the length of the service
; rather than lost.
romsvc_im1_pad:
	reti

	.org ROMSVC_ENTRY

; ---------------------------------------------------------------------------
; romsvc_entry -- fixed dispatch address for every ROM service call.
;
; In:  A  = service number
;      BC/DE/HL = per-service arguments
; Out: per-service; A = ROMSVC_BAD_SERVICE for an unknown number.
; Clobbers: per-service.
; Interrupts: disabled by the gate for the duration.
; ---------------------------------------------------------------------------
romsvc_entry:
	; A compare chain, not a jump table.  A table has to build an index in a
	; register pair, and every register pair here is carrying an argument --
	; BC, DE and HL all belong to the caller at this point.  Preserving them
	; is part of the ABI, so the dispatcher must not touch them.  With three
	; services the chain is also smaller than the table plus the arithmetic.
	cp #ROMSVC_IDENT
	jp z,romsvc_ident
	cp #ROMSVC_ECHO
	jp z,romsvc_echo
	cp #ROMSVC_WRITE_SIG
	jp z,romsvc_write_sig
	cp #ROMSVC_SPIN
	jp z,romsvc_spin
	cp #ROMSVC_UPLOAD_ATLAS
	jp z,romsvc_upload_atlas
	cp #ROMSVC_DISPLAY_INIT
	jp z,romsvc_display_init
	cp #ROMSVC_RESET_DISPLAY
	jp z,v9958_reset_display
	cp #ROMSVC_CONSOLE_BYTE
	jp z,romsvc_console_byte
	cp #ROMSVC_FLUSH_SYNC
	jp z,romsvc_flush_sync
	cp #ROMSVC_SD_READ
	jp z,sd_storage_read
	cp #ROMSVC_SD_WRITE
	jp z,sd_storage_write
	cp #ROMSVC_SD_FLUSH
	jp z,sd_storage_flush
	cp #ROMSVC_SD_PROBE
	jp z,sd_storage_probe
	cp #ROMSVC_SD_PROBE2
	jp z,sd_storage_probe2

	ld a,#ROMSVC_BAD_SERVICE
	ret

; A = ROMSVC_MAGIC.
romsvc_ident:
	ld a,#ROMSVC_MAGIC
	ret

; HL = HL + 1.  Deliberately a value the caller cannot have computed by
; accident: if HL comes back unchanged the gate never called anything, and if it
; comes back as rubbish the register did not survive the latch writes.
romsvc_echo:
	inc hl
	ld a,#ROMSVC_OK
	ret

; Copy the signature to (DE) in the caller's bank.
;
; The source is ROM at 0000h, which the caller cannot read, and the destination
; is RAM below C000h, which this code cannot read.  LDIR does both at once here
; only because shadow mode splits reads from writes exactly as MEM_DECODER.pld
; describes.  If that is wrong, this is where it shows.
romsvc_write_sig:
	ld hl,#signature
	ld bc,#ROMSVC_SIGNATURE_LEN
	ldir
	ld a,#ROMSVC_OK
	ret

; Burn roughly B milliseconds inside a ROM service.
;
; The inner count targets about 1 ms at the Zephyr's clock.  It does not need to
; be accurate -- the point is to hold the machine inside a ROM service for long
; enough that the serial receive path would visibly fail if interrupts were not
; being taken, which is tens of characters' worth of time rather than a
; precisely known interval.
romsvc_spin:
	ld a,b
	or a
	jr z,romsvc_spin_done
romsvc_spin_outer:
	ld de,#ROMSVC_SPIN_INNER
romsvc_spin_inner:
	dec de
	ld a,d
	or e
	jr nz,romsvc_spin_inner
	djnz romsvc_spin_outer
romsvc_spin_done:
	ld a,#ROMSVC_OK
	ret

; ---------------------------------------------------------------------------
; ROMSVC_UPLOAD_ATLAS -- rebuild both glyph atlases in VRAM.
;
; Moved here from E705h-E7ADh.  It is the first real migration because it is the
; clean case: bulky, called only from console init and reset rather than from
; the per-character path, and dependent on nothing the caller owns.
;
; What it still calls, it calls where it always did.  The console occupies
; E000h-ECADh, which is the common window, so it stays mapped while this runs --
; command_buffer, the atlas state bytes and v9958_write_vram_small are all
; reached at their resident addresses, generated into romsvc_bios.inc rather
; than written down.
;
; What could NOT stay is the font.  The glyph fetch reads 8000h, and while this
; service runs 8000h is this page, not bank 0.  So the font moved with the code.
;
; That removes a staging step, not a fault.  The original design put the font in
; the TPA deliberately: ROM to 8000h at boot, 8000h to VRAM, and from then on the
; glyphs live in VRAM and the RAM copy is disposable -- a transient overwriting
; it is harmless, because the next boot re-copies before the next upload.
; Reading the font straight from ROM here makes both the copy and the boot-time
; refresh that fed it unnecessary.
;
; Interrupts: runs with the gate's policy.  This is a slow service -- 128
; scanline passes, each streaming 96 bytes to VRAM -- so it is exactly the case
; that blanket DI could not have carried.
; ---------------------------------------------------------------------------
romsvc_upload_atlas:
	xor a
	ld (RES_atlas_reverse_flag),a
	call romsvc_atlas_pass
	ld a,#0x01
	ld (RES_atlas_reverse_flag),a
	call romsvc_atlas_pass
	ld a,#ROMSVC_OK
	ret

romsvc_atlas_pass:
	xor a
	ld (RES_atlas_scanline),a
romsvc_atlas_scanline_loop:
	ld hl,#RES_command_buffer
	ld (RES_atlas_dest),hl

	; font address = ROMSVC_FONT_BASE + (glyph_group * 100h) + scanline
	ld a,(RES_atlas_scanline)
	ld c,a
	and #0x07
	ld l,a
	ld a,c
	srl a
	srl a
	srl a
	add a,#(ROMSVC_FONT_BASE >> 8)
	ld h,a

	ld b,#RES_V9958_ATLAS_COLS
romsvc_atlas_glyph_loop:
	ld a,(hl)
	push hl
	call romsvc_expand_font_row
	pop hl
	ld de,#0x0008
	add hl,de
	djnz romsvc_atlas_glyph_loop

	; normal atlas at 10000h, reverse at 14000h; one 256-byte G6 pitch per
	; scanline, of which only the first 96 bytes carry glyph data.
	ld a,(RES_atlas_scanline)
	ld d,a
	ld a,(RES_atlas_reverse_flag)
	or a
	jr z,romsvc_atlas_have_address
	ld a,d
	add a,#0x40
	ld d,a
romsvc_atlas_have_address:
	ld e,#0x00
	ld c,#0x01
	ld b,#RES_ATLAS_ROW_BYTES
	ld hl,#RES_command_buffer
	call v9958_write_vram_small

	ld a,(RES_atlas_scanline)
	inc a
	ld (RES_atlas_scanline),a
	cp #(RES_V9958_ATLAS_ROWS * 8)
	jr nz,romsvc_atlas_scanline_loop
	ret

romsvc_expand_font_row:
	ld c,a
	ld hl,(RES_atlas_dest)
	ld a,c
	rrca
	rrca
	rrca
	rrca
	rrca
	rrca
	and #0x03
	call romsvc_pair_to_color
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	rrca
	rrca
	and #0x03
	call romsvc_pair_to_color
	ld (hl),a
	inc hl
	ld a,c
	rrca
	rrca
	and #0x03
	call romsvc_pair_to_color
	ld (hl),a
	inc hl
	ld (RES_atlas_dest),hl
	ret

romsvc_pair_to_color:
	push de
	push hl
	ld e,a
	ld d,#0x00
	ld a,(RES_atlas_reverse_flag)
	or a
	jr z,romsvc_pair_table_selected
	ld a,e
	add a,#0x04
	ld e,a
romsvc_pair_table_selected:
	ld hl,#romsvc_pair_color_table
	add hl,de
	ld a,(hl)
	pop hl
	pop de
	ret

romsvc_pair_color_table:
	.db 0x44,0x4f,0xf4,0xff
	.db 0xff,0xf4,0x4f,0x44

	.include "romsvc_console_init.asm"
	.include "romsvc_console_term.asm"
	.include "romsvc_console_vdp.asm"
	.include "romsvc_sd.asm"

	.org ROMSVC_FONT_BASE

; The CP850 6x8 font.  Read directly from ROM by the atlas builder above, with
; no RAM staging copy in between.
romsvc_font:
	.include "font_cp850_6x8.inc"
