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
	.globl sd_storage_setsec,sd_storage_sectran
	.globl sd_flush_thunk
	.include "romsvc_abi.inc"
	.globl ROM_GATE
	.globl stg_home,stg_seldsk,stg_settrk,stg_setsec
	.globl stg_read,stg_write,stg_sectran
	.globl stg_a_home,stg_a_seldsk,stg_a_seldsk_unsupported
	.globl stg_a_settrk,stg_a_setsec
	.globl stg_a_read,stg_a_write,stg_a_sectran
	.globl storage_caller_sp
	.globl SD_STORAGE_CODE_START,SD_STORAGE_CODE_END
	.globl SD_PROBE2_CODE_END
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
; ROM-service thunks.
;
; The SD transaction layer moved to ROM page 4.  These four stand in its place
; in the dispatcher, and they exist to keep the two operations a ROM service
; cannot perform on this side of the gate: touching the bank latch, and reading
; the caller's DMA buffer.
;
; sd_copy_to_dma and sd_copy_from_dma do both -- they select the caller's DMA
; bank and stage a 128-byte record through MOVE_BUFFER.  Writing the latch
; inside a service would unmap the ROM the service is running from, so the
; staging brackets the gate instead of living inside it.
; ---------------------------------------------------------------------------
sd_read_thunk:
	ld a,#ROMSVC_SD_READ
	call ROM_GATE
	or a
	ret nz
	call sd_copy_to_dma
	; A must be zero here.  sd_copy_to_dma tail-calls sd_select_bank, which
	; returns the BANK NUMBER in A, so falling out through it reports a
	; nonzero status and BDOS calls a good sector bad.  The original
	; sd_storage_read ended `call sd_copy_to_dma` / `xor a` / `ret` for this
	; reason; splitting the staging out of the service moved the copy to the
	; end, and the `xor a` has to move with it.
	xor a
	ret

sd_write_thunk:
	; Stage first: the service cannot read the caller's buffer once ROM is
	; mapped over it.
	call sd_copy_from_dma
	ld a,#ROMSVC_SD_WRITE
	jp ROM_GATE

sd_flush_thunk:
	ld a,#ROMSVC_SD_FLUSH
	jp ROM_GATE

sd_probe_thunk:
	ld a,#ROMSVC_SD_PROBE
	jp ROM_GATE

sd_probe2_thunk:
	ld a,#ROMSVC_SD_PROBE2
	jp ROM_GATE


; ---------------------------------------------------------------------------
; record = track * 4 + sector
;
; Output: A = BIOS_OK and sd_storage_record set, or BIOS_ERR.
; The bounds check is not decoration: a wrapped record is a write to the wrong
; sector, which is the one failure that destroys data while reporting success.
; ---------------------------------------------------------------------------

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
	ld hl,#sd_read_thunk
	jr z,stg_run
	ld hl,#stg_a_read
	jr stg_run

stg_write:
	push bc
	push de
	push hl
	call stg_is_sd
	ld hl,#sd_write_thunk
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
; C: -- the second SD volume.
;
; Same geometry as B:, so it shares SD_STORAGE_DPB, and the same shared DIRBUF
; every DPH uses.  CSV is empty because CKS is zero.  The allocation vector is
; the only thing CP/M will not let two drives share, and it is why a third drive
; costs 272 bytes rather than 16.
; ---------------------------------------------------------------------------
	.area CODE (ABS)
	.org SD_STORAGE_DPH2
SD_STORAGE_DPH2_DATA:
	.dw 0x0000			; XLT: no skew table
	.dw 0x0000
	.dw 0x0000
	.dw 0x0000
	.dw CBIOS_STORAGE_DIRBUF	; shared with A: and B:
	.dw SD_STORAGE_DPB		; shared with B:: identical 8 MiB geometry
	.dw 0x0000			; CSV: CKS = 0
	.dw SD_STORAGE_ALV2_BUFFER

; C:'s allocation vector, RESERVED not merely addressed.
;
; Without this .blkb the 256 bytes are invisible to the layout tools: the
; headroom table in docs/memory-map.md listed F980h-FA7Fh as free slot-5 space
; while C:'s DPH was already pointing at it.  The next component placed there
; would have been handed CP/M's live allocation bitmap to overwrite -- and
; nothing would have reported it, because check_overlap.py only sees bytes that
; are emitted or reserved.
	.area WORK (ABS)
	.org SD_STORAGE_ALV2_BUFFER
SD_STORAGE_ALV2:
	.ds SD_STORAGE_ALV2_SIZE

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
; The B: and C: select probes moved to ROM page 4; the probe region now carries
; the drive dispatcher, which cannot move -- stg_sel_a routes A: to the ROM-disk
; backend, and that backend drives the bank latch to read ROM pages 1-3.
	.area CODE (ABS)
	.org CBIOS_SD_PROBE2_CODE_BASE
SD_PROBE_CODE_START:

stg_seldsk:
	ld a,c
	cp #STORAGE_A_DRIVE
	jp z,stg_sel_a
	; Every other supported drive is an SD volume, and the unit it addresses
	; is the drive letter minus one: B: -> 0, C: -> 1.  Deriving it rather
	; than tabulating it means a future D: costs a DPH and an allocation
	; vector, and nothing here.
	cp #SD_STORAGE_DRIVE
	jr c,stg_sel_bad
	cp #SD_STORAGE_DRIVE_LIMIT
	jr nc,stg_sel_bad
	ld (stg_drive),a
	dec a
	ld (sd_storage_unit),a
	push bc
	push de
	push hl
	or a				; unit 0 is B:
	jr z,stg_sel_unit0
	ld hl,#sd_probe2_thunk
	jp stg_run
stg_sel_unit0:
	ld hl,#sd_probe_thunk
	jp stg_run
stg_sel_bad:
	ld a,#0xff
	ld (stg_drive),a
	jp stg_a_seldsk_unsupported
stg_sel_a:
	ld a,#STORAGE_A_DRIVE
	ld (stg_drive),a
	jp stg_a_seldsk

; Z set when the SD backend is the live one -- for ANY of its drives.
;
; This used to compare against SD_STORAGE_DRIVE alone, which was the same thing
; while B: was the only SD volume.  With C: it is not: the routines that gate on
; it would have routed C:'s reads to the A: backend.
stg_is_sd:
	ld a,(stg_drive)
	cp #SD_STORAGE_DRIVE
	jr c,stg_not_sd			; below B: -- A:, or nothing selected
	cp #SD_STORAGE_DRIVE_LIMIT
	jr nc,stg_not_sd		; above the last SD drive, incl. the FFh park
	xor a				; Z set: an SD drive is live
	ret
stg_not_sd:
	; A: is drive 0, so `or a` would set Z here and route A: to the SD
	; backend.  The flag is set from a constant instead.
	ld a,#0xff
	or a				; NZ
	ret

; Card-level probe, shared by B: and C:.  Out: Z when the card answered.
SD_PROBE2_CODE_END:
SD_PROBE_CODE_END:

