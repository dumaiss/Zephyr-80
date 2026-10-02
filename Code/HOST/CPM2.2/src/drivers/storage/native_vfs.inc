; Function-218 provider router.  The native FAT/FS2 backend remains the root
; provider; this layer contributes the synthetic /SYSTEM directory and its
; read-only A child.  Existing FAT handles remain owned by fat_native_entry.

native_vfs_entry:
	ld (cpm_vfs_desc),de
	push de
	pop hl
	ld a,(hl)
	cp #ZNATIVE_VERSION
	jp nz,native_vfs_fat
	inc hl
	ld a,(hl)

	; An empty CHDIR is the native root operation used for absolute paths.
	cp #ZNATIVE_CHDIR
	jr nz,native_vfs_handle_ops
	call native_vfs_name
	ld a,(hl)
	or a
	jr z,native_vfs_root
	cp #' '
	jr nz,native_vfs_handle_ops
native_vfs_root:
	xor a
	ld (cpm_vfs_cwd),a
	ld (cpm_vfs_root_pending),a
	jp native_vfs_fat

native_vfs_handle_ops:
	cp #ZNATIVE_CLOSE
	jr z,native_vfs_file_handle
	cp #ZNATIVE_READ
	jr z,native_vfs_file_handle
	cp #ZNATIVE_SEEK
	jr z,native_vfs_file_handle
	cp #ZNATIVE_TELL
	jr z,native_vfs_file_handle
	cp #ZNATIVE_WRITE
	jr z,native_vfs_file_handle
	cp #ZNATIVE_SYNC
	jr z,native_vfs_file_handle
	cp #ZNATIVE_TRUNCATE
	jr z,native_vfs_file_handle
	cp #ZNATIVE_READDIR
	jr z,native_vfs_dir_handle
	cp #ZNATIVE_CLOSEDIR
	jr z,native_vfs_dir_handle
	jr native_vfs_namespace

native_vfs_file_handle:
	call native_vfs_handle
	cp #0x80
	jp z,cpm_mount_file_dispatch
	jp native_vfs_fat

native_vfs_dir_handle:
	call native_vfs_handle
	cp #0x80
	jp z,cpm_mount_dir_dispatch
	; A physical root iterator emits the mount point before FS2 entries.
	ld a,(cpm_vfs_root_pending)
	or a
	jr z,native_vfs_dir_fat
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_READDIR
	jr nz,native_vfs_dir_close
	xor a
	ld (cpm_vfs_root_pending),a
	ld hl,#cpm_component_system
	jp native_vfs_emit_dir
native_vfs_dir_close:
	xor a
	ld (cpm_vfs_root_pending),a
native_vfs_dir_fat:
	jp native_vfs_fat

native_vfs_namespace:
	ld a,(cpm_vfs_cwd)
	or a
	jp nz,native_vfs_mounted

	; Only the native provider's root receives the synthetic SYSTEM entry.
	call fat_effective_cwd_count
	or a
	jp nz,native_vfs_fat
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_OPENDIR
	jr z,native_vfs_root_opendir
	cp #ZNATIVE_READDIR
	jr z,native_vfs_dir_handle
	cp #ZNATIVE_CLOSEDIR
	jr z,native_vfs_dir_handle
	cp #ZNATIVE_CHDIR
	jr z,native_vfs_root_chdir
	cp #ZNATIVE_STAT
	jr z,native_vfs_root_stat
	cp #ZNATIVE_OPEN
	jr z,native_vfs_root_open
	cp #ZNATIVE_MKDIR
	jr z,native_vfs_root_mkdir
	cp #ZNATIVE_DELETE
	jr z,native_vfs_root_read_only
	cp #ZNATIVE_RENAME
	jr z,native_vfs_root_rename
	cp #ZNATIVE_RMDIR
	jr z,native_vfs_root_read_only
	jp native_vfs_fat

native_vfs_root_opendir:
	call native_vfs_fat
	or a
	ret nz
	ld a,#1
	ld (cpm_vfs_root_pending),a
	ret

native_vfs_root_chdir:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jp nz,native_vfs_fat
	ld a,#1
	ld (cpm_vfs_cwd),a
	xor a
	jp native_vfs_return

native_vfs_root_stat:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jp nz,native_vfs_fat
	jp native_vfs_emit_stat_dir

native_vfs_root_open:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jp nz,native_vfs_fat
	ld a,#FS2_STATUS_IS_DIR
	jp native_vfs_return

native_vfs_root_mkdir:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jp nz,native_vfs_fat
	ld a,#FS2_STATUS_EXISTS
	jp native_vfs_return

native_vfs_root_rename:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jr z,native_vfs_root_read_only_status
	ld hl,#cpm_component_system
	call native_vfs_name2_eq
	jp nz,native_vfs_fat
	jr native_vfs_root_read_only_status

