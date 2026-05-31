; Local Zephyr-80 CP/M RAM disk backend.
;
; Drive A is backed by RAM banks 2-7, addresses 0000h-BFFFh in each bank.
; CP/M owns the filesystem layout; this BIOS layer only maps and transfers
; 128-byte records.
;
; Geometry assumptions:
;   6 banks * 48 KiB/bank = 294912 bytes.
;   128-byte CP/M records produce 0180h records per bank and 0900h total.
;   48 tracks * 48 sectors/track * 128 bytes/sector = full capacity.
;   Allocation and directory parameters are encoded in RAMDISK_DPB below.
;
; MOVE_BUFFER is the cross-bank staging buffer. RAMDISK_DIRBUF is the CP/M
; directory buffer referenced by the DPH. Both live in the scratch/staging area
; and must never overlap resident code or persistent runtime state.

	.globl ramdisk_home,ramdisk_seldsk,ramdisk_seldsk_unsupported
	.globl ramdisk_settrk,ramdisk_setsec,ramdisk_read,ramdisk_write
	.globl ramdisk_sectran
	.globl RAMDISK_CODE_START,RAMDISK_CODE_END
	.globl STORAGE_STATE_START,STORAGE_STATE_END
	.globl RAMDISK_DPH,RAMDISK_DPB,RAMDISK_CSV,RAMDISK_ALV
	.globl ramdisk_selected_drive,ramdisk_track,ramdisk_sector
	.globl CURRENT_BANK,DMA_BANK,cbios_dma_addr

; This inactive backend preserves the original banked RAM disk implementation
; after the active storage backend moved to VDrip proxy storage. Keep its legacy
; geometry names local to this file so the active VDrip storage definitions stay
; unambiguous.
CBIOS_RAMDISK_CODE_BASE		= CBIOS_STORAGE_VDRIP_CODE_BASE
RAMDISK_DRIVE			= 0x00
RAMDISK_FIRST_BANK		= 0x02
RAMDISK_LAST_BANK		= 0x07
RAMDISK_BANK_COUNT		= 0x06
RAMDISK_BANK_BASE		= 0x0000
RAMDISK_BANK_LIMIT		= 0xc000
RAMDISK_BANK_BYTES		= 0xc000
RAMDISK_RECORD_BYTES		= 0x0080
RAMDISK_RECORDS_PER_BANK	= 0x0180
RAMDISK_TOTAL_RECORDS		= 0x0900
RAMDISK_SECTORS_PER_TRACK	= 0x0030
RAMDISK_TRACKS			= 0x0030
RAMDISK_OFFSET_TRACKS		= 0x0000
RAMDISK_BLOCK_SHIFT		= 0x04
RAMDISK_BLOCK_MASK		= 0x0f
RAMDISK_EXTENT_MASK		= 0x01
RAMDISK_MAX_BLOCK		= 0x008f
RAMDISK_DIR_ENTRIES		= 0x003f
RAMDISK_ALLOC0			= 0x80
RAMDISK_ALLOC1			= 0x00
RAMDISK_CHECK_SIZE		= 0x0010
RAMDISK_ALV_SIZE		= 0x0012
RAMDISK_DIRBUF			= VDRIP_STORAGE_DIRBUF

	.area CODE (ABS)
	.org CBIOS_RAMDISK_CODE_BASE

RAMDISK_CODE_START:

; HOME
; Purpose: reset the selected CP/M track to zero.
; Inputs: none.
; Outputs: ramdisk_track = 0000h.
; Clobbers: HL.
ramdisk_home:
	ld hl,#0x0000
	ld (ramdisk_track),hl
	ret

; SETTRK backend.
; Input: BC = CP/M track.
; Output: ramdisk_track updated.
ramdisk_settrk:
	ld (ramdisk_track),bc
	ret

; SETSEC backend.
; Input: BC = CP/M sector within track.
; Output: ramdisk_sector updated.
ramdisk_setsec:
	ld (ramdisk_sector),bc
	ret

; Select drive A.
; Output: HL = RAMDISK_DPH, ramdisk_selected_drive = 0.
ramdisk_seldsk:
	xor a
	ld (ramdisk_selected_drive),a
	ld hl,#RAMDISK_DPH
	ret

; Select unsupported drive.
; Output: HL = 0000h, ramdisk_selected_drive = FFh.
ramdisk_seldsk_unsupported:
	ld a,#0xff
	ld (ramdisk_selected_drive),a
	ld hl,#0x0000
	ret

; SECTRAN backend.
; Input: BC = logical sector.
; Output: HL = same logical sector; the RAM disk uses no skew table.
ramdisk_sectran:
	ld h,b
	ld l,c
	ret

; READ backend.
; Purpose:
;   Copy one 128-byte record from RAM disk bank storage to the caller DMA bank.
; Inputs:
;   ramdisk_track/ramdisk_sector select the record; DMA_BANK and cbios_dma_addr
;   identify the caller's DMA buffer.
; Outputs:
;   A = BIOS_OK on success, BIOS_ERR on invalid drive/track/sector.
; Clobbers:
;   AF, BC, DE, HL.
; Important invariants:
;   The active bank is restored from RAMDISK_SAVED_BANK before returning.
;   Cross-bank transfer always stages through MOVE_BUFFER in common scratch.
ramdisk_read:
	call ramdisk_map_current
	or a
	ret nz
	ld (RAMDISK_IO_ADDR),hl
	ld a,c
	ld (RAMDISK_IO_BANK),a
	ld a,(CURRENT_BANK)
	ld (RAMDISK_SAVED_BANK),a

	ld a,(RAMDISK_IO_BANK)
	call ramdisk_select_bank_a
	ld hl,(RAMDISK_IO_ADDR)
	ld de,#MOVE_BUFFER
	ld bc,#RAMDISK_RECORD_BYTES
	ldir

	ld a,(DMA_BANK)
	call ramdisk_select_bank_a
	ld hl,#MOVE_BUFFER
	ld de,(cbios_dma_addr)
	ld bc,#RAMDISK_RECORD_BYTES
	ldir
	jr ramdisk_restore_ok

