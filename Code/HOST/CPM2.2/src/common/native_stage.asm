; Function 218 caller-buffer crossing helpers and private loader call.
;
; COMMON REQUIRED: when an application is mapped, its buffer can be hidden by
; bank 7 at 2000h-BFFFh.  WRITE data must therefore be copied into the existing
; common bulk buffer before entering mode 11, and READ data copied out after
; returning.  Protocol handling, file state and all mutation policy remain in
; the bank-7 FAT backend.

	.globl native_stage_write,native_deliver_read,zexec_native_call
	.globl native_vfs_entry,xing_os_call_ix
	.globl NATIVE_STAGE_START,NATIVE_STAGE_END

	.area CODE (ABS)
	.org CBIOS_NATIVE_STAGE_BASE

NATIVE_STAGE_START:

; Copy a valid-size native WRITE payload from caller RAM to common staging.
; Invalid lengths are left unstaged; bank 7 returns FS2_STATUS_RANGE.
; Clobbers AF, BC, DE, HL.  Nonblocking, no IOC traffic, not ISR-safe.
native_stage_write:
	ld a,(FAC_SFCB_BUF + ZNATIVE_OFF_OP)
	cp #ZNATIVE_WRITE
	ret nz
	ld bc,(FAC_SFCB_BUF + ZNATIVE_OFF_LENGTH)
	ld a,b
	or c
	ret z
	ld a,b
	cp #2
	jr c,native_stage_write_copy
	ret nz
	ld a,c
	or a
	ret nz
native_stage_write_copy:
	ld hl,(FAC_SFCB_BUF + ZNATIVE_OFF_BUFFER)
	ld de,#FAC_BULK_BUF
	ldir
	ret

; Deliver a non-empty native READ result after returning to caller mapping.
; Preserves AF so the function-218 status remains the public return value.
; Clobbers BC, DE, HL.  Nonblocking, no IOC traffic, not ISR-safe.
native_deliver_read:
	push af
	ld a,(FAC_SFCB_BUF + ZNATIVE_OFF_OP)
	cp #ZNATIVE_READ
	jr nz,native_deliver_read_done
	ld bc,(FAC_SFCB_BUF + ZNATIVE_OFF_RESULT)
	ld a,b
	or c
	jr z,native_deliver_read_done
	ld hl,#FAC_BULK_BUF
	ld de,(FAC_SFCB_BUF + ZNATIVE_OFF_BUFFER)
	ldir
native_deliver_read_done:
	pop af
	ret

; Common helper for the protected destructive loader.
zexec_native_call:
	ld de,#FAC_SFCB_BUF
	push ix
	ld ix,#native_vfs_entry
	call xing_os_call_ix
	pop ix
	ret

NATIVE_STAGE_END:

	.ifgt (NATIVE_STAGE_END - NATIVE_STAGE_START) - (CBIOS_NATIVE_STAGE_LIMIT - CBIOS_NATIVE_STAGE_BASE)
	.error 1
	.endif
