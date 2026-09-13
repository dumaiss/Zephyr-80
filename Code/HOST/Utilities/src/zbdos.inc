; zbdos.inc -- the Zephyr-80 BDOS functions, for CP/M tools.
;
; The OS runs in SRAM bank 7 and publishes no fixed addresses.  A tool reaches
; it through CALL 5; ../../CPM2.2/src/cbios_facade.asm is the authority for the
; function numbers and the register block.
;
; Include this at the END of a program, after its code and data: it assembles
; code.  It provides:
;
;   IOCALL, IOCBULK, IOCBULKW, VIDEO_SEND   under their old BIOS names and
;       contracts, through BDOS functions 214-217.  The BIOS stages the caller's
;       buffers, so they can be anywhere in the program's memory.  Each returns
;       with flags set from A.
;   zb_move, zb_xmove, zb_selmem            MOVE, XMOVE and SELMEM (210-212).
;       zb_selmem changes the caller's bank: call it from common memory only.
;   zb_xport_level   A  = the BIOS IOC transport level
;   zb_diag_iy       IY = the IOC link failure record (ioc_diag_record.inc
;                         gives the field offsets)
;   zb_sercon_iy     IY = the serial console flags byte
;
; IY is safe to keep across BDOS calls: neither the facade, ZSDOS nor the BIOS
; uses it.

ZB_BDOS			= 0x0005

ZB_REGISTER_ISR		= 200		; B = CTC channel 0-3, DE = callback
ZB_UNREGISTER_ISR	= 201		; B = CTC channel
ZB_PROGRAM_EXIT		= 202
ZB_SYSINFO		= 203		; HL -> system information block
ZB_EXT_MOVE		= 210
ZB_EXT_XMOVE		= 211
ZB_EXT_SELMEM		= 212
ZB_EXT_SETBNK		= 213
ZB_EXT_IOCALL		= 214
ZB_EXT_VIDEO_SEND	= 215
ZB_EXT_IOCBULK		= 216
ZB_EXT_IOCBULKW		= 217

; Interrupt callbacks, and everything they touch, live here (8 KiB common
; memory starts at E000h; the first 1 KiB belongs to the running program).
ZB_ISR_AREA		= 0xe000
ZB_ISR_AREA_SIZE	= 0x0400

; System information block (function 203).
ZB_SYSINFO_VERSION	= 0x00		; .db 1
ZB_SYSINFO_XPORT_LEVEL	= 0x01		; .db
ZB_SYSINFO_DIAG		= 0x02		; .dw IOC link failure record
ZB_SYSINFO_SERCON	= 0x04		; .dw serial console flags byte
ZB_SYSINFO_BIOS		= 0x06		; .dw CP/M BIOS jump table
ZB_SYSINFO_EXT		= 0x08		; .dw Zephyr extension table

; IOCALL: HL = TX frame, DE = RX frame.  Out: A = status; HL, DE unchanged.
IOCALL:
	ld (zb_regs + 5),hl
	ld (zb_regs + 3),de
	ld c,#ZB_EXT_IOCALL
	jr zb_ext

; IOCBULK: HL = destination, DE = count.  Out: A = status.
IOCBULK:
	ld (zb_regs + 5),hl
	ld (zb_regs + 3),de
	ld c,#ZB_EXT_IOCBULK
	jr zb_ext

; IOCBULKW: HL = source, DE = count.  Out: A = status.
IOCBULKW:
	ld (zb_regs + 5),hl
	ld (zb_regs + 3),de
	ld c,#ZB_EXT_IOCBULKW
	jr zb_ext

; VIDEO_SEND: A = type, HL = payload, BC = length.  Out: A = status.
VIDEO_SEND:
	ld (zb_regs),a
	ld (zb_regs + 1),bc
	ld (zb_regs + 5),hl
	ld c,#ZB_EXT_VIDEO_SEND
	jr zb_ext

; zb_move: BC = count, DE = source, HL = destination.
zb_move:
	ld (zb_regs + 1),bc
	ld (zb_regs + 3),de
	ld (zb_regs + 5),hl
	ld c,#ZB_EXT_MOVE
	jr zb_ext

; zb_xmove: C = source bank, B = destination bank.  Out: A = 00h or FFh.
zb_xmove:
	ld (zb_regs + 1),bc
	ld c,#ZB_EXT_XMOVE
	jr zb_ext

; zb_selmem: A = bank.  Out: A = 00h or FFh.
zb_selmem:
	ld (zb_regs),a
	ld c,#ZB_EXT_SELMEM

; C = function 210-217, zb_regs = A, C, B, E, D, L, H in.  Out: the same
; registers as the entry left them, and flags from A.
zb_ext:
	ld de,#zb_regs
	call ZB_BDOS
	ld hl,(zb_regs + 5)
	ld de,(zb_regs + 3)
	ld bc,(zb_regs + 1)
	ld a,(zb_regs)
	or a
	ret

; A = the BIOS IOC transport level.  Preserves BC, DE, HL.
zb_xport_level:
	push bc
	push de
	push hl
	ld c,#ZB_SYSINFO
	call ZB_BDOS
	inc hl				; ZB_SYSINFO_XPORT_LEVEL
	ld a,(hl)
	pop hl
	pop de
	pop bc
	ret

; IY = the IOC link failure record.  Preserves BC, DE, HL.
zb_diag_iy:
	ld a,#ZB_SYSINFO_DIAG
	jr zb_pointer_iy

; IY = the serial console flags byte.  Preserves BC, DE, HL.
zb_sercon_iy:
	ld a,#ZB_SYSINFO_SERCON

; A = offset of a pointer in the system information block.  IY = the pointer.
zb_pointer_iy:
	push bc
	push de
	push hl
	push af
	ld c,#ZB_SYSINFO
	call ZB_BDOS
	pop af
	ld e,a
	ld d,#0
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	push de
	pop iy
	pop hl
	pop de
	pop bc
	ret

zb_regs:	.ds 7
