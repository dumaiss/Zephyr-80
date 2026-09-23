; MKDIR.COM -- create a directory on the FAT-backed volume.
;
; A fixed-geometry CP/M volume has no directories at all, so this reports that
; plainly rather than pretending: the drive cannot hold what is being asked
; for, and STAT-style user areas are a different idea.
;
; Usage: MKDIR NAME

	.module mkdir
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_PRINT = 9
BDOS_GET_DRIVE = 25
FCB1 = 0x005c
CMDTAIL = 0x0080
FAT_DRIVE = 1				; B:, zero-based as BDOS 25 reports it

	.include "dirop.inc"

dir_op:     .db ZN_MKDIR
txt_usage:  .ascii "Usage: MKDIR NAME\r\n$"
txt_ok:     .ascii "Directory created\r\n$"
txt_failed: .ascii "MKDIR failed: $"

	.include "zbdos.inc"
