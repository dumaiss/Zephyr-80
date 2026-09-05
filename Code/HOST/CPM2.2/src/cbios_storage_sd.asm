; Zephyr-80 CP/M storage backend: SD card via the IO Controller record cache.
;
; Drive B.  The MCU owns an 8-slot LRU cache of 512-byte blocks and serves
; 128-byte CP/M records out of it, so this backend never sees a block and does
; no deblocking.  That is the whole point of the split: deblocking on the Z80
; would cost a 512-byte buffer in a BIOS that does not have one to spare, plus
; a pre-read on every partial write.  Here it costs SRAM the PIC has plenty of.
;
;   READ   record -> CMD_SD_READ_REC, READY, 128 bytes on the bulk lane
;   WRITE  record -> CMD_SD_WRITE_REC, READY, 128 bytes out, then DONE
;
; The record number is what the VDrip backend already computed as its LBA:
; track * 4 + sector, which for an 8 MiB volume is exactly a 16-bit quantity.
; The wire field is 32 bits so the protocol does not need widening later.
;
; WRITE always takes the DONE round trip.  Bytes reaching the MCU says nothing
; about whether they were stored: for a deferred write DONE reports whether the
; containing block could be read, and for the write-through block it reports the
; card's own status.  It is also the only thing that reports a bulk CRC failure.
;
; Scratch is MOVE_BUFFER, which is 192 bytes and divides exactly into the
; 128-byte record and the two 32-byte command frames.  Nothing else is live
; during a storage transaction -- CP/M does not re-enter the BIOS.

	.globl sd_storage_home,sd_storage_settrk
	.globl sd_storage_setsec,sd_storage_read,sd_storage_write
	.globl sd_storage_sectran,sd_storage_flush
	.globl stg_home,stg_seldsk,stg_settrk,stg_setsec
	.globl stg_read,stg_write,stg_sectran
	.globl stg_a_home,stg_a_seldsk,stg_a_seldsk_unsupported
	.globl stg_a_settrk,stg_a_setsec
	.globl stg_a_read,stg_a_write,stg_a_sectran
	.globl storage_caller_sp
	.globl SD_STORAGE_CODE_START,SD_STORAGE_CODE_END
	.globl SD_PROBE_CODE_START,SD_PROBE_CODE_END
	.globl cbios_dma_addr

	.area CODE (ABS)
	.org CBIOS_STORAGE_SD_CODE_BASE

SD_STORAGE_CODE_START:

; ---------------------------------------------------------------------------
; CP/M entry points
; ---------------------------------------------------------------------------

sd_storage_home:
	ld hl,#0
	ld (sd_storage_track),hl
	ret

sd_storage_settrk:
	ld (sd_storage_track),bc
	ret

sd_storage_setsec:
	ld (sd_storage_sector),bc
	ret

sd_storage_sectran:
	ld h,b
	ld l,c
	ret

; ---------------------------------------------------------------------------
; record = track * 4 + sector
;
; Output: A = BIOS_OK and sd_storage_record set, or BIOS_ERR.
; The bounds check is not decoration: a wrapped record is a write to the wrong
; sector, which is the one failure that destroys data while reporting success.
; ---------------------------------------------------------------------------
sd_compute_record:
	ld hl,(sd_storage_track)
	ld a,h
	cp #0x40			; 16384 tracks
	jr nc,sd_record_bad
	ld de,(sd_storage_sector)
	ld a,d
	or a
	jr nz,sd_record_bad
	ld a,e
	cp #4				; 4 records per track
	jr nc,sd_record_bad
	add hl,hl
	add hl,hl
	ld d,#0
	add hl,de
	ld (sd_storage_record),hl
	xor a
	ret
sd_record_bad:
	ld a,#BIOS_ERR
	ret

; ---------------------------------------------------------------------------
; Frame helpers
; ---------------------------------------------------------------------------

; Zero both frames.
sd_zero_frames:
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld b,#64			; tx and rx are adjacent
	xor a
sd_zf_loop:
	ld (hl),a
	inc hl
	djnz sd_zf_loop
	ret

; Build a record-addressed request.  In: A = command class.
sd_build_request:
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld (hl),a			; class
	inc hl
	ld (hl),#0x01			; seq placeholder; IOCALL stamps the real one
	inc hl
	ld (hl),#0x00			; status
	inc hl
	ld (hl),#0x04			; payload length: 32-bit record
	inc hl
	ld de,(sd_storage_record)
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	ret

