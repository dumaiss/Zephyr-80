; ZFWPROB.COM -- locate where a FAT write wedges the machine.
;
; ZFW freezes on its first writable open and the host never returns, so there
; is no status byte to read afterwards and no failure record to consult.  This
; walks the writable path one controller operation at a time, printing the
; label of each step BEFORE issuing it and flushing the console, so the last
; line on screen names the operation that did not come back.
;
; Usage: ZFWPROB <name>, where <name> is an EXISTING file on the FAT-backed
; drive -- ZFW.COM itself will do.  That file is only ever opened, never
; written to or truncated.  The steps that must create or truncate use
; ZFWPROB.TMP, which this program owns.
;
; The steps are ordered by how much of FatFs's writable half they reach:
;
;   open update        FA_READ|FA_WRITE on a file that already exists.  No
;                      cluster allocation, no directory mutation, nothing
;                      written -- the cheapest possible writable open.
;   open create new    dir_register(): allocates a directory entry and a
;                      cluster chain, and writes both back through the SD
;                      cache.  This is what ZFW's "create new" does.
;   open create always Re-opens an existing file and truncates it: touches the
;                      allocation half without needing a new directory entry.
;
; Safe to run repeatedly.  ZFWPROB.TMP survives the run because FS2 has no
; DELETE yet, so on every run after the first the create-new step legitimately
; finds the file already there; that is reported as "exists", not a failure.
;
; Whichever of those three is the last line printed is the operation to blame,
; and the three of them fail for quite different reasons.

	.module zfwprob
	.area CODE (ABS)
	.org 0x0100

BDOS = 0x0005
BDOS_CONOUT = 2
BDOS_PRINT = 9
BDOS_CONST = 11
BDOS_GET_DRIVE = 25
FCB1 = 0x005c
CMDTAIL = 0x0080
FAT_FCB_DRIVE = 2		; B:, one-based as FCB1 stores it

CMD_FS2_CAPS = 0x30
RSP_FS2_CAPS = 0xb0
IOC_OFF_CMD = 0
IOC_OFF_STATUS = 2
IOC_OFF_LEN = 3
IOC_OFF_PAYLOAD = 4
IOC_FRAME_BYTES = 32

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld a,(CMDTAIL)
	or a
	jr z,usage
	call validate_drive
	jr z,probe
	ld de,#txt_drive
	jp finish
usage:
	ld de,#txt_usage
	jp finish

probe:
	ld hl,#FCB1 + 1
	ld de,#name_user
	ld bc,#11
	ldir
	ld de,#txt_banner
	call print

	; 1: the capability word, through IOCALL.  If this is wrong nothing below
	; means anything, and it is the only step that avoids function 218.
	ld de,#s_caps
	call step_begin
	call check_caps
	push af
	ld de,#txt_caps
	call print
	ld a,(caps_flags + 1)
	call print_hex
	ld a,(caps_flags)
	call print_hex
	ld de,#txt_space
	call print
	pop af
	call step_end

	; 2-4: the proven read-only path, to show the link is healthy before any
	; writable command is issued.
	ld de,#s_stat
	call step_begin
	ld hl,#name_user
	call stat_name
	push af
	ld de,#txt_size
	call print
	ld a,(desc + ZN_POSITION + 1)
	call print_hex
	ld a,(desc + ZN_POSITION)
	call print_hex
	ld de,#txt_space
	call print
	pop af
	call step_end

	ld de,#s_open_read
	call step_begin
	ld hl,#name_user
	ld a,#ZN_OPEN_READ
	call open_name
	call step_end

	ld de,#s_close1
	call step_begin
	call close_step

	; 5: the cheapest writable open there is.  Reaching this and stopping means
	; the problem is not allocation.
	ld de,#s_open_update
	call step_begin
	ld hl,#name_user
	ld a,#ZN_OPEN_UPDATE
	call open_name
	call step_end

	ld de,#s_close2
	call step_begin
	call close_step

	; 6: dir_register plus cluster allocation -- what ZFW stopped on.
	ld de,#s_create_new
	call step_begin
	ld hl,#name_temp
	ld a,#ZN_OPEN_CREATE_NEW
	call open_name
	call step_end_exists

	ld de,#s_close3
	call step_begin
	call close_step

	; 7: truncate an existing file: allocation without directory growth.
	ld de,#s_create_always
	call step_begin
	ld hl,#name_temp
	ld a,#ZN_OPEN_CREATE_ALWAYS
	call open_name
	call step_end

	ld de,#s_close4
	call step_begin
	call close_step

	ld de,#txt_done
finish:
	call print
	ld sp,(entry_sp)
	ret

; DE = label.  Printed and FLUSHED before the operation runs: the console
; holds a print run until CONST or CONIN releases it, and a step that never
; returns would otherwise never appear on screen at all.
step_begin:
	call print
	ld c,#BDOS_CONST
	jp BDOS

; A = status.
step_end:
	or a
	jr nz,step_end_fail
	ld de,#txt_ok
	jr step_end_out
step_end_fail:
	push af
	ld de,#txt_fail
	call print
	pop af
	call print_hex
	ld de,#txt_crlf
step_end_out:
	call print
	ld c,#BDOS_CONST
	jp BDOS

