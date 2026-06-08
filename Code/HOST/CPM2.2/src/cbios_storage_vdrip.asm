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
;   4. Temporarily register vdrip_storage_rx_sink on SIO_CH_CONSOLE.
;   5. Send the framed storage request through vdrip_send_packet.
;   6. Wait for a framed reply with matching type, length, sequence, and
;      success status.
;   7. Restore the normal console RX sink and saved RTS state.
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
	.globl sio_register_rx_sink,sio_rx_kick
	.globl vdrip_rx_sink,vdrip_send_packet,vdrip_rts_assert_raw,crc8_update
	.globl vdrip_rx_rts_released

STORAGE_RX_WAIT_SYNC0	= 0x00
STORAGE_RX_WAIT_SYNC1	= 0x01
STORAGE_RX_LEN		= 0x02
STORAGE_RX_TYPE		= 0x03
STORAGE_RX_PAYLOAD	= 0x04
STORAGE_RX_CRC		= 0x05

STORAGE_READ_REQ_LEN	= 0x06
STORAGE_READ_REPLY_LEN	= 0x82
STORAGE_WRITE_REQ_LEN	= 0x86
STORAGE_WRITE_REPLY_LEN	= 0x02
STORAGE_REPLY_MAX_LEN	= STORAGE_READ_REPLY_LEN
STORAGE_WRITE_DATA_OFF	= 0x06
STORAGE_READ_DATA_OFF	= 0x02
STORAGE_TIMEOUT		= 0xffff

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
	call vdrip_storage_next_seq
	ld (vdrip_storage_active_seq),a
	call vdrip_storage_build_request_header

	ld a,#PACKET_STORAGE_READ_REPLY
	ld b,#STORAGE_READ_REPLY_LEN
	call vdrip_storage_begin

	or a
	ret nz

	ld a,#PACKET_STORAGE_READ_REQ
	ld b,#STORAGE_READ_REQ_LEN
	ld hl,#MOVE_BUFFER
	call vdrip_send_packet
	call vdrip_storage_wait_reply
	call vdrip_storage_end
	or a
	ret nz

	call vdrip_storage_copy_read_to_dma
	xor a
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
	call vdrip_storage_next_seq
	ld (vdrip_storage_active_seq),a
	call vdrip_storage_build_request_header
	call vdrip_storage_copy_dma_to_write

	ld a,#PACKET_STORAGE_WRITE_REPLY
	ld b,#STORAGE_WRITE_REPLY_LEN
	call vdrip_storage_begin

	ld a,#PACKET_STORAGE_WRITE_REQ
	ld b,#STORAGE_WRITE_REQ_LEN
	ld hl,#MOVE_BUFFER
	call vdrip_send_packet
	call vdrip_storage_wait_reply
	call vdrip_storage_end
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

; Increment the storage sequence byte. Zero is skipped so completion diagnostics
; and reply matching never use the all-clear sentinel value.
; Output: A = new sequence.
vdrip_storage_next_seq:
	ld a,(vdrip_storage_seq)
	inc a
	jr nz,vdrip_storage_next_seq_store
	inc a
vdrip_storage_next_seq_store:
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

; Enter transaction-scoped storage receive mode.
; Input: A = expected reply packet type, B = expected reply payload length.
; Output: A = BIOS_OK / BIOS_ERR.
vdrip_storage_begin:
	ld (storage_expected_type),a
	ld a,b
	ld (storage_expected_len),a
	ld a,(vdrip_storage_active_seq)
	ld (storage_expected_seq),a
	xor a
	ld (storage_rx_state),a
	ld (storage_rx_complete),a
	ld (storage_rx_error),a

    ; Save console RTS state before we take the channel
    ld a,(vdrip_rx_rts_released)
    ld (vdrip_storage_saved_rts_state),a	

	di
	ld hl,#vdrip_storage_rx_sink
	ld a,#SIO_CH_CONSOLE
	call sio_register_rx_sink
	ei
	or a
	ret nz

	call vdrip_rts_assert_raw
	xor a
	ret

; Restore the normal raw keyboard RX sink after a storage transaction.
; Preserves A so callers keep the transaction status.
vdrip_storage_end:
	di
	push af
	ld hl,#vdrip_rx_sink
	ld a,#SIO_CH_CONSOLE
	call sio_register_rx_sink
	ei
    ; Restore pre-transaction RTS state instead of blindly clearing
    ld a,(vdrip_storage_saved_rts_state)
    ld (vdrip_rx_rts_released),a
    or a
    jr nz,vdrip_storage_end_was_released
    call vdrip_rts_assert_raw      ; console said RTS was asserted, re-assert
    jr vdrip_storage_end_done
vdrip_storage_end_was_released:
    call vdrip_rts_release_raw     ; console had released RTS, restore that state
vdrip_storage_end_done:
    pop af
    ret

; Wait for the storage RX sink to complete the expected reply.
; Output: A = BIOS_OK or BIOS_ERR.
vdrip_storage_wait_reply:
	ld de,#STORAGE_TIMEOUT

vdrip_storage_wait_loop:
	ld a,(storage_rx_error)
	or a
	jr nz,vdrip_storage_wait_error
	ld a,(storage_rx_complete)
	or a
	jr nz,vdrip_storage_wait_ok

	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick

	ld a,(storage_rx_error)
	or a
	jr nz,vdrip_storage_wait_error
	ld a,(storage_rx_complete)
	or a
	jr nz,vdrip_storage_wait_ok

	dec de
	ld a,d
	or e
	jr nz,vdrip_storage_wait_loop

vdrip_storage_wait_error:
	ld a,#BIOS_ERR
	ret

vdrip_storage_wait_ok:
	xor a
	ret

; Storage reply RX sink. Runs from SIO ISR or foreground sio_rx_kick.
; Inputs: A = SIO channel id, C = received byte.
; ISR-safe: does bounded parser work only; no VDrip output and no bank switch.
vdrip_storage_rx_sink:
	push af
	push bc
	push de
	push hl

	cp #SIO_CH_CONSOLE
	jr nz,vdrip_storage_rx_done
	ld a,c
	call vdrip_storage_parse_byte

vdrip_storage_rx_done:
	pop hl
	pop de
	pop bc
	pop af
	ret

; Transaction-scoped framed reply parser.
; Unexpected raw bytes before A5 are ignored. Valid PACKET_TERMINAL_RX packets
; that slip into the transaction window are ignored after CRC validation;
; in-flight console input must not turn into BDOS disk errors. Malformed frames
; or storage replies with bad length, type, sequence, status, or payload size
; still fail the transaction.
vdrip_storage_parse_byte:
	ld c,a
	ld a,(storage_rx_state)
	cp #STORAGE_RX_WAIT_SYNC0
	jr z,storage_parse_wait_sync0
	cp #STORAGE_RX_WAIT_SYNC1
	jr z,storage_parse_wait_sync1
	cp #STORAGE_RX_LEN
	jr z,storage_parse_len
	cp #STORAGE_RX_TYPE
	jr z,storage_parse_type
	cp #STORAGE_RX_PAYLOAD
	jr z,storage_parse_payload
	cp #STORAGE_RX_CRC
	jp z,storage_parse_crc
	xor a
	ld (storage_rx_state),a
	ret

storage_parse_wait_sync0:
	ld a,c
	cp #PACKET_SYNC0
	ret nz
	ld a,#STORAGE_RX_WAIT_SYNC1
	ld (storage_rx_state),a
	ret

storage_parse_wait_sync1:
	ld a,c
	cp #PACKET_SYNC1
	jr z,storage_parse_sync_done
	cp #PACKET_SYNC0
	jr z,storage_parse_keep_sync1
	xor a
	ld (storage_rx_state),a
	ret

storage_parse_keep_sync1:
	ld a,#STORAGE_RX_WAIT_SYNC1
	ld (storage_rx_state),a
	ret

storage_parse_sync_done:
	ld a,#STORAGE_RX_LEN
	ld (storage_rx_state),a
	ret

storage_parse_len:
	ld a,c
	cp #VDRIP_WIRE_OVERHEAD
	jp c,storage_parse_error
	ld (storage_rx_len),a
	ld c,#0x00
	call crc8_update
	ld a,c
	ld (storage_rx_crc),a

	ld a,(storage_rx_len)
	sub #VDRIP_WIRE_OVERHEAD
	cp #(STORAGE_REPLY_MAX_LEN + 1)
	jp nc,storage_parse_error
	ld (storage_rx_payload_len),a
	ld (storage_rx_remaining),a
	xor a
	ld (storage_rx_index),a
	ld a,#STORAGE_RX_TYPE
	ld (storage_rx_state),a
	ret

storage_parse_type:
	ld a,c
	ld (storage_rx_type),a
	ld e,a
	ld a,(storage_rx_crc)
	ld c,a
	ld a,e
	call crc8_update
	ld a,c
	ld (storage_rx_crc),a

	ld a,(storage_rx_payload_len)
	or a
	jr z,storage_parse_expect_crc
	ld a,#STORAGE_RX_PAYLOAD
	ld (storage_rx_state),a
	ret

storage_parse_expect_crc:
	ld a,#STORAGE_RX_CRC
	ld (storage_rx_state),a
	ret

storage_parse_payload:
	ld hl,#MOVE_BUFFER
	ld a,(storage_rx_index)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld e,c
	ld a,(storage_rx_crc)
	ld c,a
	ld a,e
	call crc8_update
	ld a,c
	ld (storage_rx_crc),a

	ld a,(storage_rx_index)
	inc a
	ld (storage_rx_index),a
	ld a,(storage_rx_remaining)
	dec a
	ld (storage_rx_remaining),a
	jr z,storage_parse_expect_crc
	ret

storage_parse_crc:
	ld a,(storage_rx_crc)
	cp c
	jr nz,storage_parse_error

	ld a,(storage_rx_type)
	cp #PACKET_TERMINAL_RX
	jr z,storage_parse_crc_reset
	ld b,a
	ld a,(storage_expected_type)
	cp b
	jr nz,storage_parse_error

	; Console packets can already be in flight when storage_begin swaps the RX
	; sink. PACKET_TERMINAL_RX is ignored above after CRC validation so the
	; parser keeps waiting for the real storage reply.
	ld a,(storage_rx_payload_len)
	ld b,a
	ld a,(storage_expected_len)
	cp b
	jr nz,storage_parse_error

	ld a,(MOVE_BUFFER)
	ld b,a
	ld a,(storage_expected_seq)
	cp b
	jr nz,storage_parse_error

	ld a,(MOVE_BUFFER + 1)
	or a
	jr nz,storage_parse_error

	ld a,#0x01
	ld (storage_rx_complete),a
storage_parse_crc_reset:
	xor a
	ld (storage_rx_state),a
	ret

storage_parse_error:
	ld a,#0x01
	ld (storage_rx_error),a
	xor a
	ld (storage_rx_state),a
	ret

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
storage_expected_type:
	.db 0x00
storage_expected_len:
	.db 0x00
storage_expected_seq:
	.db 0x00
storage_rx_state:
	.db STORAGE_RX_WAIT_SYNC0
storage_rx_len:
	.db 0x00
storage_rx_type:
	.db 0x00
storage_rx_payload_len:
	.db 0x00
storage_rx_remaining:
	.db 0x00
storage_rx_index:
	.db 0x00
storage_rx_crc:
	.db 0x00
storage_rx_complete:
	.db 0x00
storage_rx_error:
	.db 0x00
storage_caller_sp:
	.dw 0x0000
VDRIP_STORAGE_CSV:
	.blkb VDRIP_STORAGE_CHECK_SIZE
STORAGE_STATE_END:

	.area CODE (ABS)