; Send the staged request and check the reply.
; In:  A = expected response class.
; Out: A = BIOS_OK, or BIOS_ERR / BIOS_ERR_BAD_REPLY.
sd_exchange:
	ld (sd_storage_expect),a
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld de,#(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	call IOCALL
	or a
	jr nz,sd_exchange_xport
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	ld hl,#sd_storage_expect
	cp (hl)
	jr nz,sd_exchange_reply
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + 2)
	or a
	jr nz,sd_exchange_status
	; The MCU echoes the record it decoded.  The frame CRC proves the frame
	; arrived intact; this proves both ends agree on what it MEANT, which a
	; decode bug on either side would survive.
	ld hl,#(MOVE_BUFFER + SD_STORAGE_RX_OFF + 8)
	ld a,(sd_storage_record)
	cp (hl)
	jr nz,sd_exchange_echo
	inc hl
	ld a,(sd_storage_record + 1)
	cp (hl)
	jr nz,sd_exchange_echo
	xor a
	ret
sd_exchange_xport:
	ld a,#BIOS_ERR_TIMEOUT
	ret
sd_exchange_reply:
	ld a,#BIOS_ERR_BAD_REPLY
	ret
sd_exchange_status:
	ld a,#BIOS_ERR_IO
	ret
sd_exchange_echo:
	ld a,#BIOS_ERR_BAD_REPLY
	ret

; ---------------------------------------------------------------------------
; Bank-aware record copies.  The caller's DMA buffer can be in another bank, so
; every transfer stages through MOVE_BUFFER in the BIOS bank.
; ---------------------------------------------------------------------------

sd_copy_to_dma:
	ld a,(CURRENT_BANK)
	ld (sd_storage_saved_bank),a
	ld a,(DMA_BANK)
	call sd_select_bank
	ld hl,#(MOVE_BUFFER + SD_STORAGE_DATA_OFF)
	ld de,(cbios_dma_addr)
	ld bc,#SD_STORAGE_RECORD_BYTES
	ldir
	ld a,(sd_storage_saved_bank)
	jp sd_select_bank

sd_copy_from_dma:
	ld a,(CURRENT_BANK)
	ld (sd_storage_saved_bank),a
	ld a,(DMA_BANK)
	call sd_select_bank
	ld hl,(cbios_dma_addr)
	ld de,#(MOVE_BUFFER + SD_STORAGE_DATA_OFF)
	ld bc,#SD_STORAGE_RECORD_BYTES
	ldir
	ld a,(sd_storage_saved_bank)
	jr sd_select_bank

sd_select_bank:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; ---------------------------------------------------------------------------
; READ one record
; ---------------------------------------------------------------------------
sd_storage_read:
	call sd_compute_record
	or a
	ret nz

	call sd_zero_frames
	ld a,#SD_CMD_READ_REC
	call sd_build_request
	ld a,#SD_RSP_READ_REC
	call sd_exchange
	or a
	ret nz

	; Length comes from READY rather than being assumed: a short transfer is
	; the MCU's to declare, and IOCBULK verifies the CRC trailer itself.
	ld hl,#(MOVE_BUFFER + SD_STORAGE_DATA_OFF)
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + 6)
	ld e,a
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + 7)
	ld d,a
	call IOCBULK
	or a
	jr nz,sd_read_bulk_failed

	call sd_copy_to_dma
	xor a
	ret
sd_read_bulk_failed:
	ld a,#BIOS_ERR_IO
	ret

; ---------------------------------------------------------------------------
; WRITE one record
;
; C holds CP/M's write type on entry and is deliberately ignored.  The deferral
; policy lives on the MCU and is an address rule there -- the block holding the
; directory head is write-through, everything else rides the flush timer -- so
; the controller never has to know what a directory is.
; ---------------------------------------------------------------------------
sd_storage_write:
	call sd_compute_record
	or a
	ret nz

	call sd_copy_from_dma

	call sd_zero_frames
	ld a,#SD_CMD_WRITE_REC
	call sd_build_request
	ld a,#SD_RSP_WRITE_REC
	call sd_exchange
	or a
	ret nz

	ld hl,#(MOVE_BUFFER + SD_STORAGE_DATA_OFF)
	ld de,#SD_STORAGE_RECORD_BYTES
	call IOCBULKW
	or a
	jr nz,sd_write_bulk_failed

	; DONE is mandatory and has no fast path.
	call sd_zero_frames
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld (hl),#SD_CMD_XFER_STATUS
	inc hl
	ld (hl),#0x01
	ld a,#SD_RSP_XFER_STATUS
	ld (sd_storage_expect),a
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld de,#(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	call IOCALL
	or a
	jr nz,sd_write_xport_failed
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	cp #SD_RSP_XFER_STATUS
	jr nz,sd_write_reply_failed
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + 5)
	or a
	jr nz,sd_write_done_failed
	xor a
	ret
