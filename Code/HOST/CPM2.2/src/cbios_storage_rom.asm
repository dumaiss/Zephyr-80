; Local Zephyr-80 CP/M ROM disk backend.
;
; Drive A is a read-only CP/M volume living in flash pages 1-3.  CP/M owns the
; filesystem layout; this BIOS layer only maps 128-byte records to a ROM page
; and offset and copies them into the caller's DMA buffer.
;
; Why this exists:
;   A: used to come from VDrip proxy storage over the host serial link, so it
;   only existed while the proxy was attached, and an SD fault on B: left
;   nothing to diagnose with.  A ROM-backed A: is always present, carries the
;   diagnostic utilities, and can populate a fresh card with PIP.
;
; The transfer relies on the memory decoder rather than on a staging buffer.
; From MEM_DECODER.pld (Rev 09), with shadow/copy mode set and ROM enabled:
;
;   0000h-BFFFh   reads select ROM page D7:D5, writes select SRAM bank D2:D0
;   C000h-FFFFh   reads and writes both select SRAM bank 0 (FORCE_BANK0)
;
; So one LDIR reads flash and writes SRAM in the same instruction, and the two
; ends cannot alias because they are physically different chips.  The RAM disk
; backend needs two LDIRs through MOVE_BUFFER only because both of its ends are
; SRAM; this backend needs no scratch buffer at all.
;
; This code executes from F910h, inside the C000h-FFFFh window that shadow mode
; leaves as ordinary SRAM, so it keeps running while ROM covers the low 48 KiB.
; That is the same technique restore_ccp_from_rom and restore_font_from_rom
; already use at runtime.
;
; Geometry assumptions (see the ROMDISK_* block in cbios_defs.inc):
;   3 pages * 48 KiB/page = 147456 bytes.
;   0180h records per page and 0480h records total.
;   24 tracks * 48 sectors/track * 128 bytes/sector = full capacity.
;
; The volume is read only, enforced in the BIOS: stg_a_write returns BIOS_ERR, so
; no write can ever appear to succeed.  BDOS reports "Bdos Err On A: Bad Sector",
; waits for a key and warm-boots (ERROR1/DSKERROR in cpm22.asm), so the machine
; stays usable.
;
; The nicer "Bdos Err On A: R/O" would need the BDOS write-protect vector set
; through BDOS function 28.  That was tried and does not hold: the CCP calls
; function 13 on every entry (cpm22.asm "reset the disk system"), and RSTDSK
; clears WRTPRT outright, so a flag set at boot is gone before the first prompt.
; Setting it would mean either patching the stock CCP, which stays read-only
; here, or poking BDOS internals from the BIOS.  Neither is worth a better
; wording, so the write error is the whole mechanism.  `STAT A:=R/O` still sets
; the flag for the current session if you want the shorter message.

	.globl STORAGE_A_DPH,STORAGE_A_DPB,STORAGE_A_ALV
	.globl stg_a_selected_drive,stg_a_track,stg_a_sector
	.globl stg_a_home,stg_a_seldsk,stg_a_seldsk_unsupported
	.globl stg_a_settrk,stg_a_setsec,stg_a_read,stg_a_write
	.globl stg_a_sectran
	.globl STORAGE_A_CODE_START,STORAGE_A_CODE_END
	.globl ROMDISK_CODE_START,ROMDISK_CODE_END
	.globl STORAGE_STATE_START,STORAGE_STATE_END
	.globl ROMDISK_DPH,ROMDISK_DPB,ROMDISK_ALV
	.globl rom_storage_selected_drive,rom_storage_track,rom_storage_sector
	.globl storage_caller_sp
	.globl CURRENT_BANK,DMA_BANK,cbios_dma_addr

ROMDISK_DIRBUF			= CBIOS_STORAGE_DIRBUF

	.area CODE (ABS)
	.org CBIOS_STORAGE_A_CODE_BASE

STORAGE_A_CODE_START:
ROMDISK_CODE_START:

; HOME
; Purpose: reset the selected CP/M track to zero.
; Inputs: none.
; Outputs: rom_storage_track = 0000h.
; Clobbers: HL.
stg_a_home:
	ld hl,#0x0000
	ld (rom_storage_track),hl
	ret

; SETTRK backend.
; Input: BC = CP/M track.
; Output: rom_storage_track updated.
stg_a_settrk:
	ld (rom_storage_track),bc
	ret

; SETSEC backend.
; Input: BC = CP/M sector within track.
; Output: rom_storage_sector updated.
stg_a_setsec:
	ld (rom_storage_sector),bc
	ret

; Select drive A.
; Output: HL = ROMDISK_DPH, rom_storage_selected_drive = 0.
stg_a_seldsk:
	xor a
	ld (rom_storage_selected_drive),a
	ld hl,#ROMDISK_DPH
	ret

; Select unsupported drive.
; Output: HL = 0000h, rom_storage_selected_drive = FFh.
stg_a_seldsk_unsupported:
	ld a,#0xff
	ld (rom_storage_selected_drive),a
	ld hl,#0x0000
	ret

; SECTRAN backend.
; Input: BC = logical sector.
; Output: HL = same logical sector; the ROM disk uses no skew table.
stg_a_sectran:
	ld h,b
	ld l,c
	ret

; READ backend.
; Purpose:
;   Copy one 128-byte record from flash into the caller's DMA buffer.
; Inputs:
;   rom_storage_track/rom_storage_sector select the record; DMA_BANK and
;   cbios_dma_addr identify the caller's DMA buffer.
; Outputs:
;   A = BIOS_OK on success, BIOS_ERR on invalid drive/track/sector.
; Clobbers:
;   AF, BC, DE, HL.
; Important invariants:
;   The latch is returned to RAM-only mode on the selected bank before this
;   returns.  CURRENT_BANK is never changed: shadow mode only alters what the
;   decoder selects, not which bank the BIOS considers active.
;
;   A record never straddles the shadow window.  The highest source address is
;   record 383 at 0BF80h, whose last byte is 0BFFFh, so the copy stays clear of
;   the forced-bank-0 region at C000h.
;
;   The destination may legitimately be at or above C000h.  FORCE_BANK0 sends
;   those writes to common bank 0, which is exactly right for a DMA buffer in
;   the protected common TPA.
; Interrupts:
;   Masked across the LDIR, because an interrupt handler fetching from below
;   C000h would read flash instead of its own code.  The window is one record,
;   about 2700 T-states, roughly seven character times at 115200 against a
;   3-deep SIO RX FIFO.  Never widen this to a whole block.
;
;   As with the IOCALL transfers in cbios_ioc_command.asm, this assumes the
;   caller had interrupts enabled, which every current caller does; preserving
;   the entry state properly needs ld a,i with the Z80 erratum retry.
stg_a_read:
	call rom_map_current
	or a
	ret nz

	; Build the shadow/copy latch value: ROM page in D7:D5 supplies the read
	; side, SHADOW_BIT opens the window, and the caller's DMA bank in D2:D0
	; takes the writes.  ROM_DIS stays clear; that is what makes ROM visible.
	ld a,c
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a				; A = page << 5
	ld b,a
	ld a,(DMA_BANK)
	and #BANK_MASK
	or b
	or #SHADOW_BIT
	ld b,a				; B = shadow latch value

	ld de,(cbios_dma_addr)
	di
	ld a,b
	out (BANK_PORT),a
	ld bc,#ROMDISK_RECORD_BYTES
	ldir
	ld a,(CURRENT_BANK)
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ei
	xor a
	ret

; WRITE backend.
; Purpose:
;   Refuse the write.  The volume is in flash and there is nothing to write to.
; Outputs:
;   A = BIOS_ERR, always.
stg_a_write:
	ld a,#BIOS_ERR
	ret

