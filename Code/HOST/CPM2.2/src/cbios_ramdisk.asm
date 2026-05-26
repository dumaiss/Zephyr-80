; Local Zephyr-80 CP/M RAM disk backend.
;
; Drive A is backed by RAM banks 2-7, addresses 0000h-BFFFh in each bank.
; CP/M owns the filesystem layout; this BIOS layer only maps and transfers
; 128-byte records.

	.globl ramdisk_home,ramdisk_seldsk,ramdisk_seldsk_unsupported
	.globl ramdisk_settrk,ramdisk_setsec,ramdisk_read,ramdisk_write
	.globl ramdisk_sectran
	.globl RAMDISK_CODE_START,RAMDISK_CODE_END
	.globl STORAGE_STATE_START,STORAGE_STATE_END
	.globl RAMDISK_DPH,RAMDISK_DPB,RAMDISK_CSV,RAMDISK_ALV
	.globl ramdisk_selected_drive,ramdisk_track,ramdisk_sector
	.globl CURRENT_BANK,DMA_BANK,cbios_dma_addr

	.area CODE (ABS)
	.org CBIOS_RAMDISK_CODE_BASE

RAMDISK_CODE_START:

ramdisk_home:
	ld hl,#0x0000
	ld (ramdisk_track),hl
	ret

ramdisk_settrk:
	ld (ramdisk_track),bc
	ret

ramdisk_setsec:
	ld (ramdisk_sector),bc
	ret

ramdisk_seldsk:
	xor a
	ld (ramdisk_selected_drive),a
	ld hl,#RAMDISK_DPH
	ret

ramdisk_seldsk_unsupported:
	ld a,#0xff
	ld (ramdisk_selected_drive),a
	ld hl,#0x0000
	ret

ramdisk_sectran:
	ld h,b
	ld l,c
	ret

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

ramdisk_select_bank_a:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

RAMDISK_DPH:
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw RAMDISK_DIRBUF
	.dw RAMDISK_DPB
	.dw RAMDISK_CSV
	.dw RAMDISK_ALV

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
