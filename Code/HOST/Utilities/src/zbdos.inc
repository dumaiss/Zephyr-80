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
ZB_NATIVE_FILE		= 218

; Function 218 descriptor, version 1.  Names are packed 8.3 components.  Paths
; are traversed with repeated ZCHDIR calls; applications never see IOC tokens.
ZN_VERSION		= 0
ZN_OP			= 1
ZN_STATUS		= 2
ZN_FLAGS		= 3		; OPEN mode in; attributes out
ZN_HANDLE		= 4
ZN_POSITION		= 6
ZN_LENGTH		= 10
ZN_BUFFER		= 12
ZN_RESULT		= 16
ZN_NAME			= 18
ZN_DESC_BYTES		= 32
ZN_API_VERSION		= 1
ZN_OPEN			= 1
ZN_CLOSE		= 2
ZN_READ			= 3
ZN_SEEK			= 4
ZN_TELL			= 5
ZN_STAT			= 6
ZN_OPENDIR		= 7
ZN_READDIR		= 8
ZN_CHDIR		= 9
ZN_WRITE		= 10
ZN_SYNC			= 11
ZN_TRUNCATE		= 12
ZN_DELETE		= 13
ZN_RENAME		= 14
ZN_MKDIR		= 15
ZN_RMDIR		= 16
; RENAME's destination name.  The descriptor has no room for a second 11-byte
; name after ZN_NAME, and RENAME uses none of POSITION/LENGTH/BUFFER/RESULT,
; so the new name goes in that span.
ZN_NAME2		= 6
ZN_OPEN_READ		= 0
ZN_OPEN_UPDATE		= 1
ZN_OPEN_CREATE_NEW	= 2
ZN_OPEN_CREATE_ALWAYS	= 3

; Function 218 status byte (ZN_STATUS).  ../../CPM2.2/src/cbios_defs.inc is the
; authority; these are the values a tool needs to tell one failure from another.
ZN_OK			= 0x00
ZN_ERR_NOT_FOUND	= 0x40
ZN_ERR_END		= 0x41
ZN_ERR_EXISTS		= 0x42
ZN_ERR_BAD_NAME		= 0x43
ZN_ERR_READ_ONLY	= 0x44
ZN_ERR_NO_SPACE		= 0x45
ZN_ERR_NOT_DIR		= 0x46
ZN_ERR_IS_DIR		= 0x47
ZN_ERR_NO_HANDLE	= 0x48
ZN_ERR_STALE		= 0x49
ZN_ERR_RANGE		= 0x4a
ZN_ERR_NO_MEDIA		= 0x4b
ZN_ERR_TRANSPORT	= 0x4c
ZN_ERR_UNKNOWN_WRITE	= 0x4d
ZN_ERR_IO		= 0x4e

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
; STORAGE_PROFILE: only read this appended pointer when version >= 2.
ZB_SYSINFO_STORAGE_PROFILE = 0x0a	; .dw two uint16 entry counters

; IOCALL: HL = TX frame, DE = RX frame.  Out: A = status; HL, DE unchanged.

; zb_native: DE -> 32-byte version-1 native-file descriptor.  The descriptor
; is copied across the bank boundary by the facade.  READ and WRITE data are
; staged through the existing 512-byte common bulk buffer.
zb_native:
	ld c,#ZB_NATIVE_FILE
	call ZB_BDOS
	or a
	ret

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
