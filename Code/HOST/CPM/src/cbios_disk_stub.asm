; Disk-related CP/M CBIOS stubs.
;
; These are placeholders until Zephyr-80 storage exists. Future storage will
; likely be reached through the I/O controller, but no disk I/O is attempted
; here.

; HOME
; Move selected disk to track 0. Stub: no effect.
home:
	ret

; SELDSK
; Input: C = disk number.
; Output: HL = Disk Parameter Header, or 0000h on select failure.
; Stub: no disks exist yet.
seldsk:
	ld hl,#0x0000
	ret

; SETTRK
; Input: BC = track number. Stub: ignored.
settrk:
	ret

; SETSEC
; Input: BC = sector number. Stub: ignored.
setsec:
	ret

; SETDMA
; Input: BC = DMA address for future disk I/O.
setdma:
	ld (cbios_dma_addr),bc
	ret

; READ
; Output: A = 00h success, nonzero error. Stub: fail until storage exists.
read:
	ld a,#BIOS_ERR
	ret

; WRITE
; Output: A = 00h success, nonzero error. Stub: fail until storage exists.
write:
	ld a,#BIOS_ERR
	ret

; SECTRAN
; Input: BC = logical sector, DE = translation table address.
; Output: HL = translated sector. Stub: identity translation.
sectran:
	ld h,b
	ld l,c
	ret