native_vfs_root_read_only:
	ld hl,#cpm_component_system
	call native_vfs_name_eq
	jp nz,native_vfs_fat
native_vfs_root_read_only_status:
	ld a,#FS2_STATUS_READ_ONLY
	jp native_vfs_return

native_vfs_mounted:
	ld hl,(cpm_vfs_desc)
	inc hl
	ld a,(hl)
	cp #ZNATIVE_CWD
	jp z,cpm_mount_cwd
	cp #ZNATIVE_SPACE
	jp z,cpm_mount_space
	cp #ZNATIVE_SPACE_KIB
	jp z,cpm_mount_space
	cp #ZNATIVE_OPENDIR
	jp z,cpm_mount_opendir
	cp #ZNATIVE_CDUP
	jr z,native_vfs_cdup
	cp #ZNATIVE_CHDIR
	jr z,native_vfs_chdir
	cp #ZNATIVE_STAT
	jr z,native_vfs_stat
	cp #ZNATIVE_OPEN
	jr z,native_vfs_open
	cp #ZNATIVE_DELETE
	jr z,native_vfs_read_only
	cp #ZNATIVE_RENAME
	jr z,native_vfs_read_only
	cp #ZNATIVE_MKDIR
	jr z,native_vfs_read_only
	cp #ZNATIVE_RMDIR
	jr z,native_vfs_read_only
	ld a,#FS2_STATUS_NOT_FOUND
	jp native_vfs_return

native_vfs_cdup:
	ld a,(cpm_vfs_cwd)
	dec a
	ld (cpm_vfs_cwd),a
	xor a
	jp native_vfs_return

native_vfs_chdir:
	ld a,(cpm_vfs_cwd)
	cp #1
	jr nz,native_vfs_not_dir
	ld hl,#cpm_component_a
	call native_vfs_name_eq
	jr nz,native_vfs_not_found
	ld a,#2
	ld (cpm_vfs_cwd),a
	xor a
	jp native_vfs_return
native_vfs_not_dir:
	ld a,#FS2_STATUS_NOT_DIR
	jp native_vfs_return
native_vfs_not_found:
	ld a,#FS2_STATUS_NOT_FOUND
	jp native_vfs_return

native_vfs_stat:
	ld a,(cpm_vfs_cwd)
	cp #1
	jp nz,cpm_mount_stat
	ld hl,#cpm_component_a
	call native_vfs_name_eq
	jr nz,native_vfs_not_found
	jp native_vfs_emit_stat_dir

native_vfs_open:
	ld a,(cpm_vfs_cwd)
	cp #1
	jp nz,cpm_mount_open
	ld hl,#cpm_component_a
	call native_vfs_name_eq
	jr nz,native_vfs_not_found
	ld a,#FS2_STATUS_IS_DIR
	jp native_vfs_return

native_vfs_read_only:
	ld a,#FS2_STATUS_READ_ONLY
	jp native_vfs_return

native_vfs_handle:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_HANDLE
	add hl,de
	ld a,(hl)
	ret

native_vfs_name:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_NAME
	add hl,de
	ret

; HL = packed component, result Z when it equals the descriptor name.
native_vfs_name_eq:
	ex de,hl
	push de
	call native_vfs_name
	pop de
	jr native_vfs_name_compare
native_vfs_name2_eq:
	ex de,hl
	ld hl,(cpm_vfs_desc)
	ld bc,#ZNATIVE_OFF_NAME2
	add hl,bc
native_vfs_name_compare:
	ld b,#FS2_NAME_BYTES
native_vfs_name_eq_loop:
	ld a,(de)
	cp (hl)
	ret nz
	inc de
	inc hl
	djnz native_vfs_name_eq_loop
	ret

native_vfs_emit_stat_dir:
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_FLAGS
	add hl,de
	ld (hl),#FS2_ATTR_DIR
	ld hl,(cpm_vfs_desc)
	ld de,#ZNATIVE_OFF_POSITION
	add hl,de
	ld b,#4
native_vfs_zero_position:
	ld (hl),#0
	inc hl
	djnz native_vfs_zero_position
	xor a
	jp native_vfs_return

; HL = packed component.  Emit one synthetic directory entry.
native_vfs_emit_dir:
	push hl
	call native_vfs_emit_stat_dir
	pop hl
	push hl
	call native_vfs_name
	ex de,hl
	pop hl
	ld bc,#FS2_NAME_BYTES
	ldir
	xor a
	jp native_vfs_return

; Restore the descriptor register before every handoff to the FAT provider.
; Router helpers use DE for descriptor offsets and packed-name comparisons.
native_vfs_fat:
	ld de,(cpm_vfs_desc)
	jp fat_native_entry

native_vfs_return:
	ld hl,(cpm_vfs_desc)
	inc hl
	inc hl
	ld (hl),a
	ret