; A = status.  42h is a pass for a step whose file is allowed to exist
; already, which is what makes this program re-runnable.
step_end_exists:
	or a
	jr z,step_end
	cp #ZN_ERR_EXISTS
	jr nz,step_end
	ld de,#txt_exists
	call print
	xor a
	jr step_end

; Close the handle the previous step opened, or say plainly that there was
; none.  A close reported as 48h because the open before it failed says
; nothing about close.
close_step:
	ld a,(h_probe)
	or a
	jr z,close_step_none
	call close_handle
	jp step_end
close_step_none:
	ld de,#txt_skipped
	call print
	ld c,#BDOS_CONST
	jp BDOS

print:
	ld c,#BDOS_PRINT
	jp BDOS

validate_drive:
	ld c,#BDOS_GET_DRIVE
	call BDOS
	inc a
	cp #FAT_FCB_DRIVE
	ret

op_begin:
	push bc
	ld hl,#desc
	ld b,#ZN_DESC_BYTES
	xor a
op_begin_loop:
	ld (hl),a
	inc hl
	djnz op_begin_loop
	ld a,#ZN_API_VERSION
	ld (desc + ZN_VERSION),a
	pop bc
	ret

set_name:
	push bc
	ld de,#desc + ZN_NAME
	ld bc,#11
	ldir
	pop bc
	ret

; HL = packed name.
stat_name:
	push hl
	call op_begin
	pop hl
	call set_name
	ld a,#ZN_STAT
	jr do_op

; A = mode, HL = packed name.  Records the handle on success.
open_name:
	ld (t_mode),a
	push hl
	call op_begin
	pop hl
	call set_name
	ld a,(t_mode)
	ld (desc + ZN_FLAGS),a
	ld a,#ZN_OPEN
	call do_op
	jr nz,open_name_failed
	ld a,(desc + ZN_HANDLE)
	ld (h_probe),a
	xor a
	ret
open_name_failed:
	push af
	xor a
	ld (h_probe),a
	pop af
	ret

; A = handle.
close_handle:
	ld (t_mode),a
	call op_begin
	ld a,(t_mode)
	ld (desc + ZN_HANDLE),a
	ld a,#ZN_CLOSE
do_op:
	ld (desc + ZN_OP),a
	ld de,#desc
	jp zb_native

; Out: A = 0 writable controller, 1 no usable CAPS reply, 2 no write support.
check_caps:
	ld hl,#tx_frame
	ld b,#IOC_FRAME_BYTES
	call zero_frame
	ld hl,#rx_frame
	ld b,#IOC_FRAME_BYTES
	call zero_frame
	ld a,#CMD_FS2_CAPS
	ld (tx_frame + IOC_OFF_CMD),a
	xor a
	ld (tx_frame + IOC_OFF_LEN),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,check_caps_link
	ld a,(rx_frame + IOC_OFF_CMD)
	cp #RSP_FS2_CAPS
	jr nz,check_caps_link
	ld a,(rx_frame + IOC_OFF_STATUS)
	or a
	jr nz,check_caps_link
	ld hl,(rx_frame + IOC_OFF_PAYLOAD + 2)
	ld (caps_flags),hl
	ld a,l
	and #0x40
	jr z,check_caps_read_only
	xor a
	ret
check_caps_read_only:
	ld a,#2
	ret
check_caps_link:
	ld a,#1
	ret

zero_frame:
	xor a
zero_frame_loop:
	ld (hl),a
	inc hl
	djnz zero_frame_loop
	ret

print_hex:
	push af
	rra
	rra
	rra
	rra
	call print_nibble
	pop af
print_nibble:
	and #0x0f
	add a,#0x90
	daa
	adc a,#0x40
	daa
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

s_caps:          .ascii "1 caps            $"
s_stat:          .ascii "2 stat            $"
s_open_read:     .ascii "3 open read       $"
s_close1:        .ascii "4 close           $"
s_open_update:   .ascii "5 open update     $"
s_close2:        .ascii "6 close           $"
s_create_new:    .ascii "7 open create new $"
s_close3:        .ascii "8 close           $"
s_create_always: .ascii "9 open create alw $"
s_close4:        .ascii "10 close          $"

txt_banner: .ascii "ZFWPROB: locating the writable step that hangs\r\n$"
txt_caps:   .ascii "caps=$"
txt_size:   .ascii "size=$"
txt_space:  .ascii " $"
txt_ok:     .ascii "ok\r\n$"
txt_exists: .ascii "exists, $"
txt_skipped: .ascii "skipped (no handle)\r\n$"
txt_fail:   .ascii "FAIL $"
txt_crlf:   .ascii "\r\n$"
txt_done:   .ascii "all steps returned\r\n$"
txt_drive:  .ascii "ZFWPROB must run on the FAT-backed drive\r\n$"
txt_usage:  .ascii "Usage: ZFWPROB <existing file>  (e.g. ZFWPROB ZFW.COM)\r\n$"

name_temp:  .ascii "ZFWPROB TMP"

entry_sp:    .dw 0
caps_flags:  .dw 0
t_mode:      .db 0
h_probe:     .db 0
name_user:   .ds 11
desc:        .ds 32
tx_frame:    .ds IOC_FRAME_BYTES
rx_frame:    .ds IOC_FRAME_BYTES
	.ds 128
stack_top:

	.include "zbdos.inc"