; WRITE backend.
; Purpose:
;   Copy one 128-byte record from the caller DMA bank into RAM disk bank
;   storage.
; Inputs/Outputs/Clobbers:
;   Same contract as ramdisk_read.
ramdisk_write:
	call ramdisk_map_current
	or a
	ret nz
	ld (RAMDISK_IO_ADDR),hl
	ld a,c
	ld (RAMDISK_IO_BANK),a
	ld a,(CURRENT_BANK)
	ld (RAMDISK_SAVED_BANK),a

	ld a,(DMA_BANK)
	call ramdisk_select_bank_a
	ld hl,(cbios_dma_addr)
	ld de,#MOVE_BUFFER
	ld bc,#RAMDISK_RECORD_BYTES
	ldir

	ld a,(RAMDISK_IO_BANK)
	call ramdisk_select_bank_a
	ld hl,#MOVE_BUFFER
	ld de,(RAMDISK_IO_ADDR)
	ld bc,#RAMDISK_RECORD_BYTES
	ldir

ramdisk_restore_ok:
	ld a,(RAMDISK_SAVED_BANK)
	call ramdisk_select_bank_a
	xor a
	ret

; Map the current CP/M track and 0-based sector to a storage bank/address.
; Output on success: A=0, C=bank, HL=address. Output on failure: A=BIOS_ERR.
;
; Walkthrough:
;   1. Reject unsupported drives and out-of-range tracks/sectors.
;   2. Convert track to record offset with track * RAMDISK_SECTORS_PER_TRACK.
;   3. Add sector to get an absolute 128-byte record number.
;   4. Subtract RAMDISK_RECORDS_PER_BANK until the target RAM bank is found.
;   5. Convert record-within-bank to a byte address by multiplying by 128.
ramdisk_map_current:
	ld a,(ramdisk_selected_drive)
	or a
	jr nz,ramdisk_map_error

	ld hl,(ramdisk_track)
	ld a,h
	or a
	jr nz,ramdisk_map_error
	ld a,l
	cp #RAMDISK_TRACKS
	jr nc,ramdisk_map_error

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

	ld hl,(ramdisk_sector)
	ld a,h
	or a
	jr nz,ramdisk_map_error
	ld a,l
	cp #RAMDISK_SECTORS_PER_TRACK
	jr nc,ramdisk_map_error

	add hl,de
	ld c,#RAMDISK_FIRST_BANK

ramdisk_map_bank_loop:
	ld de,#RAMDISK_RECORDS_PER_BANK
	or a
	sbc hl,de
	jr c,ramdisk_map_bank_found
	inc c
	jr ramdisk_map_bank_loop

ramdisk_map_bank_found:
	add hl,de
	ld a,l
	and #0x01
	jr z,ramdisk_map_low_zero
	ld e,#0x80
	jr ramdisk_map_have_low
ramdisk_map_low_zero:
	ld e,#0x00
ramdisk_map_have_low:
	srl h
	rr l
	ld h,l
	ld l,e
	xor a
	ret

ramdisk_map_error:
	ld a,#BIOS_ERR
	ret

; Select a RAM-only bank and update CURRENT_BANK.
; Input: A = bank number.
; Output: hardware bank latch and CURRENT_BANK updated.
; Clobbers: AF.
ramdisk_select_bank_a:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; CP/M Drive Parameter Header for drive A. The allocation/check vectors are
; persistent runtime state; RAMDISK_DIRBUF is a scratch directory buffer.
RAMDISK_DPH:
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw RAMDISK_DIRBUF
	.dw RAMDISK_DPB
	.dw RAMDISK_CSV
	.dw RAMDISK_ALV

; CP/M Drive Parameter Block for the in-memory drive geometry above.
RAMDISK_DPB:
	.dw RAMDISK_SECTORS_PER_TRACK
	.db RAMDISK_BLOCK_SHIFT
	.db RAMDISK_BLOCK_MASK
	.db RAMDISK_EXTENT_MASK
	.dw RAMDISK_MAX_BLOCK
	.dw RAMDISK_DIR_ENTRIES
	.db RAMDISK_ALLOC0
	.db RAMDISK_ALLOC1
	.dw RAMDISK_CHECK_SIZE
	.dw RAMDISK_OFFSET_TRACKS

RAMDISK_CODE_END:

	.area WORK (ABS)
	.org CBIOS_STORAGE_WORK_AREA
STORAGE_STATE_START:
ramdisk_selected_drive:
	.db 0xff
ramdisk_track:
	.dw 0x0000
ramdisk_sector:
	.dw 0x0000
RAMDISK_SAVED_BANK:
	.db 0x00
RAMDISK_IO_BANK:
	.db 0x00
RAMDISK_IO_ADDR:
	.dw 0x0000
RAMDISK_CSV:
	.blkb RAMDISK_CHECK_SIZE
RAMDISK_ALV:
	.blkb RAMDISK_ALV_SIZE
STORAGE_STATE_END:

	.area CODE (ABS)
