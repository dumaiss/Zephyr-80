; FAT-backed read-only BDOS personality -- fixed bank-7 code and state.
;
; ZSDOS owns D: through a synthetic DPH while the dispatcher implements file
; operations through the controller FS2 service.  The BIOS-level disk remains
; deliberately empty: READ returns E5h-filled records and WRITE fails.

	.globl FAT_BDOS_CODE_START,FAT_BDOS_CODE_END
	.globl FAT_BDOS_STATE_START,FAT_BDOS_STATE_END
	.globl FAT_BIOS_DPH,FAT_BIOS_DPB,FAT_BIOS_ALV
	.globl fat_bios_home,fat_bios_seldsk
	.globl fat_bios_settrk,fat_bios_setsec
	.globl fat_bios_read,fat_bios_write,fat_bios_sectran
	.globl fat_bdos_dispatch,fat_bdos_post,fat_bdos_or_zsdos,fat_native_entry
	.globl fat_current_drive,fat_current_user,fat_context_reset
	.globl cbios_dma_addr,fac_eff_dma

	.area CODE (ABS)
	.org CBIOS_FAT_BDOS_CODE_BASE

FAT_BDOS_CODE_START:

; HOME
; Purpose: select synthetic track zero.
; Outputs: fat_bios_track = 0000h.
; Clobbers: HL.  Does not block or emit IOC traffic.  Not ISR-safe.
fat_bios_home:
	ld hl,#0x0000
	ld (fat_bios_track),hl
	ret

; SELDSK backend for configured FAT drive D:.
; Output: HL = shared synthetic FAT DPH.
; Clobbers: HL.  Does not block or emit IOC traffic.  Not ISR-safe.
fat_bios_seldsk:
	; Drive availability belongs to /CPM/D itself.  A saved native CWD is
	; relative to a USER namespace and must not make the synthetic drive
	; disappear when ZSDOS logs it in or changes USER.
	call fat_fs2_base
	jr nz,fat_bios_seldsk_unavailable
	ld hl,#FAT_BIOS_DPH
	ret
fat_bios_seldsk_unavailable:
	ld hl,#0x0000
	ret

; SETTRK backend.
; Input: BC = CP/M track.
; Output: fat_bios_track updated.
; Clobbers: none.  Not ISR-safe.
fat_bios_settrk:
	ld (fat_bios_track),bc
	ret

; SETSEC backend.
; Input: BC = zero-based sector within the synthetic track.
; Output: fat_bios_sector updated.
; Clobbers: none.  Not ISR-safe.
fat_bios_setsec:
	ld (fat_bios_sector),bc
	ret

; SECTRAN backend.
; Input: BC = logical sector.
; Output: HL = BC; the synthetic geometry has no skew table.
; Clobbers: HL only.  ISR-safe, nonblocking, no IOC traffic.
fat_bios_sectran:
	ld h,b
	ld l,c
	ret

; READ backend.
; Purpose:
;   Present an empty CP/M disk to ZSDOS.  Every valid 128-byte record reads as
;   E5h, so login and directory scans find no allocated directory entries.
; Inputs:
;   fat_bios_track/fat_bios_sector select a record; cbios_dma_addr is the
;   destination as visible in mode 11.
; Outputs:
;   A = BIOS_OK, or BIOS_ERR for a track/sector outside the synthetic geometry.
; Clobbers: AF, BC, DE, HL.  Does not block or emit IOC traffic.  Not ISR-safe.
fat_bios_read:
	ld hl,(fat_bios_track)
	ld a,h
	cp #0x40			; 16384 tracks in the 8 MiB geometry
	jr nc,fat_bios_read_error
	ld hl,(fat_bios_sector)
	ld a,h
	or a
	jr nz,fat_bios_read_error
	ld a,l
	cp #SD_STORAGE_SECTORS_PER_TRACK
	jr nc,fat_bios_read_error

	ld hl,(cbios_dma_addr)
	ld (hl),#FAT_BIOS_EMPTY_BYTE
	ld d,h
	ld e,l
	inc de
	ld bc,#(FAT_BIOS_RECORD_BYTES - 1)
	ldir
	xor a
	ret
fat_bios_read_error:
	ld a,#BIOS_ERR
	ret

; WRITE backend.
; Purpose: make the synthetic BIOS disk permanently read-only.
; Output: A = BIOS_ERR, always.
; Clobbers: AF.  Does not block or emit IOC traffic.  ISR-safe.
fat_bios_write:
	ld a,#BIOS_ERR
	ret

; Shared synthetic DPH/DPB for FAT-backed drives.  The scratch words at the
; start of the DPH are writable because bank 7 is SRAM even though the initial
; image is emitted from this CODE area.  Its geometry matches the existing
; 8 MiB SD volumes and describes only the CP/M compatibility fiction.
FAT_BIOS_DPH:
	.dw 0x0000			; XLT: no skew table
	.dw 0x0000			; BDOS scratch
	.dw 0x0000			; BDOS scratch
	.dw 0x0000			; BDOS scratch
	.dw CBIOS_STORAGE_DIRBUF	; shared BIOS directory buffer
	.dw FAT_BIOS_DPB
	.dw 0x0000			; CSV: CKS = 0
	.dw FAT_BIOS_ALV

FAT_BIOS_DPB:
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
; FS2 command helpers
; ---------------------------------------------------------------------------

FAT_TX = MOVE_BUFFER
FAT_RX = MOVE_BUFFER + 0x20

fat_zero_frames:
	ld hl,#FAT_TX
	ld b,#0x40
	xor a
fat_zero_loop:
	ld (hl),a
	inc hl
	djnz fat_zero_loop
	ret

; A = expected response class.  Returns A = FS2/transport status, Z on OK.
fat_exchange:
	ld (fat_expected),a
	ld hl,#FAT_TX
	ld de,#FAT_RX
	call IOCALL
	or a
	jr z,fat_exchange_frame
	ld a,#FS2_STATUS_TRANSPORT
	jr fat_exchange_done
fat_exchange_frame:
	ld a,(FAT_RX)
	ld hl,#fat_expected
	cp (hl)
	jr z,fat_exchange_status
	ld a,#FS2_STATUS_TRANSPORT
	jr fat_exchange_done
fat_exchange_status:
	ld a,(FAT_RX + IOC_OFF_STATUS)
fat_exchange_done:
	ld (fat_last_status),a
	or a
	ret

; HL = packed 8.3 component.
fat_fs2_push:
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_PUSH
	ld (FAT_TX),a
	ld a,#FS2_NAME_BYTES
	ld (FAT_TX + IOC_OFF_LEN),a
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD)
	ld bc,#FS2_NAME_BYTES
	ldir
	ld a,#FS2_RSP_PUSH
	jp fat_exchange

; Reset the IOC resolver and replay /CPM/D, the current @N USER directory when
; requested, and then the bank-7 current directory.  Keeping USER ahead of the
; relative CWD makes a directory visible in D8: selectable by ZCD from D8:.
fat_fs2_path:
	ld (fat_path_user),a
	call fat_fs2_base
	ret nz
	ld a,(fat_path_user)
	or a
	jr z,fat_fs2_path_cwd
	ld a,(fat_current_user)
	call fat_fs2_push_user
	ret nz
fat_fs2_path_cwd:
	call fat_effective_cwd_count
	or a
	ret z
	ld b,a
	ld hl,#fat_cwd_components
	jp fat_fs2_push_components

; Return the saved relative CWD count only for the USER that owns it.
; A different USER sees its own namespace root.
fat_effective_cwd_count:
	ld a,(fat_cwd_user)
	ld c,a
	ld a,(fat_current_user)
	cp c
	jr nz,fat_effective_cwd_none
	ld a,(fat_cwd_count)
	ret
fat_effective_cwd_none:
	xor a
	ret

fat_fs2_base:
	call fat_zero_frames
	ld a,#FS2_CMD_ROOT
	ld (FAT_TX),a
	ld a,#FS2_RSP_ROOT
	call fat_exchange
	ret nz
	ld hl,#fat_component_cpm
	call fat_fs2_push
	ret nz
	ld hl,#fat_component_d
	call fat_fs2_push
	ret

; HL=packed component array, B=count.
fat_fs2_push_components:
fat_fs2_cwd_loop:
	push bc
	push hl
	call fat_fs2_push
	pop hl
	pop bc
	ret nz
	ld de,#FS2_NAME_BYTES
	add hl,de
	djnz fat_fs2_cwd_loop
	xor a
	ret
; A=USER 0..15.  USER 0 is the drive directory itself; higher USERs are
; represented by strict 8.3 @N components.
fat_fs2_push_user:
	or a
	ret z
	cp #16
	jr nc,fat_fs2_bad_user
	call fat_make_user_component_a
	ld hl,#fat_user_component
	jp fat_fs2_push
fat_fs2_bad_user:
	ld a,#FS2_STATUS_NOT_FOUND
	ld (fat_last_status),a
	or a
	ret

fat_make_user_component:
	ld a,(fat_current_user)
fat_make_user_component_a:
	ld hl,#fat_user_component
	ld (hl),#'@'
	inc hl
	ld b,#9				; spaces after a one-digit USER
	cp #10
	jr c,fat_user_one_digit
	dec b				; two digits consume one more byte
	ld (hl),#'1'
	inc hl
	sub #10
fat_user_one_digit:
	add a,#'0'
	ld (hl),a
	inc hl
fat_user_pad:
	ld (hl),#' '
	inc hl
	djnz fat_user_pad
	ret

; HL = packed filename.  Path resolver must already be prepared.
; On success records token, size and attributes in persistent scratch.
fat_fs2_open:
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_OPEN_RO
	ld (FAT_TX),a
	ld a,#FS2_NAME_BYTES
	ld (FAT_TX + IOC_OFF_LEN),a
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD)
	ld bc,#FS2_NAME_BYTES
	ldir
	ld a,#FS2_RSP_OPEN_RO
	call fat_exchange
	ret nz
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD)
	ld (fat_file_token),hl
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	ld (fat_file_size),hl
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 4)
	ld (fat_file_size + 2),hl
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 6)
	ld (fat_file_attr),a
	xor a
	ret

; A = IOC FS2 writable-open mode, HL = packed 8.3 component.
; On success records token, size and attributes in persistent scratch.
fat_fs2_open_rw:
	push af
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_OPEN_RW
	ld (FAT_TX),a
	ld a,#12
	ld (FAT_TX + IOC_OFF_LEN),a
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD + 1)
	ld bc,#FS2_NAME_BYTES
	ldir
	pop af
	ld (FAT_TX + IOC_OFF_PAYLOAD),a
	ld a,#FS2_RSP_OPEN_RW
	call fat_exchange
	ret nz
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD)
	ld (fat_file_token),hl
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	ld (fat_file_size),hl
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 4)
	ld (fat_file_size + 2),hl
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 6)
	ld (fat_file_attr),a
	xor a
	ret

fat_fs2_close:
	call fat_zero_frames
	ld a,#FS2_CMD_CLOSE
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_file_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_CLOSE
	jp fat_exchange

; A = FS2 command, HL = packed 8.3 component.  Serves UNLINK, MKDIR and RMDIR,
; which differ only in the command byte; every FS2 response class is its
; command plus 80h.
fat_fs2_name_op:
	push af
	push hl
	call fat_zero_frames
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD)
	ld bc,#FS2_NAME_BYTES
	ldir
	ld a,#FS2_NAME_BYTES
	ld (FAT_TX + IOC_OFF_LEN),a
	pop af
	ld (FAT_TX),a
	add a,#0x80
	jp fat_exchange

; HL = packed source name, DE = packed destination name.  Both resolve against
; the same current resolver path, so this renames within one directory.
fat_fs2_rename:
	push de
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_RENAME
	ld (FAT_TX),a
	ld a,#(2 * FS2_NAME_BYTES)
	ld (FAT_TX + IOC_OFF_LEN),a
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD)
	ld bc,#FS2_NAME_BYTES
	ldir
	pop hl
	ld de,#(FAT_TX + IOC_OFF_PAYLOAD + FS2_NAME_BYTES)
	ld bc,#FS2_NAME_BYTES
	ldir
	ld a,#FS2_RSP_RENAME
	jp fat_exchange

; DE:HL = byte offset, BC = requested length, IX = destination.
; Returns A=0 and BC=actual bytes, or A=status.
fat_fs2_read:
	push ix
	push bc
	push de
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_READ
	ld (FAT_TX),a
	ld a,#8
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_file_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	pop hl
	pop de
	ld (FAT_TX + IOC_OFF_PAYLOAD + 2),hl
	ld (FAT_TX + IOC_OFF_PAYLOAD + 4),de
	pop bc
	ld (FAT_TX + IOC_OFF_PAYLOAD + 6),bc
	ld a,#FS2_RSP_READ
	call fat_exchange
	jr nz,fat_fs2_read_fail
	ld bc,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	ld a,b
	or c
	jr z,fat_fs2_read_empty
	pop hl				; destination saved as IX
	push hl				; retain saved IX for the matching pop below
	push bc				; preserve actual byte count across IOCBULK
	ld d,b
	ld e,c
	call IOCBULK
	or a
	jr nz,fat_fs2_read_xport
	pop bc				; actual byte count
	pop ix
	xor a
	ret
fat_fs2_read_empty:
	pop ix
	xor a
	ret
fat_fs2_read_xport:
	pop bc				; discard saved byte count
	pop ix
	ld a,#FS2_STATUS_TRANSPORT
	or a
	ret
fat_fs2_read_fail:
	pop ix
	or a
	ret

; DE:HL = explicit byte offset, BC = length already staged in FAC_BULK_BUF.
; Returns A=0 only after a matching DONE record confirms the commit.  Once
; READY has been accepted, any unresolvable transport/result ambiguity returns
; FS2_STATUS_UNKNOWN_WRITE and is never replayed here.
fat_fs2_write:
	xor a
	ld (fat_write_started),a
	ld (fat_write_offset),hl
	ld (fat_write_offset + 2),de
	ld (fat_write_length),bc
	push bc
	push de
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_WRITE
	ld (FAT_TX),a
	ld a,#8
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_file_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	pop hl
	pop de
	ld (FAT_TX + IOC_OFF_PAYLOAD + 2),hl
	ld (FAT_TX + IOC_OFF_PAYLOAD + 4),de
	pop bc
	ld (FAT_TX + IOC_OFF_PAYLOAD + 6),bc
	ld a,#FS2_RSP_WRITE
	call fat_exchange
	ret nz
	ld a,(FAT_RX + IOC_OFF_LEN)
	cp #8
	jr nz,fat_fs2_write_ready_bad
	ld a,(FAT_RX + IOC_OFF_PAYLOAD)
	or a
	jr z,fat_fs2_write_ready_bad
	ld (fat_write_xfer_id),a
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 1)
	cp #1				; BULK_DIR_Z80_TO_MCU
	jr nz,fat_fs2_write_ready_bad
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	ld de,(fat_write_length)
	or a
	sbc hl,de
	jr nz,fat_fs2_write_ready_bad
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 4)
	ld de,(fat_write_offset)
	or a
	sbc hl,de
	jr nz,fat_fs2_write_ready_bad
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 6)
	ld de,(fat_write_offset + 2)
	or a
	sbc hl,de
	jr nz,fat_fs2_write_ready_bad
	ld hl,#FAC_BULK_BUF
	ld de,(fat_write_length)
	ld a,#1
	ld (fat_write_started),a
	call IOCBULKW
	; Even a local bulk error can race a completed commit.  DONE identity and
	; status, not the bulk return alone, decide whether the write is known.
	call fat_fs2_write_done
	ret
fat_fs2_write_ready_bad:
	ld a,#FS2_STATUS_TRANSPORT
	ld (fat_last_status),a
	or a
	ret

fat_fs2_write_done:
	call fat_zero_frames
	ld a,#SD_CMD_XFER_STATUS
	ld (FAT_TX),a
	ld a,#1
	ld (FAT_TX + IOC_OFF_LEN),a
	ld a,#SD_RSP_XFER_STATUS
	call fat_exchange
	jr nz,fat_fs2_write_unknown
	ld a,(FAT_RX + IOC_OFF_LEN)
	cp #2
	jr c,fat_fs2_write_unknown
	ld a,(FAT_RX + IOC_OFF_PAYLOAD)
	ld hl,#fat_write_xfer_id
	cp (hl)
	jr nz,fat_fs2_write_unknown
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 1)
	ld (fat_last_status),a
	or a
	ret
fat_fs2_write_unknown:
	ld a,#FS2_STATUS_UNKNOWN_WRITE
	ld (fat_last_status),a
	or a
	ret

fat_fs2_sync:
	call fat_zero_frames
	ld a,#FS2_CMD_SYNC
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_file_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_SYNC
	jp fat_exchange

; DE:HL = new byte size.
fat_fs2_truncate:
	push de
	push hl
	call fat_zero_frames
	ld a,#FS2_CMD_TRUNCATE
	ld (FAT_TX),a
	ld a,#6
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_file_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	pop hl
	pop de
	ld (FAT_TX + IOC_OFF_PAYLOAD + 2),hl
	ld (FAT_TX + IOC_OFF_PAYLOAD + 4),de
	ld a,#FS2_RSP_TRUNCATE
	jp fat_exchange

; ---------------------------------------------------------------------------
; Read-only FCB compatibility personality
; ---------------------------------------------------------------------------

; Called after ordinary ZSDOS calls that can alter mirrored state.
; C=function, E=argument byte.  ZSDOS remains authoritative.
fat_bdos_post:
	ld a,c
	cp #14
	jr z,fat_post_drive
	cp #32
	jr z,fat_post_user
	cp #29
	jr z,fat_post_ro_result
	cp #28
	jr z,fat_post_reset_ro
	cp #13
	jr z,fat_post_reset_ro
	cp #37
	ret nz
fat_post_reset_ro:
	call fat_context_reset
	jp fat_refresh_ro
fat_post_ro_result:
	ld (fat_ro_vector),hl
	ret
fat_post_drive:
	ld a,e
	ld (fat_current_drive),a
	jp fat_context_reset
fat_post_user:
	call fat_cache_flush
	ld a,e
	cp #0xff
	ret z
	and #0x1f
	ld (fat_current_user),a
	jp fat_search_reset

; Refresh the software read-only vector from authoritative ZSDOS state.
fat_refresh_ro:
	ld c,#29
	call ZSDOS_ENTRY
	ld (fat_ro_vector),hl
	ret

; Returns A=0/Z when the configured FAT drive is writable, otherwise the FS2
; read-only status.  Physical/filesystem protection is reported independently
; by the IOC's FatFs result.
fat_check_write_protect:
	ld hl,(fat_ro_vector)
	bit FAT_BIOS_DRIVE,l
	ret z
	ld a,#FS2_STATUS_READ_ONLY
	or a
	ret

; Bank-7 BDOS entry used by the facade after argument staging.  Keeping the
; selection here avoids a second common-memory dispatcher: FAT calls return
; directly, while every other call reaches unmodified ZSDOS.  Post-call mirror
; maintenance preserves all of ZSDOS's result registers and flags.
fat_bdos_or_zsdos:
	ld (fat_post_fn),bc
	ld (fat_post_de),de
	ld a,c
	cp #27
	call z,fat_refresh_alv
	ld hl,(fac_eff_dma)
	call fat_bdos_dispatch
	ret c
	ld bc,(fat_post_fn)
	ld de,(fat_post_de)
	call ZSDOS_ENTRY
	push af
	push bc
	push de
	push hl
	ld bc,(fat_post_fn)
	ld de,(fat_post_de)
	call fat_bdos_post
	pop hl
	pop de
	pop bc
	pop af
	ret

fat_context_reset:
	call fat_cache_flush
	call fat_search_reset
	ld a,(fat_native_active)
	or a
	jr z,fat_context_slot1
	ld hl,(fat_native_tokens)
	ld (fat_file_token),hl
	call fat_fs2_close
fat_context_slot1:
	ld a,(fat_native_active + 1)
	or a
	jr z,fat_context_dir
	ld hl,(fat_native_tokens + 2)
	ld (fat_file_token),hl
	call fat_fs2_close
fat_context_dir:
	ld a,(fat_native_dir_active)
	or a
	jr z,fat_context_clear
	call fat_zero_frames
	ld a,#FS2_CMD_CLOSEDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_native_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_CLOSEDIR
	call fat_exchange
fat_context_clear:
	xor a
	ld (fat_file_token),a
	ld (fat_file_token + 1),a
	ld (fat_native_active),a
	ld (fat_native_active + 1),a
	ld (fat_native_modes),a
	ld (fat_native_modes + 1),a
	ld (fat_native_dir_active),a
	ret

; C=function, DE=staged FCB, HL=effective staged DMA.
; Carry set means handled and A contains the BDOS result.
fat_bdos_dispatch:
	ld a,c
	cp #18
	jr z,fat_dispatch_search_next
	cp #15
	jr c,fat_dispatch_not_handled
	cp #24
	jr c,fat_dispatch_fcb
	cp #30
	jr z,fat_dispatch_fcb
	cp #33
	jr c,fat_dispatch_not_handled
	cp #36
	jr c,fat_dispatch_fcb
	cp #40
	jr z,fat_dispatch_fcb
	cp #102
	jr z,fat_dispatch_fcb
	cp #103
	jr nz,fat_dispatch_not_handled
