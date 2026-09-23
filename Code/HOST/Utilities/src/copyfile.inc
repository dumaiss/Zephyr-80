; Shared copy body for MV.COM and CP.COM.
;
; Both need the same thing -- open the source, create the destination, move it
; a record at a time, close -- and it is the part where a mistake loses a
; file, so it lives in one place rather than in two that would drift.
;
; The including file builds fcb (source) and fcb2 (destination), provides
; recbuf, and defines the BDOS equates.  Every failing path returns before the
; source has been touched, which is what lets MV delete only on success.
;
; Out: A = 0, or COPY_ERR_* naming the step that failed.

COPY_ERR_OPEN  = 1
COPY_ERR_MAKE  = 2
COPY_ERR_WRITE = 3
COPY_ERR_READ  = 4
COPY_ERR_CLOSE = 5

copy_file:
	ld c,#BDOS_OPEN
	ld de,#fcb
	call BDOS
	cp #4
	jr c,copy_opened
	ld a,#COPY_ERR_OPEN
	ret
copy_opened:
	ld c,#BDOS_MAKE
	ld de,#fcb2
	call BDOS
	cp #4
	jr c,copy_loop
	ld a,#COPY_ERR_MAKE
	ret
copy_loop:
	ld de,#recbuf
	ld c,#BDOS_SETDMA
	call BDOS
	ld c,#BDOS_READ_SEQ
	ld de,#fcb
	call BDOS
	or a
	jr nz,copy_eof
	ld c,#BDOS_WRITE_SEQ
	ld de,#fcb2
	call BDOS
	or a
	jr z,copy_loop
	ld a,#COPY_ERR_WRITE
	ret
copy_eof:
	cp #1				; 1 is end of file; anything else is an error
	jr z,copy_finish
	ld a,#COPY_ERR_READ
	ret
copy_finish:
	ld c,#BDOS_CLOSE
	ld de,#fcb2
	call BDOS
	cp #4
	jr c,copy_ok
	ld a,#COPY_ERR_CLOSE
	ret
copy_ok:
	xor a
	ret
