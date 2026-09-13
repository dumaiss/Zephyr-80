; SDDEL.COM — delete a file from the controller's /SHARED/ folder.
;
;   SDDEL NAME.EXT
;
; One command, no bulk phase.  The controller builds the path itself under
; /SHARED/ and rejects anything carrying a separator, so this cannot be aimed at
; the boot images in /CPM/ however the argument is spelled -- which matters
; here more than anywhere else, since this is the one tool that destroys
; something.

	.module sddel
	.area CODE (ABS)
	.org 0x0100

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	call have_name
	jr nz,del_named
	ld de,#msg_noname
	call puts
	ld a,#1
	ret
del_named:

	ld hl,#FCB1 + 1
	call print_name
	call crlf

	call zero_frames
	ld a,#CMD_FS_DELETE
	ld (tx_frame + 0),a
	ld a,#11
	ld (tx_frame + 3),a
	ld e,#4
	call put_fcb_name
	ld a,#RSP_FS_DELETE
	call fs_xact
	jr nz,fail

	ld de,#msg_done
	call puts
	xor a
	ret

fail:
	call print_fail
	ld a,#1
	ret

msg_banner:	.ascii "SDDEL: $"
msg_done:	.ascii "deleted"
		.db 13,10,'$'

	.include "sdfs.inc"
	.include "zbdos.inc"		; IOCALL/IOCBULK/IOCBULKW, which sdfs.inc calls