fat_dispatch_fcb:
	push hl
	push de
	call fat_effective_drive
	pop de
	pop hl
	jr nz,fat_dispatch_not_handled
	ld a,c
	cp #15
	jp z,fat_bdos_open
	cp #16
	jp z,fat_bdos_close
	cp #17
	jp z,fat_bdos_search_first
	cp #19
	jp z,fat_bdos_delete
	cp #20
	jp z,fat_bdos_read_seq
	cp #21
	jp z,fat_bdos_write_seq
	cp #22
	jp z,fat_bdos_make
	cp #23
	jp z,fat_bdos_rename
	; Function 30 stays refused.  FAT attribute projection was removed
	; deliberately -- the semantics do not line up and it corrupted 8.3 names
	; -- so there is nothing here for SET ATTRIBUTES to set, and claiming
	; success would be a lie the caller cannot detect.
	cp #30
	jr z,fat_bdos_readonly
	cp #33
	jp z,fat_bdos_read_random
	cp #34
	jp z,fat_bdos_write_random
	cp #35
	jp z,fat_bdos_file_size
	cp #40
	jp z,fat_bdos_write_random_zf
	cp #102
	jr z,fat_bdos_readonly
	cp #103
	jr z,fat_bdos_readonly
fat_dispatch_not_handled:
	or a
	ret				; carry clear
fat_dispatch_search_next:
	ld a,(fat_search_active)
	or a
	jr z,fat_dispatch_not_handled
	jp fat_bdos_search_next
fat_bdos_readonly:
	ld a,#0xff
	scf
	ret

; Refresh the synthetic allocation vector from FS2 free bytes.  ZSDOS remains
; the consumer of the DPH/ALV; this only makes its capacity-reporting fiction
; reflect the FAT volume instead of always reporting the virtual maximum.
fat_refresh_alv:
	ld a,(fat_current_drive)
	cp #FAT_BIOS_DRIVE
	ret nz
	call fat_zero_frames
	ld a,#FS2_CMD_SPACE
	ld (FAT_TX),a
	ld a,#FS2_RSP_SPACE
	call fat_exchange
	ret nz
	; free 4 KiB blocks = free bytes >> 12, clamped to 2045 so the three
	; directory-reserved virtual blocks remain allocated.
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 3)
	or a
	jr nz,fat_alv_clamp
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	and #0xf0
	jr nz,fat_alv_clamp
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 1)
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	ld l,a
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 2)
	and #0x0f
	rrca
	rrca
	rrca
	rrca
	or l
	ld h,a
	ld a,l
	cp #0xfd
	ld a,h
	sbc a,#0x07
	jr c,fat_alv_have_free
fat_alv_clamp:
	ld hl,#2045
fat_alv_have_free:
	ld de,#2048
	ex de,hl
	or a
	sbc hl,de			; allocated virtual blocks
	ld (fat_alv_allocated),hl
	ld hl,#FAT_BIOS_ALV
	ld (hl),#0x00
	ld d,h
	ld e,l
	inc de
	ld bc,#255
	ldir
	ld hl,(fat_alv_allocated)
	ld a,l
	and #7
	ld (fat_alv_remainder),a
	ld b,#3
fat_alv_div8:
	srl h
	rr l
	djnz fat_alv_div8
	ld b,l
	ld hl,#FAT_BIOS_ALV
	ld a,h
	or a
	jr nz,fat_alv_full_loop	; B=0 deliberately iterates 256 bytes
	ld a,b
	or a
	jr z,fat_alv_partial
fat_alv_full_loop:
	ld (hl),#0xff
	inc hl
	djnz fat_alv_full_loop
fat_alv_partial:
	ld a,(fat_alv_remainder)
	or a
	ret z
	ld b,a
	ld a,#0x80
fat_alv_mask_loop:
	djnz fat_alv_mask_more
	ld (hl),a
	ret
fat_alv_mask_more:
	srl a
	or #0x80
	jr fat_alv_mask_loop

; DE=FCB.  Z when it resolves to D:.
fat_effective_drive:
	ld a,(de)
	or a
	jr nz,fat_effective_explicit
	ld a,(fat_current_drive)
	cp #FAT_BIOS_DRIVE
	ret
fat_effective_explicit:
	cp #'?'				; CP/M raw-directory SEARCH FIRST
	jr nz,fat_effective_numbered
	ld a,c
	cp #17
	ret nz
	ld a,(fat_current_drive)
	cp #FAT_BIOS_DRIVE
	ret
fat_effective_numbered:
	dec a
	cp #FAT_BIOS_DRIVE
	ret

; Build resolver including USER, then open the FCB name.  DE is preserved.
fat_open_fcb:
	push de
	ld a,#1
	call fat_fs2_path
	pop de
	ret nz
	push de
	inc de
	ex de,hl
	call fat_fs2_open
	pop de
	ret

; A = FS2 writable-open mode, DE = FCB.  The write-side twin of fat_open_fcb.
; DE is preserved.
fat_open_fcb_mode:
	ld (fat_open_mode_save),a
	push de
	ld a,#1
	call fat_fs2_path
	pop de
	ret nz
	push de
	inc de
	ex de,hl
	ld a,(fat_open_mode_save)
	call fat_fs2_open_rw
	pop de
	ret

; A missing @N directory is how an empty USER area is represented, so the
; first file created in one has to materialise it.  USER 0 maps to the real
; directory and needs nothing; an @N that already exists is success.
fat_ensure_user_dir:
	ld a,(fat_current_user)
	or a
	ret z
	call fat_fs2_base
	ret nz
	call fat_make_user_component
	ld hl,#fat_user_component
	ld a,#FS2_CMD_MKDIR
	call fat_fs2_name_op
	ret z
	cp #FS2_STATUS_EXISTS
	ret nz
	xor a
	ret

fat_bdos_open:
	ld (fat_work_fcb),de
	call fat_open_fcb
	jr nz,fat_bdos_fail
	call fat_fs2_close
	jr nz,fat_bdos_fail
	ld de,(fat_work_fcb)
	call fat_fcb_stamp_user
	; Match OPEN's observable FCB contract.  RC describes the requested logical
	; extent and is capped at 128 records; allocation bytes stay synthetic zero.
	ld hl,(fat_file_size)
	ld a,(fat_file_size + 2)
	ld b,a
	ld a,(fat_file_size + 3)
	or b
	jr nz,fat_open_rc_full
	ld a,h
	cp #0x40			; 16 KiB = 128 records
	jr nc,fat_open_rc_full
	ld bc,#127
	add hl,bc
	ld b,#7
fat_open_rc_shift:
	srl h
	rr l
	djnz fat_open_rc_shift
	ld a,l
	jr fat_open_rc_store
fat_open_rc_full:
	ld a,#128
fat_open_rc_store:
	ld hl,#15
	add hl,de
	ld (hl),a
	xor a
	scf
	ret
fat_bdos_close:
	xor a
	scf
	ret
fat_bdos_fail:
	ld a,#0xff
	scf
	ret

; Convert FCB sequential position to 24-bit logical record in fat_record.
fat_seq_record:
	push de
	ld hl,#12
	add hl,de
	ld a,(hl)			; EX
	and #0x1f
	ld c,a
	rrca				; EX bit 0 becomes record bit 7
	and #0x80
	ld (fat_record),a
	ld a,c
	srl a				; EX bits 1..4 become record bits 8..11
	ld (fat_record + 1),a
	inc hl
	inc hl				; S2
	ld a,(hl)
	and #0x3f
	ld c,a
	add a,a				; S2 bits 0..3 become record bits 12..15
	add a,a
	add a,a
	add a,a
	ld hl,#fat_record + 1
	or (hl)
	ld (hl),a
	inc hl
	ld a,c				; S2 bits 4..5 become record bits 16..17
	srl a
	srl a
	srl a
	srl a
	ld (hl),a
	pop de
	push de
	ld hl,#32
	add hl,de			; CR
	ld a,(hl)
	ld hl,#fat_record
	add a,(hl)
	ld (hl),a
	jr nc,fat_seq_record_done
	inc hl
	inc (hl)
	jr nz,fat_seq_record_done
	inc hl
	inc (hl)
fat_seq_record_done:
	pop de
	ret

; fat_record (24-bit records) -> DE:HL byte offset.
fat_record_offset:
	ld a,(fat_record)
	ld l,a
	ld a,(fat_record + 1)
	ld h,a
	ld a,(fat_record + 2)
	ld e,a
	ld d,#0
	ld b,#7
fat_offset_shift:
	add hl,hl
	rl e
	rl d
	djnz fat_offset_shift
	ret

fat_increment_seq:
	push de
	ld hl,#32
	add hl,de
	inc (hl)
	ld a,(hl)
	cp #128
	jr c,fat_increment_done
	ld (hl),#0
	ld hl,#12
	add hl,de
	inc (hl)
	ld a,(hl)
	and #0x1f
	jr nz,fat_increment_done
	inc hl
	inc hl
	inc (hl)
fat_increment_done:
	pop de
	ret

; ---------------------------------------------------------------------------
; Reclaimable pool allocator, and the FAT read cache that is its first client.
;
; A CP/M record is 128 bytes but the controller reads 512 at a time for the
; same round trip, and the round trip is what costs: serving one record used
; to mean RESET/ROOT/PUSH/OPEN/READ/BULK/CLOSE.  Holding the 512-byte line
; that contains it serves the next three records from memory.
;
; The pool's contract is that a lease can be refused, so every path here has
; to work without one.  A refusal just means reads stay slow.
; ---------------------------------------------------------------------------

RES_OWNER_FAT_READ = 1

; A = owner id.  Out: Z with HL = line base, or NZ when the pool is full.
res_lease:
	ld c,a
	ld b,#RESOURCE_CACHE_LINE_COUNT
	ld hl,#res_owners
res_lease_scan:
	ld a,(hl)
	or a
	jr z,res_lease_take
	inc hl
	djnz res_lease_scan
	ld a,#0xff
	or a
	ret
res_lease_take:
	ld (hl),c
	ld a,#RESOURCE_CACHE_LINE_COUNT
	sub b				; index of the line just taken
	ld h,a
	ld l,#0				; index * 256
	add hl,hl			; index * 512
	ld de,#RESOURCE_CACHE_POOL_BASE
	add hl,de
	xor a
	ret

; Any change that could make the held line stale.  Cheap enough that every
; mutation path calls it rather than reasoning about which file it hit.
fat_cache_invalidate:
	push af
	xor a
	ld (fat_cache_valid),a
	pop af
	ret

