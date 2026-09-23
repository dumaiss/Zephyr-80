; RMDIR.COM -- remove an empty directory from the FAT-backed volume.
;
; Reports plainly on a fixed-geometry CP/M volume, which has no directories to
; remove.  A directory that still holds files is refused by the controller;
; that surfaces as a status, not as a silent partial delete.
;
; Usage: RMDIR NAME

	.module rmdir
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
FCB1 = 0x005c
CMDTAIL = 0x0080
FAT_DRIVE = 1				; B:, zero-based as BDOS 25 reports it

	.include "dirop.inc"

dir_op:     .db ZN_RMDIR
txt_usage:  .ascii "Usage: RMDIR NAME\r\n$"
txt_ok:     .ascii "Directory removed\r\n$"
txt_failed: .ascii "RMDIR failed: $"

	.include "zbdos.inc"
