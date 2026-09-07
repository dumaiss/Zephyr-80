; VOLINFO.COM — what is actually mounted on each storage unit.
;
;   VOLINFO
;
; Read-only, one command per unit, no bulk phase.  This exists because the
; controller can address a CP/M volume two different ways -- the raw card, or an
; 8 MiB file on a FAT card -- and without this the mode has to be INFERRED from
; whether the disk looks right, which is the slowest possible way to find out
; that an image failed to mount and the firmware quietly fell back to raw.
;
; Reported rather than guessed:
;
;   mode      file / raw / none
;   name      the image file, packed 8.3, blank in raw mode
;   base      absolute card LBA of the volume's first block
;   extents   contiguous runs the image occupies; 1 is a clean copy
;   records   volume length in 128-byte CP/M records

	.module volinfo
	.area CODE (ABS)
	.org 0x0100

CMD_VOL_INFO	= 0x11
RSP_VOL_INFO	= 0x91

VOL_UNITS	= 2

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	xor a
	ld (unit),a
	ld (guard_shown),a

unit_loop:
	call zero_frames
	ld a,#CMD_VOL_INFO
	ld (tx_frame + 0),a
	ld a,#1
	ld (tx_frame + 3),a		; payload length = 1 (unit)
	ld a,(unit)
	ld (tx_frame + 4),a
	ld a,#RSP_VOL_INFO
	call fs_xact
	jp nz,fail

	; ---- boot guard, once ----
	;
	; Printed before the units because it changes what they mean: a unit in
	; raw mode with the guard tripped has not been told there is no
	; filesystem, it has been told not to look.
	ld a,(guard_shown)
	or a
	jr nz,skip_guard
	ld a,#1
	ld (guard_shown),a

	ld a,(rx_frame + 4 + 23)	; consecutive unsettled boots
	or a
	jr z,guard_clean
	ld de,#msg_resets
	call puts
	ld (dec_val),a
	xor a
	ld (dec_val + 1),a
	ld (dec_val + 2),a
	ld (dec_val + 3),a
	call print_dec32
	call crlf
guard_clean:
	ld a,(rx_frame + 4 + 24)	; last reset was a stack overflow
	or a
	jr z,no_stkrst
	ld de,#msg_stkrst
	call puts
no_stkrst:
	ld a,(rx_frame + 4 + 22)	; guard tripped: degraded
	or a
	jr z,skip_guard
	ld de,#msg_degraded
	call puts
skip_guard:

	; ---- unit ----
	ld de,#msg_unit
	call puts
	ld a,(unit)
	add a,#'0'
	call conout

	; ---- mode ----
	ld de,#msg_mode
	call puts
	ld a,(rx_frame + 5)
	cp #2
	jp z,mode_file
	cp #1
	jp z,mode_raw
	ld de,#msg_none
	call puts
	jp next_unit
mode_raw:
	ld de,#msg_raw
	call puts
	jp show_geometry
mode_file:
	ld de,#msg_file
	call puts
	ld de,#msg_name
	call puts
	ld hl,#rx_frame + 15
	call print_name

show_geometry:
	; ---- base LBA ----
	ld de,#msg_base
	call puts
	ld hl,#rx_frame + 7
	ld de,#dec_val
	ld bc,#4
	ldir
	call print_dec32

	; ---- extents ----
	ld de,#msg_ext
	call puts
	ld a,(rx_frame + 6)
	ld (dec_val),a
	xor a
	ld (dec_val + 1),a
	ld (dec_val + 2),a
	ld (dec_val + 3),a
	call print_dec32

	; A single extent is a file copied onto a freshly formatted card.  More
	; than one still works; the cap is sixteen, and a file past that is
	; refused at mount rather than mis-addressed.
	ld a,(rx_frame + 6)
	cp #1
	jp z,ext_clean
	ld de,#msg_frag
	call puts
ext_clean:

	; ---- records ----
	ld de,#msg_recs
	call puts
	ld hl,#rx_frame + 11
	ld de,#dec_val
	ld bc,#4
	ldir
	call print_dec32

next_unit:
	call crlf
	ld a,(unit)
	inc a
	ld (unit),a
	cp #VOL_UNITS
	jp c,unit_loop
	xor a
	ret

fail:
	call print_fail
	ld a,#1
	ret

msg_banner:	.ascii "VOLINFO: storage units"
		.db 13,10,'$'
msg_unit:	.ascii "  unit $"
msg_mode:	.ascii "  $"
msg_none:	.ascii "not mounted$"
msg_raw:	.ascii "raw card$"
msg_file:	.ascii "file$"
msg_name:	.ascii " /CPM/$"
msg_base:	.ascii "  base $"
msg_ext:	.ascii "  extents $"
msg_frag:	.ascii " (fragmented)$"
msg_recs:	.ascii "  records $"
msg_resets:	.ascii "WARNING: consecutive bad boots: $"
msg_stkrst:	.ascii "WARNING: last reset was a HARDWARE STACK overflow"
		.db 13,10,'$'
msg_degraded:	.ascii "DEGRADED: image mounting disabled by the boot guard"
		.db 13,10,'$'

unit:		.ds 1
guard_shown:	.ds 1

	.include "sdfs.inc"