; Close the cached read handle if one is held.  Clears the tag first, so a
; close that fails still leaves us believing we hold nothing -- the controller
; slot is the scarce thing and a half-owned one is worse than none.
fat_hcache_close:
	ld a,(fat_hcache_valid)
	or a
	ret z
	xor a
	ld (fat_hcache_valid),a
	ld hl,(fat_hcache_token)
	ld (fat_file_token),hl
	jp fat_fs2_close

; Drop both caches.  The line is only memory, but the handle is one of the
; controller's two file slots and has to be given back or the next opener
; finds the pool full.  Called from every mutation point, so it must leave
; the caller's registers alone.
fat_cache_flush:
	push af
	push bc
	push de
	push hl
	call fat_cache_invalidate
	call fat_hcache_close
	pop hl
	pop de
	pop bc
	pop af
	ret

; DE = FCB.  Leaves an open read handle in fat_file_token, reusing the one
; from the previous record whenever it names the same file for the same USER.
; That reuse is the point: the resolver walk and the OPEN were being paid on
; every line, and neither changes between records of one file.
fat_hcache_open:
	ld (fat_work_fcb),de
	ld a,(fat_hcache_valid)
	or a
	jr z,fat_hcache_fresh
	ld hl,#fat_hcache_user
	ld a,(fat_current_user)
	cp (hl)
	jr nz,fat_hcache_fresh
	ld hl,#fat_hcache_name
	ld de,(fat_work_fcb)
	inc de
	ld b,#11
	call fat_cache_cmp
	jr nz,fat_hcache_fresh
	ld hl,(fat_hcache_token)
	ld (fat_file_token),hl
	xor a
	ret
fat_hcache_fresh:
	call fat_hcache_close
	ld de,(fat_work_fcb)
	call fat_open_fcb
	ret nz
	ld hl,(fat_file_token)
	ld (fat_hcache_token),hl
	ld hl,(fat_work_fcb)
	inc hl
	ld de,#fat_hcache_name
	ld bc,#11
	ldir
	ld a,(fat_current_user)
	ld (fat_hcache_user),a
	ld a,#1
	ld (fat_hcache_valid),a
	xor a
	ret

; Ask the pool once.  A refusal is permanent for the session; asking again on
; every record would cost more than the cache saves.
fat_cache_lease:
	ld hl,(fat_cache_line)
	ld a,h
	or l
	jr z,fat_cache_lease_try
	xor a
	ret
fat_cache_lease_try:
	ld a,(fat_cache_tried)
	or a
	jr z,fat_cache_lease_ask
	ld a,#1
	or a
	ret
fat_cache_lease_ask:
	ld a,#1
	ld (fat_cache_tried),a
	ld a,#RES_OWNER_FAT_READ
	call res_lease
	ret nz
	ld (fat_cache_line),hl
	xor a
	ret

; Four 128-byte records share one 512-byte line, so the line is simply the
; record with its low two bits cleared and the offset within it is those two
; bits times 128.  No 32-bit masking needed.
fat_cache_locate:
	ld a,(fat_record)
	and #3
	ld h,a
	ld l,#0				; (record & 3) * 256
	srl h
	rr l				; ... / 2 = * 128
	ld (fat_cache_within),hl
	ld a,(fat_record)
	and #0xfc
	ld (fat_line_rec),a
	ld a,(fat_record + 1)
	ld (fat_line_rec + 1),a
	ld a,(fat_record + 2)
	ld (fat_line_rec + 2),a
	ret

; HL, DE = blocks, B = count.  Z when equal.
fat_cache_cmp:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz fat_cache_cmp
	xor a
	ret

; Z when the held line already covers this record, for this file and USER.
fat_cache_hit:
	ld a,(fat_cache_valid)
	or a
	jr z,fat_cache_miss
	ld hl,#fat_cache_user
	ld a,(fat_current_user)
	cp (hl)
	jr nz,fat_cache_miss
	ld hl,#fat_cache_rec
	ld de,#fat_line_rec
	ld b,#3
	call fat_cache_cmp
	jr nz,fat_cache_miss
	ld hl,#fat_cache_name
	ld de,(fat_work_fcb)
	inc de
	ld b,#11
	call fat_cache_cmp
	jr nz,fat_cache_miss
	xor a
	ret
fat_cache_miss:
	ld a,#1
	or a
	ret

; Read the 512 bytes containing this record into the held line.  Z on success.
; NZ means no line or a failed read, and the caller falls back to the
; single-record path -- slower, but it is the one that was already proven.
fat_cache_fill:
	call fat_cache_lease
	ret nz
	call fat_cache_invalidate
	xor a
	ld (fat_hcache_retry),a
fat_cache_fill_attempt:
	ld de,(fat_work_fcb)
	call fat_hcache_open
	ret nz
	ld hl,#fat_record
	ld de,#fat_cache_saverec
	ld bc,#3
	ldir
	ld hl,#fat_line_rec
	ld de,#fat_record
	ld bc,#3
	ldir
	call fat_record_offset
	push de
	push hl
	ld hl,#fat_cache_saverec
	ld de,#fat_record
	ld bc,#3
	ldir
	pop hl
	pop de
	ld bc,#RESOURCE_CACHE_LINE_SIZE
	ld ix,(fat_cache_line)
	call fat_fs2_read
	or a
	jr z,fat_cache_fill_store
	; The controller retires every file slot on a namespace mutation, so a
	; token can die underneath us.  The FCB is authoritative and nothing is
	; lost by reopening, but only once -- a second failure is a real error,
	; not a handle that went stale.
	cp #FS2_STATUS_NO_HANDLE
	jr z,fat_cache_fill_reopen
	cp #FS2_STATUS_STALE
	jr nz,fat_cache_fill_failed
fat_cache_fill_reopen:
	call fat_hcache_close
	ld a,(fat_hcache_retry)
	or a
	jr nz,fat_cache_fill_failed
	ld a,#1
	ld (fat_hcache_retry),a
	jr fat_cache_fill_attempt
fat_cache_fill_failed:
	push af
	call fat_hcache_close
	pop af
	or a
	ret
fat_cache_fill_store:
	ld (fat_cache_len),bc
	ld hl,(fat_work_fcb)
	inc hl
	ld de,#fat_cache_name
	ld bc,#11
	ldir
	ld a,(fat_current_user)
	ld (fat_cache_user),a
	ld hl,#fat_line_rec
	ld de,#fat_cache_rec
	ld bc,#3
	ldir
	ld a,#1
	ld (fat_cache_valid),a
	xor a
	ret

; Serve the record out of the held line, padding a short tail with 1Ah
; exactly as the read-through path does.
fat_cache_deliver:
	ld hl,(fat_cache_len)
	ld de,(fat_cache_within)
	or a
	sbc hl,de
	jp z,fat_read_eof
	jp c,fat_read_eof
	ld bc,#128
	ld a,h
	or a
	jr nz,fat_cache_deliver_copy
	ld a,l
	cp #128
	jr nc,fat_cache_deliver_copy
	ld c,l
	ld b,#0
fat_cache_deliver_copy:
	; Copy first, then pad only what the copy did not cover.  Filling the
	; whole record with 1Ah and overwriting all of it again cost 128 LDIR
	; iterations per record, and three records in four are served from here.
	push bc
	ld hl,(fat_cache_line)
	ld de,(fat_cache_within)
	add hl,de
	ld de,(fat_work_dma)
	ldir				; DE ends just past the bytes copied
	pop bc
	ld a,#128
	sub c
	jr z,fat_cache_deliver_done	; a full record needs no padding at all
	ld c,a
	ld b,#0
	ld h,d
	ld l,e
	ld (hl),#0x1a
	inc de
	dec bc
	ld a,b
	or c
	jr z,fat_cache_deliver_done
	ldir
fat_cache_deliver_done:
	xor a
	scf
	ret

; DE=FCB, HL=DMA, fat_record already selected.
fat_read_record:
	ld (fat_work_fcb),de
	ld (fat_work_dma),hl
	call fat_cache_locate
	call fat_cache_hit
	jp z,fat_cache_deliver
	; Two different reasons to miss, and they are not the same thing.  Without
	; a line there is nothing to fill, so the slower read-through path runs --
	; that is the pool contract.  But a fill that was attempted and FAILED is
	; a real read error: retrying the same bytes through another path would
	; hide it and double the cost of every hard failure.
	call fat_cache_lease
	jr nz,fat_read_through
	call fat_cache_fill
	jp z,fat_cache_deliver
	jp fat_read_error
fat_read_through:
	; The FCB and DMA were recorded above; the cache calls clobber DE and HL,
	; so they are reloaded rather than re-derived from registers that no
	; longer hold them.
	ld de,(fat_work_fcb)
	call fat_open_fcb
	jr nz,fat_read_error
	ld hl,(fat_work_dma)
	ld (hl),#0x1a
	ld d,h
	ld e,l
	inc de
	ld bc,#127
	ldir
	call fat_record_offset
	ld bc,#128
	ld ix,(fat_work_dma)
	call fat_fs2_read
	push af
	push bc
	call fat_fs2_close
	ld d,a				; CLOSE failure is independent of READ
	pop bc
	pop af
	or a
	jr nz,fat_read_error
	ld a,d
	or a
	jr nz,fat_read_error
	ld a,b
	or c
	jr z,fat_read_eof
	xor a
	scf
	ret
fat_read_eof:
	ld a,#1
	or a				; establish NZ: A is nonzero
	scf
	ret
fat_read_error:
	ld a,#0xff			; filesystem/handle/transport error, not EOF
	or a
	scf
	ret

; DE=FCB, HL=DMA, fat_record already selected.  Opens for update, writes the
; one 128-byte record at that record's byte offset, and closes.  The close is
; the flush, which is why function 16 has nothing left to do -- and why a
; crash costs at most the record in flight.
fat_write_record:
	call fat_cache_flush
	ld (fat_work_fcb),de
	ld (fat_work_dma),hl
	call fat_check_write_protect
	jr nz,fat_write_error
	ld de,(fat_work_fcb)
	ld a,#FS2_OPEN_UPDATE
	call fat_open_fcb_mode
	jr nz,fat_write_status
	; fat_fs2_write sends what is already staged in the common bulk buffer.
	ld hl,(fat_work_dma)
	ld de,#FAC_BULK_BUF
	ld bc,#128
	ldir
	call fat_record_offset
	ld bc,#128
	call fat_fs2_write
	push af
	call fat_fs2_close
	ld d,a				; CLOSE failure is independent of WRITE
	pop af
	or a
	jr nz,fat_write_status
	ld a,d
	or a
	jr nz,fat_write_error
	xor a
	scf
	ret
; A full disk is a normal CP/M result, not a failure of the machine, so it
; gets its own code.  Everything else -- transport, media, an unknown commit
; -- is a hard error the caller must not mistake for "disk full".
fat_write_status:
	cp #FS2_STATUS_NO_SPACE
	jr nz,fat_write_error
	ld a,#2				; no available data block
	or a
	scf
	ret
