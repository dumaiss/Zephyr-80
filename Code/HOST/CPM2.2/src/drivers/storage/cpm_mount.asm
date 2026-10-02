; Read-only CP/M filesystem provider for function 218.
;
; The provider exposes the immutable recovery volume as /CPM/A.  It parses the
; ordinary CP/M 2.2 directory and extent allocation map in bank 7 and reads
; records through the existing ROM-disk backend; it never calls BDOS recursively.
; One A-file handle and one directory iterator may coexist with FAT handles.
;
; Public entry points are called only in OS mode through native_vfs_entry.
; They may block for a ROM record copy, emit no Virtual Drip traffic, and are
; not ISR-safe.

	.include "config.inc"
	.include "layout/platform.inc"
	.include "layout/memory.inc"

	.globl CPM_MOUNT_CODE_START,CPM_MOUNT_CODE_END
	.globl CPM_MOUNT_STATE_START,CPM_MOUNT_STATE_END
	.globl cpm_mount_reset,cpm_mount_file_dispatch,cpm_mount_dir_dispatch
	.globl cpm_mount_open,cpm_mount_stat,cpm_mount_opendir
	.globl cpm_mount_cwd,cpm_mount_space
	.globl cpm_vfs_desc,cpm_vfs_cwd,cpm_vfs_root_pending
	.globl cpm_component_a
	.globl native_vfs_return
	.globl stg_a_read,stg_a_selected_drive
	.globl stg_a_track,stg_a_sector,cbios_dma_addr

CPM_MOUNT_HANDLE	= 0x80
CPM_DIR_CPM		= 0x01
CPM_DIR_A		= 0x02
CPM_DIR_ENTRIES		= 128
CPM_RECORD_BYTES	= 128
CPM_RECORDS_PER_BLOCK	= 8
CPM_RECORDS_PER_EXTENT	= 128
CPM_RECORDS_PER_TRACK	= ROMDISK_SECTORS_PER_TRACK
CPM_RECORD_BUFFER	= CBIOS_STORAGE_DIRBUF

	.area CPMM_CODE (ABS)
	.org CBIOS_CPM_MOUNT_CODE_BASE

CPM_MOUNT_CODE_START:

cpm_mount_reset:
	xor a
	ld (cpm_vfs_cwd),a
	ld (cpm_vfs_root_pending),a
	ld (cpm_file_active),a
	ld (cpm_dir_active),a
	ld a,#0xff
	ld (cpm_dir_cache),a
	ret

; Dispatch operations on the provider's reserved file handle.
cpm_mount_file_dispatch:
	ld a,(cpm_file_active)
	or a
	jr z,cpm_file_no_handle
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_CLOSE
	jr z,cpm_file_close
	cp #ZNATIVE_READ
	jp z,cpm_file_read
	cp #ZNATIVE_SEEK
	jr z,cpm_file_seek
	cp #ZNATIVE_TELL
	jr z,cpm_file_tell
	ld a,#FS2_STATUS_READ_ONLY
	jp native_vfs_return
cpm_file_no_handle:
	ld a,#FS2_STATUS_NO_HANDLE
	jp native_vfs_return
cpm_file_close:
	xor a
	ld (cpm_file_active),a
	jp native_vfs_return
cpm_file_seek:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	ld de,#cpm_file_position
	ld bc,#4
	ldir
	xor a
	jp native_vfs_return
