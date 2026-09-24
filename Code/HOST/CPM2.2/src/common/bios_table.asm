; The reset vector and the CP/M BIOS jump table, both common memory.
; These are published addresses: page zero and the ZCPR2 build are made against
; CBIOS_BASE, so the order and position of these entries is ABI.
; Split out of zephyr.asm so the assembly root carries the include order and
; nothing else.


	.area RESET (ABS)
	.org 0x0000
reset_vector:
	jp cpm_rom_entry_high

; CP/M BIOS jump table, common memory.
;
; This table serves programs running in mode 10.  The order is the CP/M 2.2
; ABI.  Programs find the table through page zero's JP WBOOT, and ZCPR2, which
; calls BIOS+6 and BIOS+9 directly, is assembled against its address
; (zcpr2/build-zcpr2.sh, from CBIOS_BASE).
;
; Only boot and the console are live (plan F6).  CONST, CONIN and CONOUT are
; gates into the bank 7 console.  The disk and auxiliary entries are inert: the
; disk structures live in bank 7, and ZSDOS uses its own table there.
;
; ZBIOS_EXT_BASE is the Zephyr extension table immediately after it:
;   MOVE / XMOVE / SELMEM / SETBNK   bank primitives, common code
;   IOCALL / VIDEO_SEND /            gates into bank 7 that stage the caller's
;   IOCBULK / IOCBULKW               buffers through common memory
; It is not published: programs reach these eight as BDOS functions 210-217
; (cbios_facade.asm), which call through it.
	.area CODE (ABS)
	.org CBIOS_BASE

BIOS_CODE_START:
BOOT:
	jp boot
WBOOT:
	jp wboot
CONST:
	jp gate_const
CONIN:
	jp gate_conin
CONOUT:
	jp gate_conout
LIST:
	jp bios_inert_ret
PUNCH:
	jp bios_inert_ret
READER:
	jp bios_inert_reader
HOME:
	jp bios_inert_ret
SELDSK:
	jp bios_inert_seldsk
SETTRK:
	jp bios_inert_ret
SETSEC:
	jp bios_inert_ret
SETDMA:
	jp bios_inert_ret
READ:
	jp bios_inert_error
WRITE:
	jp bios_inert_error
LISTST:
	jp bios_inert_listst
SECTRAN:
SECTRN:
	jp bios_inert_sectran
ZBIOS_EXT_BASE:
	jp MOVE
	jp XMOVE
	jp SELMEM
	jp SETBNK
	jp gate_iocall
	jp gate_video_send
	jp gate_iocbulk
	jp gate_iocbulkw