fat_write_error:
	ld a,#0xff
	or a
	scf
	ret

fat_bdos_write_seq:
	ld (fat_work_fcb),de
	push hl
	call fat_seq_record
	pop hl
	call fat_write_record
	ret nz
	ld de,(fat_work_fcb)
	call fat_increment_seq
	xor a
	scf
	ret

fat_bdos_write_random:
	push hl
	push de
	ld hl,#33
	add hl,de
	ld de,#fat_record
	ld bc,#3
	ldir
	pop de
	pop hl
	jp fat_write_record

; Function 40 differs from 34 only in guaranteeing that a gap it skips over
; reads back as zeros.  FatFs extends a file by allocating clusters holding
; whatever was on the card, so the gap is written out explicitly.
fat_bdos_write_random_zf:
	; The caller's record may BE the common bulk buffer: the facade stages a
	; hidden DMA into FAC_DMA_BUF, and FAC_DMA_BUF is FAC_BULK_BUF.  The gap
	; fill writes zeros through that same buffer, so the record has to be
	; moved out of the way first or the fill destroys it and the record lands
	; on the card as zeros.  Plain WRITE is unaffected: its copy to the bulk
	; buffer is then a copy onto itself, which changes nothing.
	push de
	ld de,#fat_zf_save
	ld bc,#128
	ldir
	pop de
	push de
	ld hl,#33
	add hl,de
	ld de,#fat_record
	ld bc,#3
	ldir
	pop de
	push de
	call fat_zero_fill_gap
	pop de
	jr nz,fat_write_status
	ld hl,#fat_zf_save
	jp fat_write_record

; DE = FCB, fat_record = the target record.  Writes zero records from the
; file's current end up to (not including) the target, inside a single open.
fat_zero_fill_gap:
	call fat_cache_flush
	ld (fat_work_fcb),de
	call fat_check_write_protect
	ret nz
	ld de,(fat_work_fcb)
	ld a,#FS2_OPEN_UPDATE
	call fat_open_fcb_mode
	ret nz
	ld hl,#fat_record
	ld de,#fat_zf_target
	ld bc,#3
	ldir
	call fat_size_records
	; Every gap record writes the same 128 bytes, so stage them once.
	ld hl,#FAC_BULK_BUF
	ld (hl),#0
	ld d,h
	ld e,l
	inc de
	ld bc,#127
	ldir
fat_zf_loop:
	call fat_zf_remaining
	jr z,fat_zf_done
	ld hl,#fat_zf_rec
	ld de,#fat_record
	ld bc,#3
	ldir
	call fat_record_offset
	ld bc,#128
	call fat_fs2_write
	jr nz,fat_zf_failed
	ld hl,#fat_zf_rec
	inc (hl)
	jr nz,fat_zf_loop
	inc hl
	inc (hl)
	jr nz,fat_zf_loop
	inc hl
	inc (hl)
	jr fat_zf_loop
fat_zf_done:
	ld hl,#fat_zf_target
	ld de,#fat_record
	ld bc,#3
	ldir
	call fat_fs2_close
	or a
	ret
fat_zf_failed:
	push af
	call fat_fs2_close
	pop af
	or a
	ret

; fat_zf_rec = ceil(fat_file_size / 128): the first record past the end.
fat_size_records:
	ld hl,(fat_file_size)
	ld de,(fat_file_size + 2)
	ld bc,#127
	add hl,bc
	jr nc,fat_size_rec_nc
	inc de
fat_size_rec_nc:
	ld b,#7
fat_size_rec_shift:
	srl d
	rr e
	rr h
	rr l
	djnz fat_size_rec_shift
	ld (fat_zf_rec),hl
	ld a,e
	ld (fat_zf_rec + 2),a
	ret

; Z when the gap is exhausted (fat_zf_rec >= fat_zf_target).
fat_zf_remaining:
	ld a,(fat_zf_target + 2)
	ld b,a
	ld a,(fat_zf_rec + 2)
	cp b
	jr c,fat_zf_more
	jr nz,fat_zf_none
	ld a,(fat_zf_target + 1)
	ld b,a
	ld a,(fat_zf_rec + 1)
	cp b
	jr c,fat_zf_more
	jr nz,fat_zf_none
	ld a,(fat_zf_target)
	ld b,a
	ld a,(fat_zf_rec)
	cp b
	jr c,fat_zf_more
fat_zf_none:
	xor a
	ret
fat_zf_more:
	ld a,#1
	or a
	ret

; MAKE creates the file empty, materialising the USER directory first if this
; is the first file in one.  CREATE_ALWAYS matches CP/M: MAKE over an existing
; name truncates it.
fat_bdos_make:
	call fat_cache_flush
	ld (fat_work_fcb),de
	call fat_check_write_protect
	jp nz,fat_bdos_fail
	call fat_ensure_user_dir
	jp nz,fat_bdos_fail
	ld de,(fat_work_fcb)
	ld a,#FS2_OPEN_CREATE_ALWAYS
	call fat_open_fcb_mode
	jp nz,fat_bdos_fail
	call fat_fs2_close
	jp nz,fat_bdos_fail
	ld de,(fat_work_fcb)
	call fat_fcb_stamp_user
	; The file is empty, so the first sequential write must land at record 0.
	ld hl,#12
	add hl,de
	xor a
	ld (hl),a			; EX
	inc hl
	ld (hl),a			; S1
	inc hl
	ld (hl),a			; S2
	inc hl
	ld (hl),a			; RC
	ld hl,#32
	add hl,de
	ld (hl),a			; CR
	xor a
	scf
	ret

; RENAME takes the existing name at FCB+1 and the new one at FCB+17.  Both
; resolve in the current directory; CP/M has no cross-directory rename.
fat_bdos_rename:
	call fat_cache_flush
	ld (fat_work_fcb),de
	call fat_check_write_protect
	jp nz,fat_bdos_fail
	call fat_search_reset
	ld a,#1
	call fat_fs2_path
	jp nz,fat_bdos_fail
	ld hl,(fat_work_fcb)
	ld de,#17
	add hl,de
	ex de,hl			; DE = new name
	ld hl,(fat_work_fcb)
	inc hl				; HL = existing name
	call fat_fs2_rename
	jp nz,fat_bdos_fail
	xor a
	scf
	ret

; ERA takes ambiguous names, so DELETE enumerates and removes every match.
; The directory is reopened for each one: FatFs makes no promise about
; enumerating a directory while it is being modified, and the controller
; closes its file slots on every unlink anyway.  This borrows
; fat_search_pattern and fat_search_match, so it resets any SEARCH in
; progress first -- removing entries would leave that enumeration pointing
; into a directory that moved underneath it.
fat_bdos_delete:
	call fat_cache_flush
	ld (fat_work_fcb),de
	call fat_check_write_protect
	jp nz,fat_bdos_fail
	call fat_search_reset
	ld hl,(fat_work_fcb)
	inc hl
	ld de,#fat_search_pattern
	ld bc,#11
	ldir
	xor a
	ld (fat_delete_count),a
fat_delete_loop:
	call fat_delete_find
	jr nz,fat_delete_done
	ld hl,#fat_delete_name
	ld a,#FS2_CMD_UNLINK
	call fat_fs2_name_op
	jp nz,fat_bdos_fail
	ld hl,#fat_delete_count
	inc (hl)
	jr nz,fat_delete_loop
fat_delete_done:
	ld a,(fat_delete_count)
	or a
	jp z,fat_bdos_fail
	xor a
	scf
	ret

; Z with fat_delete_name set when an entry matching fat_search_pattern exists.
fat_delete_find:
	ld a,#1
	call fat_fs2_path
	ret nz
	call fat_zero_frames
	ld a,#FS2_CMD_OPENDIR
	ld (FAT_TX),a
	ld a,#FS2_RSP_OPENDIR
	call fat_exchange
	ret nz
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD)
	ld (fat_dir_token),hl
fat_delete_scan:
	call fat_zero_frames
	ld a,#FS2_CMD_READDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_READDIR
	call fat_exchange
	jr nz,fat_delete_scan_end
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 11)
	and #FS2_ATTR_DIR
	jr nz,fat_delete_scan
	call fat_search_match
	jr nz,fat_delete_scan
	ld hl,#(FAT_RX + IOC_OFF_PAYLOAD)
	ld de,#fat_delete_name
	ld bc,#11
	ldir
	call fat_delete_close_dir
	xor a
	ret
fat_delete_scan_end:
	call fat_delete_close_dir
	ld a,#1
	or a
	ret
fat_delete_close_dir:
	push af
	call fat_zero_frames
	ld a,#FS2_CMD_CLOSEDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_CLOSEDIR
	call fat_exchange
	pop af
	ret

fat_bdos_read_seq:
	ld (fat_work_fcb),de
	push hl
	call fat_seq_record
	pop hl
	call fat_read_record
	ret nz
	ld de,(fat_work_fcb)
	call fat_increment_seq
	xor a
	scf
	ret

fat_bdos_read_random:
	push hl
	push de
	ld hl,#33
	add hl,de
	ld de,#fat_record
	ld bc,#3
	ldir
	pop de
	pop hl
	jp fat_read_record

fat_bdos_file_size:
	ld (fat_work_fcb),de
	call fat_open_fcb
	jp nz,fat_bdos_fail
	call fat_fs2_close
	jp nz,fat_bdos_fail
	ld hl,(fat_file_size)
	ld de,(fat_file_size + 2)
	ld bc,#127
	add hl,bc
	jr nc,fat_size_no_carry
	inc de
fat_size_no_carry:
	ld b,#7
fat_size_shift:
	srl d
	rr e
	rr h
	rr l
	djnz fat_size_shift
	ld a,e
	push af
	ld de,(fat_work_fcb)
	ex de,hl
	ld bc,#33
	add hl,bc
	ex de,hl
	ld a,l
	ld (de),a
	inc de
	ld a,h
	ld (de),a
	inc de
	pop af				; high record byte was shifted in E
	ld (de),a
	xor a
	scf
	ret

; SEARCH FIRST/NEXT.  The IOC returns strict representable 8.3 entries; the
; compatibility layer filters directories and applies CP/M '?' matching.
fat_bdos_search_first:
	push de
	push hl
	call fat_search_reset
	pop hl
	pop de
	ld (fat_work_dma),hl
	ld a,(de)
	cp #'?'
	jr nz,fat_search_copy_pattern
	ld a,#1
	ld (fat_search_raw),a
	ld hl,#fat_search_pattern
	ld b,#11
fat_search_raw_pattern:
	ld (hl),#'?'
	inc hl
	djnz fat_search_raw_pattern
	jr fat_search_pattern_ready
fat_search_copy_pattern:
	ld hl,#fat_search_pattern
	push de
	inc de
	ex de,hl
	ld bc,#11
	ldir
	pop de
fat_search_pattern_ready:
	ld a,(fat_current_user)
	ld (fat_search_origin_user),a
	ld b,a
	ld a,(fat_search_raw)
	or a
	ld a,b
	jr z,fat_search_first_user_ready
	xor a				; raw scan starts with USER 0
fat_search_first_user_ready:
	ld (fat_search_user),a
	call fat_fcb_stamp_user
	call fat_search_open_user
	jr z,fat_search_next_entry
	ld a,(fat_search_raw)
	or a
	jp z,fat_search_fail
	ld a,(fat_last_status)
	cp #FS2_STATUS_NOT_FOUND
	jp nz,fat_search_fail
	jp fat_search_next_user_no_close

; Open the directory represented by fat_search_user.  Temporarily substitute
; that USER only while building the IOC resolver; ZSDOS/facade state remains
; authoritative and is restored before any reply is consumed.
fat_search_open_user:
	ld a,(fat_current_user)
	push af
	ld a,(fat_search_user)
	ld (fat_current_user),a
	ld a,#1
	call fat_fs2_path
	ld b,a
	pop af
	ld (fat_current_user),a
	ld a,b
	or a
	ret nz
	call fat_zero_frames
	ld a,#FS2_CMD_OPENDIR
	ld (FAT_TX),a
	ld a,#FS2_RSP_OPENDIR
	call fat_exchange
	ret nz
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD)
	ld (fat_dir_token),hl
	ld a,#1
	ld (fat_search_active),a
	xor a
	ret
fat_bdos_search_next:
	ld (fat_work_dma),hl
	ld a,(fat_search_origin_user)
	ld b,a
	ld a,(fat_current_user)
	cp b
	jr nz,fat_search_fail
fat_search_next_entry:
	call fat_zero_frames
	ld a,#FS2_CMD_READDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_READDIR
	call fat_exchange
	jr nz,fat_search_end_or_error
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 11)
	and #FS2_ATTR_DIR
	jr nz,fat_search_next_entry
	call fat_search_match
	jr nz,fat_search_next_entry
	call fat_search_save
	call fat_search_emit_saved
	xor a
	scf
	ret
fat_search_end_or_error:
	ld a,(fat_last_status)
	cp #FS2_STATUS_END
	jr nz,fat_search_fail
	ld a,(fat_search_raw)
	or a
	jr z,fat_search_fail
	call fat_search_close_dir
	jr nz,fat_search_fail
fat_search_next_user_no_close:
	ld a,(fat_search_user)
	inc a
	cp #16
	jr nc,fat_search_fail
	ld (fat_search_user),a
	call fat_search_open_user
	jr z,fat_search_next_entry
	ld a,(fat_last_status)
	cp #FS2_STATUS_NOT_FOUND
	jr z,fat_search_next_user_no_close
fat_search_fail:
	call fat_search_reset
	ld a,#0xff
	scf
	ret

; DE=FCB.  ZSDOS marks S1 as a valid cached USER during OPEN and SEARCH FIRST.
; Keep the same caller-visible convention while the bank-7 USER mirror remains
; a cache of ZSDOS's authoritative value.
fat_fcb_stamp_user:
	push hl
	ld hl,#13
	add hl,de
	ld a,(fat_current_user)
	or #0x80
	ld (hl),a
	pop hl
	ret

fat_search_match:
	ld hl,#fat_search_pattern
	ld de,#(FAT_RX + IOC_OFF_PAYLOAD)
	ld b,#11
fat_search_match_loop:
	ld a,(hl)
	and #0x7f
	cp #'?'
	jr z,fat_search_match_next
	ld c,a
	ld a,(de)
	and #0x7f
	cp c
	ret nz
fat_search_match_next:
	inc hl
	inc de
	djnz fat_search_match_loop
	xor a
	ret

; Save the current IOC entry and derive its 128-byte record count.  SEARCH
; presents one synthetic directory entry per FAT file.  Its EX/S2/RC fields
; describe the terminal logical extent, as directory consumers use those
; fields to recover the file length.  FAT has no physical CP/M allocation
; blocks, and exposing several invented entries makes ordinary directory tools
; print the same filename repeatedly.
fat_search_save:
	ld hl,#(FAT_RX + IOC_OFF_PAYLOAD)
	ld de,#fat_search_name
	ld bc,#11
	ldir
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD + 12)
	ld de,(FAT_RX + IOC_OFF_PAYLOAD + 14)
	ld bc,#127
	add hl,bc
	jr nc,fat_search_size_no_carry
	inc de
fat_search_size_no_carry:
	ld b,#7
fat_search_size_shift:
	srl d
	rr e
	rr h
	rr l
	djnz fat_search_size_shift
	ld (fat_search_records),hl
	ld a,e
	ld (fat_search_records + 2),a
	xor a
	ld (fat_search_extent),a
	ld (fat_search_pending),a
	ret

fat_search_emit_saved:
	ld hl,(fat_work_dma)
	ld (hl),#0xe5
	ld d,h
	ld e,l
	inc de
	ld bc,#127
	ldir
	ld hl,(fat_work_dma)
	ld (hl),#0
	ld d,h
	ld e,l
	inc de
	ld bc,#31
	ldir
	ld hl,(fat_work_dma)
	ld a,(fat_search_user)
	ld (hl),a
	inc hl
	ld de,#fat_search_name
	ex de,hl
	ld bc,#11
	ldir
	; FAT attributes have no CP/M compatibility meaning.  Keep all filename and
	; extension bytes seven-bit clean; the personality is already read-only.
	ld hl,(fat_work_dma)
	ld de,#12
	add hl,de
	push hl
	call fat_search_terminal_fields	; B=EX, C=S2, A=RC
	pop hl
	ld (hl),b			; EX
	inc hl				; S1 remains zero
	inc hl
	ld (hl),c			; S2
	inc hl
	ld (hl),a			; RC
	xor a
	ld (fat_search_pending),a
	ret

; Return the terminal CP/M logical extent for the 24-bit record count.
; Empty files are EX=S2=RC=0.  Otherwise the terminal record number is
; records-1: EX/S2 select its 128-record extent and RC is its one-based record
; count within that extent.  This is one directory entry, not a claim that FAT
; has CP/M physical extents or allocation blocks.
fat_search_terminal_fields:
	ld hl,(fat_search_records)
	ld a,(fat_search_records + 2)
	ld d,a
	ld a,h
	or l
	jr nz,fat_search_terminal_nonzero
	ld a,d
	or a
	jr nz,fat_search_terminal_borrow
	ld b,#0
	ld c,#0
	xor a
	ret
fat_search_terminal_borrow:
	dec d
fat_search_terminal_nonzero:
	dec hl
	ld a,l
	and #0x7f
	inc a
	ld e,a				; preserve RC while shifting extent
	ld b,#7
fat_search_terminal_record_shift:
	srl d
	rr h
	rr l
	djnz fat_search_terminal_record_shift
	ld a,l
	and #0x1f
	push af				; terminal EX
	ld b,#5
fat_search_terminal_s2_shift:
	srl d
	rr h
	rr l
	djnz fat_search_terminal_s2_shift
	ld a,l
	and #0x3f
	ld c,a				; terminal S2
	pop af
	ld b,a				; terminal EX
	ld a,e				; terminal RC
	ret

fat_search_close_dir:
	ld a,(fat_search_active)
	or a
	ret z
	call fat_zero_frames
	ld a,#FS2_CMD_CLOSEDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_CLOSEDIR
	call fat_exchange
	push af
	xor a
	ld (fat_search_active),a
	pop af
	ret

fat_search_reset:
	call fat_search_close_dir
fat_search_reset_clear:
	xor a
	ld (fat_search_active),a
	ld (fat_search_raw),a
	ld (fat_search_pending),a
	ret

fat_native_entry:
	ld (fat_native_desc),de
	; The gate copied the descriptor unchanged.  Version is byte zero; reload it
	; through HL because DE is also the persistent descriptor base.
	ld hl,(fat_native_desc)
	ld a,(hl)
	cp #ZNATIVE_VERSION
	jp nz,fat_native_bad
	inc hl
	ld a,(hl)
	cp #ZNATIVE_OPEN
	jp z,fat_native_open
	cp #ZNATIVE_CLOSE
	jp z,fat_native_close
	cp #ZNATIVE_READ
	jp z,fat_native_read
	cp #ZNATIVE_SEEK
	jp z,fat_native_seek
	cp #ZNATIVE_TELL
	jp z,fat_native_tell
	cp #ZNATIVE_STAT
	jp z,fat_native_stat
	cp #ZNATIVE_OPENDIR
	jp z,fat_native_opendir
	cp #ZNATIVE_READDIR
	jp z,fat_native_readdir
	cp #ZNATIVE_CHDIR
	jp z,fat_native_chdir
	cp #ZNATIVE_WRITE
	jp z,fat_native_write
	cp #ZNATIVE_SYNC
	jp z,fat_native_sync
	cp #ZNATIVE_TRUNCATE
	jp z,fat_native_truncate
	cp #ZNATIVE_DELETE
	jp z,fat_native_delete
	cp #ZNATIVE_RENAME
	jp z,fat_native_rename
	cp #ZNATIVE_MKDIR
	jp z,fat_native_mkdir
	cp #ZNATIVE_RMDIR
	jp z,fat_native_rmdir
fat_native_bad:
	ld a,#0xff
	jp fat_native_return

fat_native_return:
	ld hl,(fat_native_desc)
	inc hl
	inc hl
	ld (hl),a
	ret

fat_native_name:
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_NAME
	add hl,de
	ret

fat_native_slot:
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	or a
	jr z,fat_native_slot_bad
	cp #3
	jr nc,fat_native_slot_bad
	dec a
	ld (fat_native_slot_index),a
	ld e,a
	ld d,#0
	ld hl,#fat_native_active
	add hl,de
	ld a,(hl)
	or a
	jr z,fat_native_slot_bad
	ld a,e
	add a,a
	ld e,a
	ld hl,#fat_native_tokens
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	xor a
	ret
fat_native_slot_bad:
	ld a,#FS2_STATUS_NO_HANDLE
	or a
	ret

fat_native_open:
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld a,(hl)
	cp #(ZNATIVE_OPEN_CREATE_ALWAYS + 1)
	jr c,fat_native_open_mode_ok
	ld a,#FS2_STATUS_RANGE
	jp fat_native_return
fat_native_open_mode_ok:
	ld (fat_native_open_mode),a
	call fat_cache_flush
	ld a,(fat_native_open_mode)
	or a
	jr z,fat_native_open_path
	call fat_check_write_protect
	jp nz,fat_native_return
