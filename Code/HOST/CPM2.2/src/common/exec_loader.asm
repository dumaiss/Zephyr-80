; Protected destructive loader used by ZephyrShell through private BDOS 219.
;
; The C shell opens and validates the native file, builds its page-zero FCBs
; and command tail, and passes a function-218-style READ descriptor.  This
; routine copies that descriptor into common memory before the first chunk can
; overwrite the shell.  Every read is one 512-byte FS2 transfer through the
; existing native staging buffer.  The handle is closed before control moves
; to 0100h.  Errors close the handle and warm boot; the partially overwritten
; shell is never resumed.

	.globl zexec_loader_entry,ZEXEC_LOADER_START,ZEXEC_LOADER_END
	.globl fac_de,zexec_native_call,WBOOT

	.area CODE (ABS)
	.org CBIOS_EXEC_LOADER_BASE

ZEXEC_LOADER_START:
zexec_loader_entry:
	ld hl,(fac_de)
	ld de,#FAC_SFCB_BUF
	ld bc,#ZNATIVE_DESC_BYTES
	ldir
	ld de,#0x0100
zexec_read_loop:
	push de
	call zexec_native_call
	pop de
	or a
	jr nz,zexec_failed
	ld bc,(FAC_SFCB_BUF + ZNATIVE_OFF_RESULT)
	ld a,b
	or c
	jr z,zexec_start
	ld hl,#FAC_BULK_BUF
	ldir
	jr zexec_read_loop

zexec_start:
	ld a,#ZNATIVE_CLOSE
	ld (FAC_SFCB_BUF + ZNATIVE_OFF_OP),a
	call zexec_native_call
	; A raw CP/M program may return with RET.  Give it a WBOOT return word in
	; the protected top of common memory; z88dk programs replace SP themselves.
	ld sp,#ZEXEC_CHILD_STACK_TOP
	ld hl,#WBOOT
	push hl
	jp 0x0100

zexec_failed:
	ld a,#ZNATIVE_CLOSE
	ld (FAC_SFCB_BUF + ZNATIVE_OFF_OP),a
	call zexec_native_call
	jp WBOOT

ZEXEC_LOADER_END:

	.ifgt (ZEXEC_LOADER_END - ZEXEC_LOADER_START) - (CBIOS_EXEC_LOADER_LIMIT - CBIOS_EXEC_LOADER_BASE)
	.error 1
	.endif
