; Local Zephyr-80 CP/M VDrip storage backend.
;
; Drive A is backed by the proxy-side "Zephyr VDrip CP/M 8M" flat image.
; CP/M owns the filesystem layout; this BIOS layer only maps standard 128-byte
; records to Virtual Drip storage transactions.
;
; Geometry assumptions:
;   8,388,608 bytes, 65,536 logical 128-byte records.
;   4 records/track, 16,384 tracks, no reserved/system tracks.
;   4 KiB allocation blocks, 2048 blocks, 512 directory entries.
;
; Packet constants use the next free Virtual Drip packet IDs after existing
; display/control packets:
;   0Dh READ request, 0Eh READ reply, 0Fh WRITE request, 10h WRITE reply.
;
; MOVE_BUFFER is transaction scratch. READ replies store payload bytes there
; before copying data to the caller DMA bank; WRITE requests stage the caller
; DMA record there before transmission.
;
; Transaction flow:
;   1. Validate selected drive, track, and sector.
;   2. Compute LBA = track * 4 + sector.
;   3. Allocate a nonzero sequence byte and build the request header.
;   4. Enter common transport STORAGE_FRAME receive mode.
;   5. Send the framed storage request through the common sender.
;   6. Wait for common dispatch to validate type, length, sequence, and status.
;   7. Restore raw/PTY idle receive mode and saved RTS state.
;
; The backend is deliberately not a RAM disk. The old banked RAM disk backend
; is preserved separately in cbios_storage_ramdisk.asm and is not linked by the
; active VDrip build.

	.globl vdrip_storage_home,vdrip_storage_seldsk,vdrip_storage_seldsk_unsupported
	.globl vdrip_storage_settrk,vdrip_storage_setsec,vdrip_storage_read,vdrip_storage_write
	.globl vdrip_storage_sectran
	.globl VDRIP_STORAGE_CODE_START,VDRIP_STORAGE_CODE_END
	.globl STORAGE_STATE_START,STORAGE_STATE_END
	.globl VDRIP_STORAGE_DPH,VDRIP_STORAGE_DPB,VDRIP_STORAGE_CSV,VDRIP_STORAGE_ALV
	.globl vdrip_storage_selected_drive,vdrip_storage_track,vdrip_storage_sector
	.globl CURRENT_BANK,DMA_BANK,cbios_dma_addr
	.globl vdrip_send_packet,vdrip_rts_assert_raw
	.globl vdrip_rx_rts_released
	.globl vdrip_transport_wait_ready
	.globl vdrip_transport_begin_storage,vdrip_transport_end_storage
	.globl vdrip_transport_wait_reply
	.globl vdrip_proxy_online

STORAGE_READ_REQ_LEN	= 0x06
STORAGE_READ_REPLY_LEN	= 0x82
STORAGE_WRITE_REQ_LEN	= 0x86
STORAGE_WRITE_REPLY_LEN	= 0x02
STORAGE_WRITE_DATA_OFF	= 0x06
STORAGE_READ_DATA_OFF	= 0x02

	.area CODE (ABS)
	.org CBIOS_STORAGE_VDRIP_CODE_BASE

VDRIP_STORAGE_CODE_START:

; HOME
; Purpose: reset the selected CP/M track to zero.
; Inputs: none.
; Outputs: vdrip_storage_track = 0000h.
; Clobbers: HL.
vdrip_storage_home:
	ld hl,#0x0000
	ld (vdrip_storage_track),hl
	ret

; SETTRK backend.
; Input: BC = CP/M track.
; Output: vdrip_storage_track updated.
vdrip_storage_settrk:
	ld (vdrip_storage_track),bc
	ret

; SETSEC backend.
; Input: BC = zero-based CP/M sector within track.
; Output: vdrip_storage_sector updated.
vdrip_storage_setsec:
	ld (vdrip_storage_sector),bc
	ret

; Select drive A.
; Output: HL = VDRIP_STORAGE_DPH, vdrip_storage_selected_drive = 0.
vdrip_storage_seldsk:
	xor a
	ld (vdrip_storage_selected_drive),a
	ld hl,#VDRIP_STORAGE_DPH
	ret

; Select unsupported drive.
; Output: HL = 0000h, vdrip_storage_selected_drive = FFh.
vdrip_storage_seldsk_unsupported:
	ld a,#0xff
	ld (vdrip_storage_selected_drive),a
	ld hl,#0x0000
	ret

; SECTRAN backend.
; Input: BC = logical sector.
; Output: HL = same logical sector; VDrip storage uses no skew table.
vdrip_storage_sectran:
	ld h,b
	ld l,c
	ret

; READ backend.
; Purpose:
;   Fetch one CP/M 128-byte record from the VDrip proxy into the caller DMA
;   bank/address.
; Inputs:
;   vdrip_storage_track/vdrip_storage_sector select the record; DMA_BANK and cbios_dma_addr
;   identify the caller's DMA buffer.
; Outputs:
;   A = BIOS_OK on success, BIOS_ERR on invalid address or storage failure.
; Clobbers:
;   AF, BC, DE, HL.
; Blocking behavior:
;   Bounded by STORAGE_TIMEOUT while waiting for the framed storage reply.
vdrip_storage_read:
	call vdrip_storage_compute_lba
	or a
	ret nz
	call vdrip_transport_wait_ready
	or a
	ret nz
	call vdrip_storage_next_seq
	ld (vdrip_storage_active_seq),a
	call vdrip_storage_build_request_header

	ld a,#PACKET_STORAGE_READ_REPLY
	call vdrip_storage_begin

	or a
	ret nz

	ld a,#PACKET_STORAGE_READ_REQ
	ld b,#STORAGE_READ_REQ_LEN
	ld hl,#MOVE_BUFFER
	call vdrip_send_packet
	or a
	jr nz,vdrip_storage_read_send_error
	call vdrip_storage_wait_reply
	call vdrip_storage_end
	or a
	jr z,vdrip_storage_read_reply_ok
	ld a,#BIOS_ERR
	ret
vdrip_storage_read_reply_ok:
	call vdrip_storage_copy_read_to_dma
	xor a
	ret
vdrip_storage_read_send_error:
	call vdrip_storage_end
	ld a,#BIOS_ERR
	ret

; WRITE backend.
; Purpose:
;   Send one CP/M 128-byte record from the caller DMA bank/address to the VDrip
;   proxy storage image.
; Inputs/Outputs/Clobbers:
;   Same contract as vdrip_storage_read.
vdrip_storage_write:
	call vdrip_storage_compute_lba
	or a
	ret nz
	call vdrip_transport_wait_ready
	or a
	ret nz
	call vdrip_storage_next_seq
	ld (vdrip_storage_active_seq),a
	call vdrip_storage_build_request_header
	call vdrip_storage_copy_dma_to_write

	; RTS handshake around the request transmit. This is the fix for spurious
	; write "Bad Sector"s: MOVE_BUFFER is the transmit source, so the host must
	; not send anything into it while we clock out the 134-byte request. The
	; CRTSCTS host holds its output whenever our RTS is released, so save the
	; current console RTS state and release RTS for the duration of the send.
	; Without this, a stray console byte both scribbles the outgoing record and
	; latches an SIO RX error that wait_reply reads as a failed reply, even
	; though the proxy received and wrote the record successfully. Reads send
	; only 6 bytes, so they almost never hit this window.
	ld a,(vdrip_rx_rts_released)
	ld (vdrip_storage_saved_rts_state),a
	call vdrip_rts_release_raw

	ld a,#PACKET_STORAGE_WRITE_REQ
	ld b,#STORAGE_WRITE_REQ_LEN
	ld hl,#MOVE_BUFFER
	call vdrip_send_packet
	or a
	jr nz,vdrip_storage_write_send_error

	; Request fully on the wire. Arm a clean STORAGE reply window (this clears
	; any transmit-window line error and resets the parser) and only now assert
	; RTS so the host may send its 2-byte reply.
	ld a,(vdrip_storage_active_seq)
	ld c,a
	ld a,#PACKET_STORAGE_WRITE_REPLY
	call vdrip_transport_begin_storage
	call vdrip_rts_assert_raw

	call vdrip_storage_wait_reply
	call vdrip_storage_end
	ret
vdrip_storage_write_send_error:
	call vdrip_storage_end
	ld a,#BIOS_ERR
	ret

; Compute canonical LBA = track * 4 + zero-based sector.
; Output: A=0 and vdrip_storage_lba updated, or A=BIOS_ERR on invalid drive/LBA.
vdrip_storage_compute_lba:
	ld a,(vdrip_storage_selected_drive)
	or a
	jr nz,vdrip_storage_lba_error

	ld hl,(vdrip_storage_track)
	ld a,h
	cp #0x40
	jr nc,vdrip_storage_lba_error

	ld de,(vdrip_storage_sector)
	ld a,d
	or a
	jr nz,vdrip_storage_lba_error
	ld a,e
	cp #VDRIP_STORAGE_SECTORS_PER_TRACK
	jr nc,vdrip_storage_lba_error

	add hl,hl
	add hl,hl
	ld d,#0x00
	add hl,de
	ld (vdrip_storage_lba),hl
	xor a
	ret

vdrip_storage_lba_error:
	ld a,#BIOS_ERR
	ret

; Increment the storage sequence byte with natural FFh -> 00h wrap.
; Output: A = new sequence.
vdrip_storage_next_seq:
	ld a,(vdrip_storage_seq)
	inc a
	ld (vdrip_storage_seq),a
	ret

; Build common READ/WRITE request header at MOVE_BUFFER:
;   seq, drive 0, little-endian 32-bit LBA.
vdrip_storage_build_request_header:
	ld hl,#MOVE_BUFFER
	ld a,(vdrip_storage_active_seq)
	ld (hl),a
	inc hl
	ld (hl),#VDRIP_STORAGE_DRIVE
	inc hl
	ld de,(vdrip_storage_lba)
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	ret

; Copy 128 bytes from the caller DMA bank into WRITE request payload scratch.
vdrip_storage_copy_dma_to_write:
	ld a,(CURRENT_BANK)
	ld (VDRIP_STORAGE_SAVED_BANK),a
	ld a,(DMA_BANK)
	call vdrip_storage_select_bank_a
	ld hl,(cbios_dma_addr)
	ld de,#(MOVE_BUFFER + STORAGE_WRITE_DATA_OFF)
	ld bc,#VDRIP_STORAGE_RECORD_BYTES
	ldir
	ld a,(VDRIP_STORAGE_SAVED_BANK)
	jp vdrip_storage_select_bank_a

; Copy READ reply data from scratch into the caller DMA bank.
vdrip_storage_copy_read_to_dma:
	ld a,(CURRENT_BANK)
	ld (VDRIP_STORAGE_SAVED_BANK),a
	ld a,(DMA_BANK)
	call vdrip_storage_select_bank_a
	ld hl,#(MOVE_BUFFER + STORAGE_READ_DATA_OFF)
	ld de,(cbios_dma_addr)
	ld bc,#VDRIP_STORAGE_RECORD_BYTES
	ldir
	ld a,(VDRIP_STORAGE_SAVED_BANK)
	jp vdrip_storage_select_bank_a

; Enter transaction-scoped common framed receive mode.
; Input: A = expected reply packet type.
; Output: A = BIOS_OK / BIOS_ERR.
vdrip_storage_begin:
	ld b,a
	ld a,(vdrip_rx_rts_released)
	ld (vdrip_storage_saved_rts_state),a
	call vdrip_rts_assert_raw
	ld a,(vdrip_storage_active_seq)
	ld c,a
	ld a,b
	call vdrip_transport_begin_storage
	xor a
	ret

; Restore the console backend's idle receive mode after a storage transaction.
; Preserves A so callers keep the transaction status.
vdrip_storage_end:
	push af
	call vdrip_transport_end_storage
	ld a,(vdrip_storage_saved_rts_state)
	ld (vdrip_rx_rts_released),a
	or a
	jr nz,vdrip_storage_end_was_released
	call vdrip_rts_assert_raw
	jr vdrip_storage_end_done
vdrip_storage_end_was_released:
	call vdrip_rts_release_raw
vdrip_storage_end_done:
	pop af
	ret

; Wait for common transport dispatch to complete the expected reply.
; Output: A = BIOS_OK or BIOS_ERR.
vdrip_storage_wait_reply:
	jp vdrip_transport_wait_reply

; Select a RAM bank and update CURRENT_BANK.
; Input: A = bank number.
; Output: hardware bank latch and CURRENT_BANK updated.
; Clobbers: AF.
vdrip_storage_select_bank_a:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

VDRIP_STORAGE_CODE_END:

; CP/M Drive Parameter Header and Block for drive A.
;
; These live in their own scratch-area slot (VDRIP_STORAGE_DPHDPB_BASE = FB40h), NOT
; in the packed VDrip storage code slot.  They are constants that BDOS reads
; (and re-reads on every Select Disk), so they must never share memory with a
; buffer that gets written during operation.  Previously they sat at the tail
; of the code slot, which overflowed past FA80h into MOVE_BUFFER; every storage
; transfer then overwrote the DPH ALV pointer and the DPB geometry, wrecking
; BDOS as soon as it re-read the DPH after the directory login.
;
; The boot shadow copy mirrors the whole C000h-FFFFh window from ROM to RAM, so
; these initializers load correctly just like code, the same as VDRIP_STORAGE_ALV and
; the storage state block below.
;
; CKS is zero for fixed-disk behavior, so VDRIP_STORAGE_CSV is a zero-length label.
	.area WORK (ABS)
	.org VDRIP_STORAGE_DPHDPB_BASE
VDRIP_STORAGE_DPH:
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw VDRIP_STORAGE_DIRBUF
	.dw VDRIP_STORAGE_DPB
	.dw VDRIP_STORAGE_CSV
	.dw VDRIP_STORAGE_ALV

; CP/M Drive Parameter Block for Zephyr VDrip CP/M 8M:
;   SPT=4, BSH=5, BLM=31, EXM=1, DSM=2047, DRM=511,
;   AL0=F0h, AL1=00h, CKS=0, OFF=0.
VDRIP_STORAGE_DPB:
	.dw VDRIP_STORAGE_SECTORS_PER_TRACK
	.db VDRIP_STORAGE_BLOCK_SHIFT
	.db VDRIP_STORAGE_BLOCK_MASK
	.db VDRIP_STORAGE_EXTENT_MASK
	.dw VDRIP_STORAGE_MAX_BLOCK
	.dw VDRIP_STORAGE_DIR_ENTRIES
	.db VDRIP_STORAGE_ALLOC0
	.db VDRIP_STORAGE_ALLOC1
	.dw VDRIP_STORAGE_CHECK_SIZE
	.dw VDRIP_STORAGE_OFFSET_TRACKS

	.area WORK (ABS)
	.org VDRIP_STORAGE_ALV_BUFFER
VDRIP_STORAGE_ALV:
	.blkb VDRIP_STORAGE_ALV_SIZE

	.area WORK (ABS)
	.org CBIOS_STORAGE_WORK_AREA
STORAGE_STATE_START:
; Persistent storage backend state. These bytes live in the BIOS runtime-state
; window, not in MOVE_BUFFER, so incomplete or failed storage transactions do
; not corrupt CP/M-visible DPH/DPB/ALV pointers.
vdrip_storage_selected_drive:
	.db 0xff
vdrip_storage_track:
	.dw 0x0000
vdrip_storage_sector:
	.dw 0x0000
VDRIP_STORAGE_SAVED_BANK:
	.db 0x00
vdrip_storage_saved_rts_state:
	.db 0x00	
vdrip_storage_seq:
	.db 0x00
vdrip_storage_active_seq:
	.db 0x00
vdrip_storage_lba:
	.dw 0x0000

	.org CBIOS_STORAGE_CALLER_SP
storage_caller_sp:
	.dw 0x0000
VDRIP_STORAGE_CSV:
	.blkb VDRIP_STORAGE_CHECK_SIZE
STORAGE_STATE_END:

	.area CODE (ABS)