fat_native_open_path:
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_native_name
	ld a,(fat_native_open_mode)
	or a
	jr z,fat_native_open_read
	dec a				; native modes 1..3 -> FS2 modes 0..2
	call fat_fs2_open_rw
	jr fat_native_open_result
fat_native_open_read:
	call fat_fs2_open
fat_native_open_result:
	push af
	ld a,(fat_native_open_mode)
	cp #ZNATIVE_OPEN_CREATE_NEW
	jr c,fat_native_open_known
	pop af
	cp #FS2_STATUS_TRANSPORT
	jr nz,fat_native_open_checked
	ld a,#FS2_STATUS_UNKNOWN_WRITE
	jr fat_native_open_checked
fat_native_open_known:
	pop af
fat_native_open_checked:
	or a
	jp nz,fat_native_return
	ld a,(fat_native_active)
	or a
	jr z,fat_native_open_slot0
	ld a,(fat_native_active + 1)
	or a
	jr z,fat_native_open_slot1
	call fat_fs2_close
	jp nz,fat_native_return
	ld a,#FS2_STATUS_NO_HANDLE
	jp fat_native_return
fat_native_open_slot0:
	ld a,#0
	jr fat_native_open_store
fat_native_open_slot1:
	ld a,#1
fat_native_open_store:
	ld c,a
	ld (fat_native_slot_index),a
	ld e,a
	ld d,#0
	ld hl,#fat_native_active
	add hl,de
	ld (hl),#1
	ld hl,#fat_native_modes
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	add hl,de
	ld a,(fat_native_open_mode)
	ld (hl),a
	ld a,c
	add a,a
	ld e,a
	ld hl,#fat_native_tokens
	add hl,de
	ld de,(fat_file_token)
	ld (hl),e
	inc hl
	ld (hl),d
	; Retain authoritative path identity so a stale read-only IOC token can be
	; reopened safely after a media-generation change.
	ld a,c
	or a
	ld hl,#fat_native_name0
	ld de,#fat_native_cwd0
	jr z,fat_native_identity_ptrs
	ld hl,#fat_native_name1
	ld de,#fat_native_cwd1
fat_native_identity_ptrs:
	push de
	ex de,hl
	call fat_native_name
	ld bc,#11
	ldir
	pop de
	ld a,(fat_current_user)
	ld (de),a
	inc de
	call fat_effective_cwd_count
	ld (de),a
	inc de
	; A relative CWD of zero components is the drive root -- the normal case,
	; and the one every native OPEN from D: itself takes.  LDIR must not be
	; reached with BC=0: the Z80 decrements BC before it tests, so a zero count
	; transfers 65536 bytes instead of none, walking fat_cwd_components over
	; the whole address space and destroying bank 7 with the OS still in it.
	; fat_native_reopen already skips its replay on a zero count; this is the
	; same condition on the recording side.
	or a
	jr z,fat_native_identity_done
	ld l,a
	ld h,#0
	push de
	ld e,l
	ld d,h
	add hl,hl
	add hl,hl
	add hl,de
	add hl,hl			; count * 10
	add hl,de			; count * 11
	ld b,h
	ld c,l
	pop de
	ld hl,#fat_cwd_components
	ldir
fat_native_identity_done:
	ld a,(fat_native_slot_index)
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_positions
	add hl,de
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(fat_native_slot_index)
	inc a
	ld (hl),a
	ld de,#(ZNATIVE_OFF_POSITION - ZNATIVE_OFF_HANDLE)
	add hl,de
	ex de,hl
	ld hl,#fat_file_size
	ld bc,#4
	ldir
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld a,(fat_file_attr)
	ld (hl),a
	xor a
	jp fat_native_return

fat_native_close:
	call fat_native_slot
	jp nz,fat_native_return
	ld (fat_file_token),de
	call fat_fs2_close
	cp #FS2_STATUS_TRANSPORT
	jr nz,fat_native_close_status
	ld hl,#fat_native_modes
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	or a
	jr z,fat_native_close_status
	ld a,#FS2_STATUS_UNKNOWN_WRITE
fat_native_close_status:
	push af
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	ld hl,#fat_native_active
	add hl,de
	ld (hl),#0
	ld hl,#fat_native_modes
	add hl,de
	ld (hl),#0
	pop af
	jp fat_native_return

fat_native_read:
	call fat_native_slot
	jp nz,fat_native_return
	ld (fat_file_token),de
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	dec a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_positions
	add hl,de
	ld (fat_native_pos_ptr),hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld c,(hl)
	inc hl
	ld b,(hl)
	ex de,hl			; BC:HL position
	ld d,b
	ld e,c			; DE:HL position
	ld bc,(fat_native_desc)
	push hl
	ld h,b
	ld l,c
	ld bc,#ZNATIVE_OFF_LENGTH
	add hl,bc
	ld c,(hl)
	inc hl
	ld b,(hl)
	pop hl
	ld ix,#FAC_BULK_BUF
	call fat_fs2_read
	cp #FS2_STATUS_STALE
	jr nz,fat_native_read_result
	ld hl,#fat_native_modes
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	or a
	jr z,fat_native_read_reopen
	call fat_native_invalidate_slot
	ld a,#FS2_STATUS_STALE
	jp fat_native_return
fat_native_read_reopen:
	call fat_native_reopen
	jp nz,fat_native_return
	; Position and request length are still in the descriptor/slot; restart the
	; read once with the newly issued token.
	jp fat_native_read
fat_native_read_result:
	; Re-test A.  The STALE comparison above set the flags from the CP, not
	; from fat_fs2_read's result, so a successful read arrived here as NZ and
	; returned status 0 while skipping the RESULT store and the position
	; advance below -- every native read reported zero bytes.  The sync,
	; truncate and open paths all re-test the same way.
	or a
	jp nz,fat_native_return
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_RESULT
	add hl,de
	ld (hl),c
	inc hl
	ld (hl),b
	ld hl,(fat_native_pos_ptr)
	ld a,(hl)
	add a,c
	ld (hl),a
	inc hl
	ld a,(hl)
	adc a,b
	ld (hl),a
	inc hl
	jr nc,fat_native_read_done
	inc (hl)
	jr nz,fat_native_read_done
	inc hl
	inc (hl)
fat_native_read_done:
	xor a
	jp fat_native_return

; The selected native slot must have been opened through a writable mode and
; D: must not be protected by ZSDOS.  Physical/filesystem protection is still
; enforced by FatFs on the controller.
fat_native_require_write:
	ld hl,#fat_native_modes
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	or a
	jr nz,fat_native_require_write_wp
	ld a,#FS2_STATUS_READ_ONLY
	or a
	ret
fat_native_require_write_wp:
	jp fat_check_write_protect

fat_native_invalidate_slot:
	ld a,(fat_native_slot_index)
	ld e,a
	ld d,#0
	ld hl,#fat_native_active
	add hl,de
	ld (hl),#0
	ld hl,#fat_native_modes
	add hl,de
	ld (hl),#0
	ret

fat_native_write:
	call fat_cache_flush
	call fat_native_slot
	jp nz,fat_native_return
	ld (fat_file_token),de
	call fat_native_require_write
	jp nz,fat_native_return
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	dec a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_positions
	add hl,de
	ld (fat_native_pos_ptr),hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld c,(hl)
	inc hl
	ld b,(hl)
	ex de,hl
	ld d,b
	ld e,c			; DE:HL explicit byte offset
	ld bc,(fat_native_desc)
	push hl
	ld h,b
	ld l,c
	ld bc,#ZNATIVE_OFF_LENGTH
	add hl,bc
	ld c,(hl)
	inc hl
	ld b,(hl)
	pop hl
	ld a,b
	or c
	jr z,fat_native_write_range
	ld a,b
	cp #2
	jr c,fat_native_write_length_ok
	jr nz,fat_native_write_range
	ld a,c
	or a
	jr nz,fat_native_write_range
fat_native_write_length_ok:
	call fat_fs2_write
	jr z,fat_native_write_success
	push af
	ld a,(fat_write_started)
	or a
	call nz,fat_native_invalidate_slot
	pop af
	jp fat_native_return
fat_native_write_range:
	ld a,#FS2_STATUS_RANGE
	jp fat_native_return
fat_native_write_success:
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_LENGTH
	add hl,de
	ld c,(hl)
	inc hl
	ld b,(hl)
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_RESULT
	add hl,de
	ld (hl),c
	inc hl
	ld (hl),b
	ld hl,(fat_native_pos_ptr)
	ld a,(hl)
	add a,c
	ld (hl),a
	inc hl
	ld a,(hl)
	adc a,b
	ld (hl),a
	inc hl
	jr nc,fat_native_write_done
	inc (hl)
	jr nz,fat_native_write_done
	inc hl
	inc (hl)
fat_native_write_done:
	xor a
	jp fat_native_return

fat_native_sync:
	call fat_native_slot
	jp nz,fat_native_return
	ld (fat_file_token),de
	call fat_native_require_write
	jp nz,fat_native_return
	call fat_fs2_sync
	cp #FS2_STATUS_TRANSPORT
	jr nz,fat_native_sync_result
	ld a,#FS2_STATUS_UNKNOWN_WRITE
fat_native_sync_result:
	or a
	jp z,fat_native_return
	push af
	call fat_native_invalidate_slot
	pop af
	jp fat_native_return

fat_native_truncate:
	call fat_cache_flush
	call fat_native_slot
	jp nz,fat_native_return
	ld (fat_file_token),de
	call fat_native_require_write
	jp nz,fat_native_return
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld c,(hl)
	inc hl
	ld b,(hl)
	ex de,hl
	ld d,b
	ld e,c			; DE:HL requested size
	call fat_fs2_truncate
	cp #FS2_STATUS_TRANSPORT
	jr nz,fat_native_truncate_result
	ld a,#FS2_STATUS_UNKNOWN_WRITE
fat_native_truncate_result:
	or a
	jp z,fat_native_return
	push af
	call fat_native_invalidate_slot
	pop af
	jp fat_native_return

; The controller closes every FS2 file slot before it mutates the directory,
; because FF_FS_LOCK is 0 there and FatFs will not stop an unlink or rename of
; a file something still holds open.  The tokens on this side are therefore
; dead whatever the outcome, and saying so here keeps a later operation from
; presenting a token the controller has already retired.
fat_native_forget_slots:
	call fat_cache_flush
	xor a
	ld (fat_native_active),a
	ld (fat_native_active + 1),a
	ld (fat_native_modes),a
	ld (fat_native_modes + 1),a
	ret

fat_native_delete:
	ld a,#FS2_CMD_UNLINK
	jr fat_native_name_op
fat_native_mkdir:
	ld a,#FS2_CMD_MKDIR
	jr fat_native_name_op