cpm_file_tell:
	ld hl,#cpm_file_position
	ld de,(cpm_vfs_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_POSITION
	add hl,bc
	ex de,hl
	ld bc,#4
	ldir
	xor a
	jp native_vfs_return

; Dispatch READDIR/CLOSEDIR for the provider's reserved directory handle.
cpm_mount_dir_dispatch:
	ld a,(cpm_dir_active)
	or a
	jr z,cpm_dir_no_handle
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_CLOSEDIR
	jr z,cpm_dir_close
	cp #ZNATIVE_READDIR
	jr nz,cpm_dir_no_handle
	ld a,(cpm_dir_kind)
	cp #CPM_DIR_CPM
	jp nz,cpm_a_readdir
	ld a,(cpm_dir_index)
	or a
	jr nz,cpm_dir_end
	inc a
	ld (cpm_dir_index),a
	ld hl,#cpm_component_a
	call cpm_emit_name
	ld a,#FS2_ATTR_DIR
	call cpm_emit_metadata
	xor a
	jp native_vfs_return
cpm_dir_end:
	ld a,#FS2_STATUS_END
	jp native_vfs_return
cpm_dir_close:
	xor a
	ld (cpm_dir_active),a
	jp native_vfs_return
cpm_dir_no_handle:
	ld a,#FS2_STATUS_NO_HANDLE
	jp native_vfs_return

cpm_mount_opendir:
	ld a,(cpm_dir_active)
	or a
	jr nz,cpm_dir_no_handle
	ld a,#1
	ld (cpm_dir_active),a
	ld a,(cpm_vfs_cwd)
	ld (cpm_dir_kind),a
	xor a
	ld (cpm_dir_index),a
	ld a,#0xff
	ld (cpm_dir_cache),a
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld (hl),#CPM_MOUNT_HANDLE
	inc hl
	ld (hl),#0
	xor a
	jp native_vfs_return

; Return /CPM or /CPM/A one packed component at a time.
cpm_mount_cwd:
	ld a,(cpm_vfs_cwd)
	ld c,a
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_RESULT
	add hl,de
	ld (hl),c
	inc hl
	ld (hl),#0
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld a,(hl)
	cp c
	jr nc,cpm_cwd_done
	or a
	ld hl,#fat_component_cpm_ref
	jr z,cpm_cwd_emit
	ld hl,#cpm_component_a
cpm_cwd_emit:
	call cpm_emit_name
cpm_cwd_done:
	xor a
	jp native_vfs_return

; The ROM volume is immutable: 0/147456 bytes or 0/144 whole KiB.
cpm_mount_space:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_SPACE_KIB
	jr nz,cpm_space_bytes
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_SPACE_TOTAL
	add hl,de
	ld (hl),#0x90			; 144 KiB
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	xor a
	jp native_vfs_return
cpm_space_bytes:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_SPACE_TOTAL
	add hl,de
	ld (hl),#0x00
	inc hl
	ld (hl),#0x40
	inc hl
	ld (hl),#0x02
	inc hl
	ld (hl),#0x00
	xor a
	jp native_vfs_return
cpm_mount_stat:
	call cpm_scan_descriptor
	jp nz,native_vfs_return
	call cpm_emit_scan_size
	ld a,#FS2_ATTR_RO
	call cpm_emit_flags
	xor a
	jp native_vfs_return

cpm_mount_open:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld a,(hl)
	or a
	jr nz,cpm_open_read_only
	ld a,(cpm_file_active)
	or a
	jp nz,cpm_file_no_handle
	call cpm_scan_descriptor
	jp nz,native_vfs_return
	ld hl,#cpm_scan_name
	ld de,#cpm_file_name
	ld bc,#FS2_NAME_BYTES
	ldir
	ld hl,(cpm_scan_records)
	ld (cpm_file_records),hl
	ld hl,#cpm_scan_size
	ld de,#cpm_file_size
	ld bc,#4
	ldir
	xor a
	ld (cpm_file_position),a
	ld (cpm_file_position + 1),a
	ld (cpm_file_position + 2),a
	ld (cpm_file_position + 3),a
	inc a
	ld (cpm_file_active),a
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld (hl),#CPM_MOUNT_HANDLE
	inc hl
	ld (hl),#0
	ld hl,#cpm_file_size
	call cpm_emit_size_hl
	ld a,#FS2_ATTR_RO
	call cpm_emit_flags
	xor a
	jp native_vfs_return
cpm_open_read_only:
	ld a,#FS2_STATUS_READ_ONLY
	jp native_vfs_return

; Enumerate only each file's first extent, then calculate its total record size.
cpm_a_readdir:
	ld a,(cpm_dir_index)
	cp #CPM_DIR_ENTRIES
	jp nc,cpm_dir_end
	inc a
	ld (cpm_dir_index),a
	dec a
	call cpm_get_entry
	jp nz,native_vfs_return
	ld a,(hl)
	or a
	jr nz,cpm_a_readdir
	push hl
	ld de,#12
	add hl,de
	ld a,(hl)
	and #0x1f
	jr nz,cpm_readdir_skip
	inc hl
	inc hl
	ld a,(hl)
	or a
	jr nz,cpm_readdir_skip
	pop hl
	inc hl
	ld de,#cpm_scan_name
	ld b,#FS2_NAME_BYTES
cpm_readdir_copy:
	ld a,(hl)
	and #0x7f
	ld (de),a
	inc hl
	inc de
	djnz cpm_readdir_copy
	call cpm_calculate_size
	jp nz,native_vfs_return
	ld hl,#cpm_scan_name
	call cpm_emit_name
	call cpm_emit_scan_size
	ld a,#FS2_ATTR_RO
	call cpm_emit_flags
	xor a
	jp native_vfs_return
cpm_readdir_skip:
	pop hl
	jr cpm_a_readdir

; Copy the descriptor name and total every matching USER-0 extent's RC field.
cpm_scan_descriptor:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_NAME
	add hl,de
	ld de,#cpm_scan_name
	ld bc,#FS2_NAME_BYTES
	ldir
cpm_calculate_size:
	xor a
	ld (cpm_scan_records),a
	ld (cpm_scan_records + 1),a
	ld (cpm_scan_found),a
	ld (cpm_scan_index),a
	ld a,#0xff
	ld (cpm_dir_cache),a
cpm_scan_loop:
	ld a,(cpm_scan_index)
	cp #CPM_DIR_ENTRIES
	jr nc,cpm_scan_done
	inc a
	ld (cpm_scan_index),a
	dec a
	call cpm_get_entry
	ret nz
	call cpm_entry_matches
	jr nz,cpm_scan_loop
	inc hl
	inc hl
	inc hl
	ld a,(hl)
	ld hl,(cpm_scan_records)
	ld e,a
	ld d,#0
	add hl,de
	ld (cpm_scan_records),hl
	ld a,#1
	ld (cpm_scan_found),a
	jr cpm_scan_loop
cpm_scan_done:
	ld a,(cpm_scan_found)
	or a
	jr z,cpm_scan_not_found
	ld hl,(cpm_scan_records)
	ld a,l
	and #1
	rrca
	ld (cpm_scan_size),a
	ld a,l
	srl a
	ld e,a
	ld a,h
	and #1
	rrca
	or e
	ld (cpm_scan_size + 1),a
	ld a,h
	srl a
	ld (cpm_scan_size + 2),a
	xor a
	ld (cpm_scan_size + 3),a
	ret
cpm_scan_not_found:
	ld a,#FS2_STATUS_NOT_FOUND
	or a
	ret

; HL = directory entry. Return Z only for USER 0 and cpm_scan_name.
; On success HL points to the EX byte (offset 12).
cpm_entry_matches:
	ld a,(hl)
	or a
	ret nz
	inc hl
	ld de,#cpm_scan_name
	ld b,#FS2_NAME_BYTES
cpm_match_loop:
	ld a,(hl)
	and #0x7f
	ld c,a
	ld a,(de)
	cp c
	ret nz
	inc hl
	inc de
	djnz cpm_match_loop
	ret

; Read one of the 128 directory entries and return HL = its 32-byte record.
cpm_get_entry:
	ld c,a
	and #3
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld a,c
	srl a
	srl a
	ld b,a
	ld a,(cpm_dir_cache)
	cp b
	jr z,cpm_get_entry_ptr
	push bc
	push de
	ld l,b
	ld h,#0
	call cpm_read_abs_record
	pop de
	pop bc
	ret nz
	ld a,b
	ld (cpm_dir_cache),a
cpm_get_entry_ptr:
	ld hl,#CPM_RECORD_BUFFER
	add hl,de
	xor a
	ret

; Read absolute CP/M record HL into the shared 128-byte storage directory line.
cpm_read_abs_record:
	ld b,#0
cpm_record_track_loop:
	ld de,#CPM_RECORDS_PER_TRACK
	or a
	sbc hl,de
	jr c,cpm_record_track_done
	inc b
	jr cpm_record_track_loop
cpm_record_track_done:
	add hl,de
	ld (stg_a_sector),hl
	ld l,b
	ld h,#0
	ld (stg_a_track),hl
	xor a
	ld (stg_a_selected_drive),a
	ld hl,#CPM_RECORD_BUFFER
	ld (cbios_dma_addr),hl
	call stg_a_read
	or a
	ret z
	ld a,#FS2_STATUS_IO
	or a
	ret

; Map the current byte position to one CP/M logical record and load it.
cpm_load_current_record:
	ld a,(cpm_file_position)
	and #0x7f
	ld (cpm_record_offset),a
	ld a,(cpm_file_position + 1)
	add a,a
	ld l,a
	ld a,(cpm_file_position)
	rlca
	and #1
	or l
	ld l,a
	ld a,(cpm_file_position + 2)
	add a,a
	ld h,a
	ld a,(cpm_file_position + 1)
	rlca
	and #1
	or h
	ld h,a
	ld de,(cpm_file_records)
	ld a,h
	cp d
	jr c,cpm_load_in_range
	jr nz,cpm_load_eof
	ld a,l
	cp e
	jr nc,cpm_load_eof
cpm_load_in_range:
	ld a,l
	and #0x7f
	ld (cpm_extent_record),a
	ld a,l
	rlca
	and #1
	ld c,a
	ld a,h
	add a,a
	or c
	ld (cpm_extent_number),a
	ld hl,#cpm_file_name
	ld de,#cpm_scan_name
	ld bc,#FS2_NAME_BYTES
	ldir
	xor a
	ld (cpm_scan_index),a
	ld a,#0xff
	ld (cpm_dir_cache),a
cpm_extent_scan:
	ld a,(cpm_scan_index)
	cp #CPM_DIR_ENTRIES
	jr nc,cpm_load_io
	inc a
	ld (cpm_scan_index),a
	dec a
	call cpm_get_entry
	ret nz
	call cpm_entry_matches
	jr nz,cpm_extent_scan
	ld a,(hl)
	and #0x1f
	ld c,a
	ld a,(cpm_extent_number)
	cp c
	jr nz,cpm_extent_scan
	inc hl
	inc hl
	ld a,(hl)
	or a
	jr nz,cpm_extent_scan
	inc hl
	ld a,(cpm_extent_record)
	cp (hl)
	jr nc,cpm_load_io
	inc hl
	ld a,(cpm_extent_record)
	srl a
	srl a
	srl a
	ld e,a
	ld d,#0
	add hl,de
	ld a,(hl)
	or a
	jr z,cpm_load_io
	ld l,a
	ld h,#0
	add hl,hl
	add hl,hl
	add hl,hl
	ld a,(cpm_extent_record)
	and #7
	ld e,a
	ld d,#0
	add hl,de
	ld a,#0xff
	ld (cpm_dir_cache),a
	jp cpm_read_abs_record
cpm_load_eof:
	ld a,#FS2_STATUS_END
	or a
	ret
cpm_load_io:
	ld a,#FS2_STATUS_IO
	or a
	ret

cpm_file_read:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_LENGTH
	add hl,de
	ld c,(hl)
	inc hl
	ld b,(hl)
	ld a,b
	cp #2
	jr c,cpm_read_length_ok
	jp nz,cpm_read_range
	ld a,c
	or a
	jp nz,cpm_read_range
cpm_read_length_ok:
	ld (cpm_read_remaining),bc
	xor a
	ld (cpm_read_result),a
	ld (cpm_read_result + 1),a
	ld hl,#FAC_BULK_BUF
	ld (cpm_read_dest),hl
cpm_read_loop:
	ld hl,(cpm_read_remaining)
	ld a,h
	or l
	jr z,cpm_read_done
	ld a,(cpm_file_position + 3)
	or a
	jr nz,cpm_read_done
	call cpm_load_current_record
	cp #FS2_STATUS_END
	jr z,cpm_read_done
	or a
	jp nz,native_vfs_return
	ld a,(cpm_record_offset)
	ld e,a
	ld a,#CPM_RECORD_BYTES
	sub e
	ld c,a
	ld hl,(cpm_read_remaining)
	ld a,h
	or a
	jr nz,cpm_read_have_chunk
	ld a,l
	cp c
	jr nc,cpm_read_have_chunk
	ld c,a
cpm_read_have_chunk:
	ld l,e
	ld h,#0
	ld de,#CPM_RECORD_BUFFER
	add hl,de
	ld de,(cpm_read_dest)
	ld b,#0
	push bc
	ldir
	ld (cpm_read_dest),de
	pop bc
	ld hl,(cpm_read_remaining)
	ld a,l
	sub c
	ld l,a
	ld a,h
	sbc a,#0
	ld h,a
	ld (cpm_read_remaining),hl
	ld hl,(cpm_read_result)
	ld e,c
	ld d,#0
	add hl,de
	ld (cpm_read_result),hl
	ld hl,(cpm_file_position)
	add hl,de
	ld (cpm_file_position),hl
	jr nc,cpm_read_loop
	ld hl,#cpm_file_position + 2
	inc (hl)
	jr nz,cpm_read_loop
	inc hl
	inc (hl)
	jr cpm_read_loop
cpm_read_done:
	ld hl,#cpm_read_result
	ld de,(cpm_vfs_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_RESULT
	add hl,bc
	ex de,hl
	ld bc,#2
	ldir
	xor a
	jp native_vfs_return
cpm_read_range:
	ld a,#FS2_STATUS_RANGE
	jp native_vfs_return

; Descriptor-output helpers.
cpm_emit_name:
	push hl
	ld de,(cpm_vfs_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_NAME
	add hl,bc
	ex de,hl
	pop hl
	ld bc,#FS2_NAME_BYTES
	ldir
	ret

cpm_emit_scan_size:
	ld hl,#cpm_scan_size
cpm_emit_size_hl:
	ld de,(cpm_vfs_desc)
	ex de,hl
	ld bc,#ZNATIVE_OFF_POSITION
	add hl,bc
	ex de,hl
	ld bc,#4
	ldir
	ret

cpm_emit_flags:
	push af
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	pop af
	ld (hl),a
	ret

; A = flags; size is zero.
cpm_emit_metadata:
	call cpm_emit_flags
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ret

; Packed path components.
fat_component_cpm_ref:
	.ascii "CPM     "
	.ascii "   "
cpm_component_a:
	.ascii "A       "
	.ascii "   "

CPM_MOUNT_CODE_END:

	.ifgt (CPM_MOUNT_CODE_END - CPM_MOUNT_CODE_START) - (CBIOS_CPM_MOUNT_CODE_LIMIT - CBIOS_CPM_MOUNT_CODE_BASE)
	.error 1
	.endif

	.area CPMM_WORK (ABS)
	.org CBIOS_CPM_MOUNT_STATE_BASE

CPM_MOUNT_STATE_START:
cpm_vfs_desc:
	.dw 0x0000
cpm_vfs_cwd:
	.db 0x00
cpm_vfs_root_pending:
	.db 0x00
cpm_file_active:
	.db 0x00
cpm_file_name:
	.ds FS2_NAME_BYTES
cpm_file_records:
	.dw 0x0000
cpm_file_size:
	.ds 4
cpm_file_position:
	.ds 4
cpm_dir_active:
	.db 0x00
cpm_dir_kind:
	.db 0x00
cpm_dir_index:
	.db 0x00
cpm_dir_cache:
	.db 0xff
cpm_scan_index:
	.db 0x00
cpm_scan_found:
	.db 0x00
cpm_scan_name:
	.ds FS2_NAME_BYTES
cpm_scan_records:
	.dw 0x0000
cpm_scan_size:
	.ds 4
cpm_extent_number:
	.db 0x00
cpm_extent_record:
	.db 0x00
cpm_record_offset:
	.db 0x00
cpm_read_remaining:
	.dw 0x0000
cpm_read_result:
	.dw 0x0000
cpm_read_dest:
	.dw 0x0000
CPM_MOUNT_STATE_END:

	.ifgt (CPM_MOUNT_STATE_END - CPM_MOUNT_STATE_START) - (CBIOS_CPM_MOUNT_STATE_LIMIT - CBIOS_CPM_MOUNT_STATE_BASE)
	.error 1
	.endif