; Map the current CP/M track and 0-based sector to a ROM page and address.
; Output on success: A=0, C=ROM page, HL=address in 0000h-0BF80h.
; Output on failure: A=BIOS_ERR.
;
; Walkthrough:
;   1. Reject unsupported drives and out-of-range tracks/sectors.
;   2. Convert track to record offset with track * ROMDISK_SECTORS_PER_TRACK.
;   3. Add sector to get an absolute 128-byte record number.
;   4. Subtract ROMDISK_RECORDS_PER_PAGE until the target ROM page is found.
;   5. Convert record-within-page to a byte address by multiplying by 128.
rom_map_current:
	ld a,(rom_storage_selected_drive)
	or a
	jr nz,rom_map_error

	ld hl,(rom_storage_track)
	ld a,h
	or a
	jr nz,rom_map_error
	ld a,l
	cp #ROMDISK_TRACKS
	jr nc,rom_map_error

	ld h,#0x00
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,de
	ex de,hl

	ld hl,(rom_storage_sector)
	ld a,h
	or a
	jr nz,rom_map_error
	ld a,l
	cp #ROMDISK_SECTORS_PER_TRACK
	jr nc,rom_map_error

	add hl,de
	ld c,#ROMDISK_FIRST_PAGE

rom_map_page_loop:
	ld de,#ROMDISK_RECORDS_PER_PAGE
	or a
	sbc hl,de
	jr c,rom_map_page_found
	inc c
	jr rom_map_page_loop

rom_map_page_found:
	add hl,de
	ld a,l
	and #0x01
	jr z,rom_map_low_zero
	ld e,#0x80
	jr rom_map_have_low
rom_map_low_zero:
	ld e,#0x00
rom_map_have_low:
	srl h
	rr l
	ld h,l
	ld l,e
	xor a
	ret

rom_map_error:
	ld a,#BIOS_ERR
	ret

ROMDISK_CODE_END:
STORAGE_A_CODE_END:

; CP/M Drive Parameter Header and Block for drive A.
;
; These share the fixed DPH/DPB window with the SD backend, whose DPH sits at
; SD_STORAGE_DPH (this base + 20h).  DPH (16) + DPB (15) fills the 32 bytes
; below it exactly, so nothing may be added here.  ROMDISK_DIRBUF is the shared
; CP/M directory buffer; CSV is a null pointer because CKS is zero.
	.area WORK (ABS)
	.org VDRIP_STORAGE_DPHDPB_BASE
STORAGE_A_DPH:
ROMDISK_DPH:
	.dw 0x0000			; XLT: no skew table
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw ROMDISK_DIRBUF
	.dw ROMDISK_DPB
	.dw 0x0000			; CSV: unused, CKS = 0
	.dw ROMDISK_ALV

; CP/M Drive Parameter Block for the flash volume:
;   SPT=48, BSH=3, BLM=7, EXM=0, DSM=143, DRM=127, AL0=F0h, AL1=00h,
;   CKS=0, OFF=0.
STORAGE_A_DPB:
ROMDISK_DPB:
	.dw ROMDISK_SECTORS_PER_TRACK
	.db ROMDISK_BLOCK_SHIFT
	.db ROMDISK_BLOCK_MASK
	.db ROMDISK_EXTENT_MASK
	.dw ROMDISK_MAX_BLOCK
	.dw ROMDISK_DIR_ENTRIES
	.db ROMDISK_ALLOC0
	.db ROMDISK_ALLOC1
	.dw ROMDISK_CHECK_SIZE
	.dw ROMDISK_OFFSET_TRACKS

	.area WORK (ABS)
	.org VDRIP_STORAGE_ALV_BUFFER
STORAGE_A_ALV:
ROMDISK_ALV:
	.blkb ROMDISK_ALV_SIZE

	.area WORK (ABS)
	.org CBIOS_STORAGE_WORK_AREA
STORAGE_STATE_START:
; Persistent storage backend state, in the BIOS runtime-state window rather than
; in MOVE_BUFFER.  Only 11 bytes are available here before the VDrip transport's
; block at CBIOS_VDRIP_TRANSPORT_WORK_AREA; this backend uses five.
stg_a_selected_drive:
rom_storage_selected_drive:
	.db 0xff
stg_a_track:
rom_storage_track:
	.dw 0x0000
stg_a_sector:
rom_storage_sector:
	.dw 0x0000

	.org CBIOS_STORAGE_CALLER_SP
storage_caller_sp:
	.dw 0x0000
STORAGE_STATE_END:

	.area CODE (ABS)