fat_native_rmdir:
	ld a,#FS2_CMD_RMDIR
fat_native_name_op:
	ld (fat_native_op_cmd),a
	call fat_check_write_protect
	jp nz,fat_native_return
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_native_name
	ld a,(fat_native_op_cmd)
	call fat_fs2_name_op
	jr fat_native_mutate_result

; Source in the descriptor's name field, destination at ZNATIVE_OFF_NAME2.
fat_native_rename:
	call fat_check_write_protect
	jp nz,fat_native_return
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_native_name
	push hl
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_NAME2
	add hl,de
	ex de,hl			; DE = destination name
	pop hl				; HL = source name
	call fat_fs2_rename
fat_native_mutate_result:
	; A directory mutation whose commit is unknown must never be replayed.
	cp #FS2_STATUS_TRANSPORT
	jr nz,fat_native_mutate_known
	ld a,#FS2_STATUS_UNKNOWN_WRITE
fat_native_mutate_known:
	push af
	call fat_native_forget_slots
	pop af
	jp fat_native_return

fat_native_reopen:
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	dec a
	ld (fat_native_slot_index),a
	or a
	ld hl,#fat_native_name0
	ld de,#fat_native_cwd0
	jr z,fat_native_reopen_ptrs
	ld hl,#fat_native_name1
	ld de,#fat_native_cwd1
fat_native_reopen_ptrs:
	ld (fat_native_identity_name),hl
	ex de,hl
	ld c,(hl)			; USER captured when the handle opened
	inc hl
	ld b,(hl)			; relative CWD component count
	inc hl
	ld (fat_native_identity_cwd),hl
	push bc
	call fat_fs2_base
	pop bc
	ret nz
	ld a,c
	push bc
	call fat_fs2_push_user
	pop bc
	ret nz
	ld a,b
	or a
	jr z,fat_native_reopen_file
	ld hl,(fat_native_identity_cwd)
	call fat_fs2_push_components
	ret nz
fat_native_reopen_file:
	ld hl,(fat_native_identity_name)
	call fat_fs2_open
	ret nz
	ld a,(fat_native_slot_index)
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_tokens
	add hl,de
	ld de,(fat_file_token)
	ld (hl),e
	inc hl
	ld (hl),d
	xor a
	ret

fat_native_seek:
	call fat_native_slot
	jp nz,fat_native_return
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	dec a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_positions
	add hl,de
	ex de,hl
	ld hl,(fat_native_desc)
	ld bc,#ZNATIVE_OFF_POSITION
	add hl,bc
	ld bc,#4
	ldir
	xor a
	jp fat_native_return

fat_native_tell:
	call fat_native_slot
	jp nz,fat_native_return
	; SEEK already copies descriptor position into the slot.  Reverse the copy.
	ld hl,(fat_native_desc)
	ld bc,#ZNATIVE_OFF_HANDLE
	add hl,bc
	ld a,(hl)
	dec a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#fat_native_positions
	add hl,de
	ld de,(fat_native_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_POSITION
	add hl,bc
	ex de,hl
	ld bc,#4
	ldir
	xor a
	jp fat_native_return

fat_native_stat:
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_native_name
	call fat_fs2_open
	jp nz,fat_native_return
	call fat_fs2_close
	jp nz,fat_native_return
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	ex de,hl
	ld hl,#fat_file_size
	ld bc,#4
	ldir
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld a,(fat_file_attr)
	ld (hl),a
	xor a
	jp fat_native_return

fat_native_opendir:
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_zero_frames
	ld a,#FS2_CMD_OPENDIR
	ld (FAT_TX),a
	ld a,#FS2_RSP_OPENDIR
	call fat_exchange
	jp nz,fat_native_return
	ld hl,(FAT_RX + IOC_OFF_PAYLOAD)
	ld (fat_native_dir_token),hl
	ld a,#1
	ld (fat_native_dir_active),a
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld (hl),#1
	xor a
	jp fat_native_return

fat_native_readdir:
	ld a,(fat_native_dir_active)
	or a
	jr z,fat_native_dir_bad
	call fat_zero_frames
	ld a,#FS2_CMD_READDIR
	ld (FAT_TX),a
	ld a,#2
	ld (FAT_TX + IOC_OFF_LEN),a
	ld hl,(fat_native_dir_token)
	ld (FAT_TX + IOC_OFF_PAYLOAD),hl
	ld a,#FS2_RSP_READDIR
	call fat_exchange
	jp nz,fat_native_return
	ld hl,#(FAT_RX + IOC_OFF_PAYLOAD)
	ld de,(fat_native_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_NAME
	add hl,bc
	ex de,hl
	ld bc,#11
	ldir
	ld a,(FAT_RX + IOC_OFF_PAYLOAD + 11)
	ld hl,(fat_native_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld (hl),a
	ld hl,#(FAT_RX + IOC_OFF_PAYLOAD + 12)
	ld de,(fat_native_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_POSITION
	add hl,bc
	ex de,hl
	ld bc,#4
	ldir
	xor a
	jp fat_native_return
fat_native_dir_bad:
	ld a,#FS2_STATUS_NO_HANDLE
	jp fat_native_return

fat_native_chdir:
	call fat_cache_flush
	; An empty component selects the current USER's drive root.  Test this
	; before replaying the old CWD so it also provides a recovery path if a
	; directory was removed on the FAT volume.
	call fat_native_name
	ld a,(hl)
	or a
	jr z,fat_native_chdir_root
	cp #' '
	jr z,fat_native_chdir_root
	call fat_effective_cwd_count
	cp #16
	jp nc,fat_native_bad
	ld a,#1
	call fat_fs2_path
	jp nz,fat_native_return
	call fat_native_name
	push hl
	call fat_fs2_push
	pop hl
	jp nz,fat_native_return
	push hl
	call fat_effective_cwd_count
	ld e,a
	ld d,#0
	push hl
	ld hl,#0
	ld b,e
fat_native_cwd_offset:
	ld a,b
	or a
	jr z,fat_native_cwd_store
	ld de,#11
	add hl,de
	djnz fat_native_cwd_offset
fat_native_cwd_store:
	ld de,#fat_cwd_components
	add hl,de
	ex de,hl
	pop hl
	ld bc,#11
	ldir
	call fat_effective_cwd_count
	inc a
	ld (fat_cwd_count),a
	ld a,(fat_current_user)
	ld (fat_cwd_user),a
	pop hl
	xor a
	jp fat_native_return
fat_native_chdir_root:
	xor a
	ld (fat_cwd_count),a
	ld a,(fat_current_user)
	ld (fat_cwd_user),a
	xor a
	jp fat_native_return

fat_component_cpm:
	.ascii "CPM     "
	.ascii "   "
fat_component_d:
	.ascii "D       "
	.ascii "   "

FAT_BDOS_CODE_END:

	.area WORK (ABS)
	.org CBIOS_FAT_BDOS_STATE_BASE

FAT_BDOS_STATE_START:
fat_bios_track:
	.dw 0x0000
fat_bios_sector:
	.dw 0x0000

; ZSDOS owns this compatibility allocation vector after selecting/logging D:.
; Keep it immediately after track/sector: the generated layout contract and
; the DPH both rely on this deliberate fixed placement.
FAT_BIOS_ALV:
	.rept 0x0100
	.db 0x00
	.endm

fat_current_drive:
	.db 0x00
fat_current_user:
	.db 0x00
fat_ro_vector:
	.dw 0x0000
fat_expected:
	.db 0x00
fat_last_status:
	.db 0x00
fat_path_user:
	.db 0x00
fat_post_fn:
	.dw 0x0000
fat_post_de:
	.dw 0x0000
fat_alv_allocated:
	.dw 0x0000
fat_alv_remainder:
	.db 0x00
fat_file_token:
	.dw 0x0000
fat_file_size:
	.ds 4
fat_file_attr:
	.db 0x00
fat_dir_token:
	.dw 0x0000
fat_record:
	.ds 3
fat_work_fcb:
	.dw 0x0000
fat_work_dma:
	.dw 0x0000
fat_search_active:
	.db 0x00
fat_search_raw:
	.db 0x00
fat_search_origin_user:
	.db 0x00
fat_search_user:
	.db 0x00
fat_search_pattern:
	.ds 11
fat_search_name:
	.ds 11
fat_search_records:
	.ds 3
fat_search_extent:
	.db 0x00
fat_search_pending:
	.db 0x00
fat_user_component:
	.ds 11
fat_cwd_count:
	.db 0x00
fat_cwd_user:
	.db 0xff
fat_cwd_components:
	.ds (16 * FS2_NAME_BYTES)
fat_native_desc:
	.dw 0x0000
fat_native_active:
	.ds 2
fat_native_modes:
	.ds 2
fat_native_tokens:
	.ds 4
fat_native_positions:
	.ds 8
fat_native_pos_ptr:
	.dw 0x0000
fat_native_op_cmd:
	.db 0
fat_open_mode_save:
	.db 0
fat_delete_count:
	.db 0
fat_delete_name:
	.ds 11
fat_zf_target:
	.ds 3
fat_zf_rec:
	.ds 3
fat_zf_save:
	.ds 128
; Explicitly zeroed: .ds leaves whatever fill the image carries, and FFh here
; reads as "every line is owned", which would refuse every lease and disable
; the cache with no symptom other than being slow.
res_owners:
	.db 0,0,0,0,0,0,0,0,0,0,0,0,0
fat_cache_line:
	.dw 0
fat_cache_len:
	.dw 0
fat_cache_within:
	.dw 0
fat_cache_valid:
	.db 0
fat_cache_tried:
	.db 0
fat_cache_user:
	.db 0
fat_cache_name:
	.ds 11
fat_cache_rec:
	.ds 3
fat_line_rec:
	.ds 3
fat_cache_saverec:
	.ds 3
fat_hcache_valid:
	.db 0
fat_hcache_retry:
	.db 0
fat_hcache_user:
	.db 0
fat_hcache_token:
	.dw 0
fat_hcache_name:
	.ds 11
fat_native_slot_index:
	.db 0x00
fat_native_open_mode:
	.db 0x00
fat_write_started:
	.db 0x00
fat_write_xfer_id:
	.db 0x00
fat_write_length:
	.dw 0x0000
fat_write_offset:
	.ds 4
fat_native_dir_active:
	.db 0x00
fat_native_dir_token:
	.dw 0x0000
fat_native_identity_name:
	.dw 0x0000
fat_native_identity_cwd:
	.dw 0x0000
fat_native_name0:
	.ds 11
fat_native_name1:
	.ds 11
fat_native_cwd0:
	.ds (2 + 16 * FS2_NAME_BYTES)
fat_native_cwd1:
	.ds (2 + 16 * FS2_NAME_BYTES)

FAT_BDOS_STATE_END:
