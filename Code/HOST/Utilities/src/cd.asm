; CD.COM -- select a directory in the FAT-backed B: namespace.
;
; Usage: CD GAMES, CD B8:GAMES, or CD B8: to select the USER root.
; Bare CD selects the current USER root when the caller is already on B:.
; CD .. steps one level up.  That case is recognised from the command tail,
; not from FCB1: the CP/M name parser stops the name at the first '.', so the
; CCP hands this program eleven spaces for "..", which is exactly what it
; hands it for a bare CD.  The untouched tail is the only place the two can
; still be told apart.
; Repeated calls traverse a hierarchy.  The bank-7 CWD survives transient
; program exit and drive changes; warm boot preserves the selected directory.

	.module cd
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
BDOS_USER = 32
FCB1 = 0x005c
CMDTAIL = 0x0080
CMDTEXT = 0x0081
FAT_FCB_DRIVE = 2		; B:, one-based as FCB1 stores it

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld hl,#desc
	ld b,#32
	xor a
clear_desc:
	ld (hl),a
	inc hl
	djnz clear_desc
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	ld a,#ZN_CHDIR
	ld (desc + ZN_OP),a
	; ZCPR leaves no reliable sentinel in FCB1 for a bare command.  Its command
	; tail length is authoritative: zero means select the USER root.
	ld a,(CMDTAIL)
	or a
	jr z,prepare_target
	call tail_is_dotdot
	jr nz,copy_name
	ld a,#ZN_CDUP
	ld (desc + ZN_OP),a
	jr prepare_target
copy_name:
	ld hl,#FCB1 + 1
	ld de,#desc + ZN_NAME
	ld bc,#11
	ldir
prepare_target:
	ld e,#0xff
	ld c,#BDOS_USER
	call BDOS
	and #0x1f
	cp #16
	jr nc,bad_target
	ld (saved_user),a
	ld (target_user),a
	xor a
	ld (user_switched),a
	call validate_drive
	jr nz,bad_target
	call parse_target_user
	jr nz,bad_target
	call apply_target_user
	ld de,#desc
	call zb_native
	ld (native_status),a
	call restore_user
	ld a,(native_status)
	or a
	jr nz,failed
	ld de,#ok_text
	jr print
bad_target:
	ld de,#target_text
	jr print
failed:
	ld de,#fail_text
print:
	ld c,#BDOS_PRINT
	call BDOS
	; ZCPR invokes transients with CALL 0100h.  Restore that entry stack and
	; return directly so ZCPR performs its normal post-program cleanup.
	ld sp,(entry_sp)
	ret

; The native service is specific to the FAT drive.  An explicit B: is
; accepted from any caller drive; an omitted drive only while B: is current.
validate_drive:
	ld a,(FCB1)
	or a
	jr nz,validate_explicit_drive
	ld c,#BDOS_GET_DRIVE
	call BDOS
	inc a				; BDOS is zero-based; FCB drives are one-based
validate_explicit_drive:
	cp #FAT_FCB_DRIVE
	ret

; Z when the command tail names "..", ignoring a leading drive prefix so that
; CD B8:.. works the same way.
tail_is_dotdot:
	ld hl,#CMDTEXT
dotdot_skip:
	ld a,(hl)
	cp #' '
	jr nz,dotdot_prefix
	inc hl
	jr dotdot_skip
dotdot_prefix:
	push hl
	call skip_drive_prefix
	ld a,(hl)
	cp #'.'
	jr nz,dotdot_no
	inc hl
	ld a,(hl)
	cp #'.'
	jr nz,dotdot_no
	inc hl
	ld a,(hl)
	or a
	jr z,dotdot_yes
	cp #' '
	jr nz,dotdot_no
dotdot_yes:
	pop hl
	xor a
	ret
dotdot_no:
	pop hl
	ld a,#1
	or a
	ret

; HL past a leading "B:" or "B8:" style prefix, or unchanged when there is none.
skip_drive_prefix:
	push hl
dotdot_scan:
	ld a,(hl)
	or a
	jr z,dotdot_scan_none
	cp #' '
	jr z,dotdot_scan_none
	cp #':'
	jr z,dotdot_scan_found
	inc hl
	jr dotdot_scan
dotdot_scan_found:
	inc hl
	pop af				; discard the saved start
	ret
dotdot_scan_none:
	pop hl
	ret

; ZCPR records the drive and packed name in FCB1, but keeps the USER from a
; DU: prefix only in its private temporary state.  Recover USER 0..15 from the
; untouched command tail.  A token without a colon remains a relative name.
parse_target_user:
	ld a,(CMDTAIL)
	or a
	ret z
	ld hl,#CMDTEXT
parse_skip_spaces:
	ld a,(hl)
	cp #' '
	jr nz,parse_prefix
	inc hl
	jr parse_skip_spaces
parse_prefix:
	and #0xdf
	cp #'B'
	jr nz,parse_possible_user
	inc hl
	ld a,(hl)
	cp #':'
	ret z				; B: uses the caller's USER
parse_possible_user:
	ld a,(hl)
	sub #'0'
	cp #10
	jr nc,parse_no_prefix
	ld b,a
	inc hl
	ld a,(hl)
	cp #':'
	jr z,parse_commit_user
	sub #'0'
	cp #10
	jr nc,parse_no_prefix
	ld c,a
	ld a,b
	add a,a
	add a,a
	add a,b
	add a,a				; first digit * 10
	add a,c
	ld b,a
	inc hl
	ld a,(hl)
	cp #':'
	jr nz,parse_no_prefix
parse_commit_user:
	ld a,b
	cp #16
	jr nc,parse_bad_prefix
	ld (target_user),a
	xor a
	ret
parse_no_prefix:
	xor a
	ret
parse_bad_prefix:
	ld a,#0xff
	or a
	ret

apply_target_user:
	ld a,(target_user)
	ld b,a
	ld a,(saved_user)
	cp b
	ret z
	ld a,#1
	ld (user_switched),a
	ld e,b
	ld c,#BDOS_USER
	jp BDOS

restore_user:
	ld a,(user_switched)
	or a
	ret z
	ld a,(saved_user)
	ld e,a
	ld c,#BDOS_USER
	jp BDOS

ok_text:    .ascii "Directory selected\r\n$"
fail_text:  .ascii "Cannot select directory\r\n$"
target_text: .ascii "CD target must be B0: through B15:\r\n$"
entry_sp:   .dw 0
saved_user: .db 0
target_user: .db 0
user_switched: .db 0
native_status: .db 0
desc:       .ds 32
	.ds 96
stack_top:

	.include "zbdos.inc"
