; SYSID.COM — report which CP/M system is actually running.
;
; Zephyr-80 can carry a stock DRI CCP or ZCPR2, and a stock BDOS or ZSDOS, in
; any combination.  The ROM image is built by selecting them, and for a while
; nothing in the build output said which combination a given file held -- so a
; machine could be running something other than what its operator believed, and
; the only symptoms were subtle (a command-line feature quietly absent).
;
; This reads the running system out of RAM rather than inferring it, which is
; the point: it reports what is EXECUTING, not what someone meant to flash.
;
; The three probes:
;
;   BDOS   The six bytes ahead of FBASE, the BDOS entry page zero's 0005h jump
;          names, are CP/M's serial-number field, and a
;          replacement BDOS stamps its identity there -- ZSDOS writes 'ZSDOS '
;          and ZDDOS writes 'ZDDOS '.  Stock CP/M leaves a binary serial, so
;          "all six printable" is a reliable discriminator.  This prints them
;          verbatim when they are text, so a BDOS this program has never heard
;          of still identifies itself.
;
;   CCP    No equivalent stamp exists, so the resident command table is used.
;          ZCPR2 has JUMP and GET; stock CP/M 2.2 has USER and neither of the
;          others.  Searching the 2 KiB slot for those names distinguishes them
;          without depending on a build-specific entry address -- which would
;          change whenever ZCPR2 is reassembled with different options.
;
;   BIOS   The transport level, from Zephyr BDOS function 203.  Printed raw;
;          comparing it is IOC_LEVELS' job, not this program's.
;
; The CCP slot is the 800h bytes below the serial.  Nothing is at a fixed
; address: the banked OS publishes none.
;
; Reads memory and calls only BDOS console output.  Nothing here touches the IO
; Controller, so it works when the link is dead -- which is when the question
; "what am I actually running?" tends to be asked.

	.module sysid
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09

CCP_SIZE	= 0x0800

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	ld hl,(BDOS + 1)		; FBASE
	ld de,#-6
	add hl,de
	ld (bdos_serial),hl
	ld de,#-CCP_SIZE
	add hl,de
	ld (ccp_base),hl
	call main
	ld sp,(entry_sp)
	ret

main:
	ld de,#msg_banner
	call puts

	; ---- CCP ----
	ld de,#msg_ccp
	call puts
	ld hl,#pat_jump
	call find_in_ccp
	jr z,ccp_zcpr2
	ld hl,#pat_user
	call find_in_ccp
	jr z,ccp_stock
	ld de,#msg_unknown
	call puts
	jr ccp_done
ccp_zcpr2:
	ld de,#msg_zcpr2
	call puts
	jr ccp_done
ccp_stock:
	ld de,#msg_dri
	call puts
ccp_done:
	call crlf

	; ---- BDOS ----
	ld de,#msg_bdos
	call puts
	call serial_is_text
	jr nz,bdos_stock
	; Printable: the BDOS names itself.  Print the six bytes as they are.
	ld hl,(bdos_serial)
	ld b,#6
bdos_name:
	ld a,(hl)
	call conout
	inc hl
	djnz bdos_name
	jr bdos_done
bdos_stock:
	ld de,#msg_dri
	call puts
bdos_done:
	call crlf

	; ---- BIOS transport level ----
	ld de,#msg_xport
	call puts
	call zb_xport_level
	call print_hex_byte
	call crlf

	xor a
	ret

; ---------------------------------------------------------------------------
; Search the CCP slot for the 4-character name at HL.  Z if found.
;
; Four characters, because that is the width of ZCPR2's command table entries
; and it is long enough that a chance match in arbitrary code is unlikely.
; ---------------------------------------------------------------------------
find_in_ccp:
	ld (pat_ptr),hl
	ld hl,(ccp_base)
	ld bc,#CCP_SIZE - 4
fic_next:
	push bc
	push hl
	ld de,(pat_ptr)
	ld b,#4
fic_cmp:
	ld a,(de)
	cp (hl)
	jr nz,fic_miss
	inc hl
	inc de
	djnz fic_cmp
	pop hl
	pop bc
	xor a				; Z: found
	ret
fic_miss:
	pop hl
	pop bc
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,fic_next
	or #0xff			; NZ: not found
	ret

; ---------------------------------------------------------------------------
; Z when all six serial bytes are printable ASCII.
;
; A stock CP/M serial contains zero bytes, so this separates "the BDOS wrote its
; name here" from "this is a serial number" without knowing either in advance.
; ---------------------------------------------------------------------------
serial_is_text:
	ld hl,(bdos_serial)
	ld b,#6
sit_loop:
	ld a,(hl)
	cp #0x20
	jr c,sit_no
	cp #0x7f
	jr nc,sit_no
	inc hl
	djnz sit_loop
	xor a				; Z: all printable
	ret
sit_no:
	or #0xff
	ret

puts:
	ld c,#BDOS_PRINT
	jp BDOS

crlf:
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	jp BDOS

conout:
	push hl
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
	pop hl
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call print_hex_nibble
	pop af
print_hex_nibble:
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	jp conout

pat_jump:	.ascii "JUMP"
pat_user:	.ascii "USER"

msg_banner:	.ascii "SYSID: running system"
		.db 13,10,'$'
msg_ccp:	.ascii "  CCP   $"
msg_bdos:	.ascii "  BDOS  $"
msg_xport:	.ascii "  BIOS  transport level $"
msg_zcpr2:	.ascii "ZCPR2$"
msg_dri:	.ascii "CP/M 2.2 (DRI)$"
msg_unknown:	.ascii "unrecognised$"
msg_crlf:	.db 13,10,'$'

pat_ptr:	.ds 2
bdos_serial:	.ds 2
ccp_base:	.ds 2

entry_sp:	.ds 2
	.ds 64
stack_top:

	.include "zbdos.inc"