sd_write_bulk_failed:
	ld a,#BIOS_ERR_IO
	ret
sd_write_xport_failed:
	ld a,#BIOS_ERR_TIMEOUT
	ret
sd_write_reply_failed:
	ld a,#BIOS_ERR_BAD_REPLY
	ret
sd_write_done_failed:
	ld a,#BIOS_ERR_IO
	ret

; ---------------------------------------------------------------------------
; Commit every dirty cache slot.  No bulk phase: the reply status IS the answer,
; which makes this the one storage command whose result needs no DONE query.
; ---------------------------------------------------------------------------
sd_storage_flush:
	call sd_zero_frames
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld (hl),#SD_CMD_FLUSH
	inc hl
	ld (hl),#0x01
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld de,#(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	call IOCALL
	or a
	jr nz,sd_flush_failed
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	cp #SD_RSP_FLUSH
	jr nz,sd_flush_failed
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + 2)
	or a
	jr nz,sd_flush_failed
	xor a
	ret
sd_flush_failed:
	ld a,#BIOS_ERR_IO
	ret

; ---------------------------------------------------------------------------
; Drive dispatcher
;
; SELDSK records which backend is live; everything after it routes on that.
; CP/M always calls SELDSK before the SETTRK/SETSEC/READ/WRITE that act on a
; drive, so a single "active backend" byte is sufficient and is how ordinary
; multi-drive BIOSes do it.
;
; An unsupported drive parks stg_drive at FFh so a stray READ that arrives
; without a preceding SELDSK fails rather than silently addressing A:.
; ---------------------------------------------------------------------------

stg_seldsk:
	ld a,c
	cp #SD_STORAGE_DRIVE
	jr z,stg_sel_sd
	cp #STORAGE_A_DRIVE
	jr z,stg_sel_a
	ld a,#0xff
	ld (stg_drive),a
	jp stg_a_seldsk_unsupported
stg_sel_sd:
	ld a,#SD_STORAGE_DRIVE
	ld (stg_drive),a
	push bc
	push de
	push hl
	ld hl,#sd_storage_probe
	jr stg_run
stg_sel_a:
	ld a,#STORAGE_A_DRIVE
	ld (stg_drive),a
	jp stg_a_seldsk

; Z set when the SD backend is the live one.
stg_is_sd:
	ld a,(stg_drive)
	cp #SD_STORAGE_DRIVE
	ret

stg_home:
	call stg_is_sd
	jp z,sd_storage_home
	push hl
	call stg_a_home
	pop hl
	ret

stg_settrk:
	call stg_is_sd
	jp z,sd_storage_settrk
	jp stg_a_settrk

stg_setsec:
	call stg_is_sd
	jp z,sd_storage_setsec
	jp stg_a_setsec

stg_sectran:
	call stg_is_sd
	jp z,sd_storage_sectran
	jp stg_a_sectran

; READ and WRITE run on the BIOS stack.
;
; CP/M's BDOS calls disk I/O on a small private stack, and both backends nest
; well past what it allows -- frame build, transport, bulk loop, bank switch.
; The caller's stack is restored before returning.
stg_read:
	push bc
	push de
	push hl
	call stg_is_sd
	ld hl,#sd_storage_read
	jr z,stg_run
	ld hl,#stg_a_read
	jr stg_run

stg_write:
	push bc
	push de
	push hl
	call stg_is_sd
	ld hl,#sd_storage_write
	jr z,stg_run
	ld hl,#stg_a_write

stg_run:
	ld (storage_caller_sp),sp
	ld sp,#CBIOS_CONSOLE_STACK_TOP
	ld de,#stg_run_return
	push de
	jp (hl)
stg_run_return:
	ld hl,(storage_caller_sp)
	ld sp,hl
	pop hl
	pop de
	pop bc
	ret

SD_STORAGE_CODE_END:

; ---------------------------------------------------------------------------
; Disk parameter header and block for B:.
;
; The directory buffer is shared with A:, which is ordinary CP/M -- one DIRBUF
; serves every DPH.  The DPB is NOT shared.  It used to point at the A: backend's
; DPB, which was correct only while A: was the VDrip proxy volume, because that
; volume and this card have the same 8 MiB geometry.  A: is now a 144 KiB ROM
; disk by default, so B: carries its own DPB or it would be described by the
; wrong geometry entirely.
;
; CSV is empty because CKS is zero -- a fixed disk that CP/M never re-verifies.
; ---------------------------------------------------------------------------
	.area CODE (ABS)
	.org SD_STORAGE_DPH
SD_STORAGE_DPH_DATA:
	.dw 0x0000			; XLT: no skew table
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw CBIOS_STORAGE_DIRBUF	; shared with A:
	.dw SD_STORAGE_DPB		; private: 8 MiB card geometry
	.dw 0x0000			; CSV: CKS = 0
	.dw SD_STORAGE_ALV_BUFFER

; CP/M Drive Parameter Block for the SD volume:
;   SPT=4, BSH=5, BLM=31, EXM=1, DSM=2047, DRM=511, AL0=F0h, AL1=00h,
;   CKS=0, OFF=0.  Occupies the last 16 bytes of the DPH/DPB window.
	.area CODE (ABS)
	.org SD_STORAGE_DPB
SD_STORAGE_DPB_DATA:
	.dw SD_STORAGE_SECTORS_PER_TRACK
	.db SD_STORAGE_BLOCK_SHIFT
	.db SD_STORAGE_BLOCK_MASK
	.db SD_STORAGE_EXTENT_MASK
	.dw SD_STORAGE_MAX_BLOCK
	.dw SD_STORAGE_DIR_ENTRIES
	.db SD_STORAGE_ALLOC0
	.db SD_STORAGE_ALLOC1
	.dw SD_STORAGE_CHECK_SIZE
	.dw SD_STORAGE_OFFSET_TRACKS

; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; SD selection probe.
;
; One linear routine.  It used to be four fragments -- request at F41Bh,
; recovery at DFEDh in the core BIOS tail, success at F909h and the result store
; at FA74h -- wedged into whatever gaps existed when each piece was written, and
; stitched together with jp instructions.  Nothing about the behaviour required
; that; only the absence of 41 contiguous bytes did.  Slot 5 has them now.
;
; The behaviour is unchanged and deliberately so: this is normal failure
; handling.  A failed transport or MCU status returns a zero DPH, BDOS applies
; its usual disk-error policy, and the machine warm-boots to A: instead of
; looping on a drive that will never answer.
;
; stg_run saved the caller's HL at storage_caller_sp; the paths below select the
; DPH value its return shim will restore.
;
; Inputs: none.  Output: the protected SELDSK caller receives the B: DPH in HL
; on success, or HL = 0 on failure.  Clobbers AF/BC/DE/HL.  May block for card
; initialization and IOCALL; emits IOC Command traffic, no Virtual Drip traffic.
; Foreground only: uses MOVE_BUFFER and is not ISR-safe.
; ---------------------------------------------------------------------------
	.area CODE (ABS)
	.org CBIOS_SD_PROBE_CODE_BASE

SD_PROBE_CODE_START:
sd_storage_probe:
	call sd_zero_frames
	ld a,#SD_CMD_PROBE
	ld (MOVE_BUFFER + SD_STORAGE_TX_OFF),a
	ld hl,#(MOVE_BUFFER + SD_STORAGE_TX_OFF)
	ld de,#(MOVE_BUFFER + SD_STORAGE_RX_OFF)
	call IOCALL
	; A = transport status; fall through rather than jumping to a fragment.
sd_probe_result:
	or a
	jr nz,sd_probe_failed
	ld a,(MOVE_BUFFER + SD_STORAGE_RX_OFF + IOC_OFF_STATUS)
	or a
	jr nz,sd_probe_failed
	ld de,#SD_STORAGE_DPH
	jr sd_probe_store_result
sd_probe_failed:
	ld de,#0x0000			; no DPH: drive unavailable
; In: DE = DPH to return, or zero for an unavailable drive.
; Out: saved SELDSK HL replaced with DE.  Clobbers HL; foreground only.
sd_probe_store_result:
	ld hl,(storage_caller_sp)
	ld (hl),e
	inc hl
	ld (hl),d
	ret
SD_PROBE_CODE_END:
