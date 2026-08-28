; Local Zephyr-80 banking BIOS extensions.
;
; This module is owned by the CPM2.2 port and implements the extended BIOS
; ABI exposed after ZBIOS_EXT_BASE.
;
; These services are core BIOS, not drivers. CP/M storage paths depend on a
; single authoritative view of CURRENT_BANK, DMA_BANK, and pending XMOVE
; state. A replaceable device driver may call these services, but must not
; own the bank latch policy.

	.globl MOVE,XMOVE,SELMEM,SETBNK
	.globl BIOS_CODE_END
	.globl BANKING_CODE_START,BANKING_CODE_END
	.globl BANKING_STATE_START,BANKING_STATE_END
	.globl SAVED_BANK,DMA_BANK,XMOVE_SRC_BANK,XMOVE_DST_BANK,XMOVE_PENDING
	.globl MOVE_BUFFER
	.globl CURRENT_BANK,cbios_dma_addr
	.globl WBOOT,FBASE
	
	.globl ctc_disable_interrupts,ioc_diag_capture
	.globl ioc_bulk_synced
	.globl ioc_rx_synced,ioc_link_ready
	.globl IOC_DIAG_RR0,IOC_DIAG_RR1,IOC_DIAG_SYNCED,IOC_DIAG_READY
	.globl IOC_DIAG_SCANLEFT
	.globl IOC_DIAG_B0,IOC_DIAG_B1,IOC_DIAG_B2,IOC_DIAG_B3
	.globl IOC_DIAG_B4,IOC_DIAG_B5,IOC_DIAG_B6,IOC_DIAG_B7,IOC_DIAG_BIDX
	.globl IOC_DIAG_BULK_REASON,IOC_DIAG_BULK_COUNT
	.globl IOC_DIAG_BULK_B0,IOC_DIAG_BULK_HEADER
	.globl IOC_DIAG_BULK_RR0,IOC_DIAG_BULK_RR1,IOC_DIAG_BULK_SYNCED
	.globl IOC_DIAG_BULK_EXPECT_LEN,IOC_DIAG_BULK_EXPECT_TYPE
	.globl IOC_DIAG_BULK_EXPECT_SEQ

	.area CODE (ABS)
	.org CBIOS_BANKING_CODE_BASE

BANKING_CODE_START:

; SELMEM
; Purpose:
;   Select the active RAM-only execution/data bank.
; Input:
;   A = target RAM bank.
; Output:
;   CURRENT_BANK and the hardware bank latch are updated.
; Clobbers:
;   AF. Preserves BC, DE, HL, IX, IY.
SELMEM:
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

; SETBNK
; Purpose:
;   Record the bank containing the next CP/M disk DMA buffer.
; Input:
;   A = future disk DMA bank.
; Output:
;   DMA_BANK updated; the active hardware bank is unchanged.
; Clobbers:
;   AF. Preserves BC, DE, HL, IX, IY.
SETBNK:
	and #BANK_MASK
	ld (DMA_BANK),a
	ret

; XMOVE
; Purpose:
;   Arm the next MOVE as a cross-bank transfer.
; Input:
;   C = source bank, B = destination bank.
; Output:
;   XMOVE_SRC_BANK, XMOVE_DST_BANK, and XMOVE_PENDING updated.
; Clobbers:
;   AF. Preserves BC, DE, HL, IX, IY.
XMOVE:
	ld a,c
	and #BANK_MASK
	ld (XMOVE_SRC_BANK),a
	ld a,b
	and #BANK_MASK
	ld (XMOVE_DST_BANK),a
	ld a,#0x01
	ld (XMOVE_PENDING),a
	ret

; MOVE
; Purpose:
;   Copy BC bytes from DE to HL. With no pending XMOVE, this is a same-bank
;   LDIR. With XMOVE_PENDING set, bytes are copied between two banks via the
;   common MOVE_BUFFER scratch area.
; Inputs:
;   BC = byte count, DE = source address, HL = destination address.
; Outputs:
;   Same-bank move leaves LDIR results in BC/DE/HL. Cross-bank move restores the
;   original active bank and clears XMOVE_PENDING.
; Clobbers:
;   AF, BC, DE, HL. Preserves IX, IY.
; Important invariants:
;   MOVE_BUFFER is scratch, not persistent state. C000h-C3FFh is protected
;   common TPA and remains application-owned; this routine does not reserve it.
MOVE:
	ld a,(XMOVE_PENDING)
	or a
	jr nz,MOVE_CROSS_BANK
	ld a,b
	or c
	ret z
	ldir
	ret

MOVE_CROSS_BANK:
	; Snapshot the foreground bank and pointers, then copy in chunks no larger
	; than MOVE_BUFFER_SIZE so the common scratch buffer is the only bridge.
	ld a,(CURRENT_BANK)
	ld (SAVED_BANK),a
	ld (MOVE_SRC_PTR),de
	ld (MOVE_DST_PTR),hl
	ld (MOVE_REMAIN),bc

MOVE_CROSS_LOOP:
	ld hl,(MOVE_REMAIN)
	ld a,h
	or l
	jr z,MOVE_CROSS_DONE

	ld a,h
	or a
	jr nz,MOVE_CROSS_FULL_CHUNK
	ld b,#0x00
	ld c,l
	jr MOVE_CROSS_HAVE_CHUNK

MOVE_CROSS_FULL_CHUNK:
	ld bc,#MOVE_BUFFER_SIZE

MOVE_CROSS_HAVE_CHUNK:
	ld (MOVE_CHUNK_LEN),bc

	ld a,(XMOVE_SRC_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld hl,(MOVE_SRC_PTR)
	ld de,#MOVE_BUFFER
	ld bc,(MOVE_CHUNK_LEN)
	ldir
	ld (MOVE_SRC_PTR),hl

	ld a,(XMOVE_DST_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ld hl,#MOVE_BUFFER
	ld de,(MOVE_DST_PTR)
	ld bc,(MOVE_CHUNK_LEN)
	ldir
	ld (MOVE_DST_PTR),de

	ld hl,(MOVE_REMAIN)
	ld de,(MOVE_CHUNK_LEN)
	or a
	sbc hl,de
	ld (MOVE_REMAIN),hl
	jr MOVE_CROSS_LOOP

MOVE_CROSS_DONE:
	xor a
	ld (XMOVE_PENDING),a
	ld a,(SAVED_BANK)
	and #BANK_MASK
	ld (CURRENT_BANK),a
	or #ROMDIS_BIT
	out (BANK_PORT),a
	ret

BANKING_CODE_END:

	.area WORK (ABS)
	.org CBIOS_BANK_WORK_AREA
BANKING_STATE_START:
SAVED_BANK:
	.db 0x00
DMA_BANK:
	.db 0x00
XMOVE_SRC_BANK:
	.db 0x00
XMOVE_DST_BANK:
	.db 0x00
XMOVE_PENDING:
	.db 0x00
MOVE_SRC_PTR:
	.dw 0x0000
MOVE_DST_PTR:
	.dw 0x0000
MOVE_REMAIN:
	.dw 0x0000
MOVE_CHUNK_LEN:
	.dw 0x0000
BANKING_STATE_END:

	.area CODE (ABS)

; ---------------------------------------------------------------------------
; Overflow area: routines relocated out of full core-BIOS regions.
;
; Physically after the banking module only because the free bytes happen to be
; here; nothing below belongs to banking.  Keep entries small, self-contained,
; and referenced by .globl so they can move again without touching callers.
; ---------------------------------------------------------------------------
	.area CODE (ABS)
	.org CBIOS_SPARE_CODE_BASE

; Reset all Z80 CTC channels with interrupt enable clear.  Relocated from
; cbios_boot.asm to free three bytes there for the IOCALL link bring-up call.
ctc_disable_interrupts:
	ld a,#CTC_RESET_DISABLE
	out (CTC0_CTRL),a
	out (CTC1_CTRL),a
	out (CTC2_CTRL),a
	out (CTC3_CTRL),a
	ret

	.area CODE (ABS)
	.org CBIOS_IOC_DIAG_BASE
IOC_DIAG_RR0:		.db 0
IOC_DIAG_RR1:		.db 0
IOC_DIAG_SYNCED:	.db 0
IOC_DIAG_READY:		.db 0
; Scan budget REMAINING when the reply timed out.  SIO_COMMAND_REPLY_SCAN_LIMIT
; minus this is how many bytes actually arrived before the link went quiet, and
; that separates "the reply never came" from "the reply came and the marker was
; missed" -- which need opposite fixes.
IOC_DIAG_SCANLEFT:	.db 0
; First eight bytes the reply scan actually saw, and the index used to fill
; them.  If the character boundary is wrong A5h/5Ah and the following header
; appear bit-rotated.  Nothing else distinguishes "wrong alignment" from
; "wrong bytes" when the marker is never accepted.
IOC_DIAG_B0:		.db 0
IOC_DIAG_B1:		.db 0
IOC_DIAG_B2:		.db 0
IOC_DIAG_B3:		.db 0
IOC_DIAG_B4:		.db 0
IOC_DIAG_B5:		.db 0
IOC_DIAG_B6:		.db 0
IOC_DIAG_B7:		.db 0
IOC_DIAG_BIDX:		.db 0

; Bounded SIO1/A receive rejection trace.  Error 02 otherwise merges "marker
; absent" with every header-field mismatch, which makes a scope the only way
; to distinguish character alignment from bad metadata.  On marker exhaustion
; COUNT is the scan limit and B0 is the last byte considered; B1..B7 are
; reserved.  HEADER is populated after the complete wire stream is drained.
IOC_DIAG_BULK_REASON:	.db 0
IOC_DIAG_BULK_COUNT:	.db 0
IOC_DIAG_BULK_B0:	.db 0
			.ds 7
IOC_DIAG_BULK_HEADER:	.ds 5
IOC_DIAG_BULK_RR0:	.db 0
IOC_DIAG_BULK_RR1:	.db 0
IOC_DIAG_BULK_SYNCED:	.db 0
IOC_DIAG_BULK_EXPECT_LEN:	.dw 0
IOC_DIAG_BULK_EXPECT_TYPE:	.db 0
IOC_DIAG_BULK_EXPECT_SEQ:	.db 0

; Record why a reply never arrived.  In: B = unused scan budget.
; Clobbers AF only, so the caller's error code is still its own to set.
ioc_diag_capture:
	ld a,b
	ld (IOC_DIAG_SCANLEFT),a
	xor a
	out (SIO_COMMAND_CTRL_PORT),a	; point at RR0
	in a,(SIO_COMMAND_CTRL_PORT)
	ld (IOC_DIAG_RR0),a
	ld a,#0x01
	out (SIO_COMMAND_CTRL_PORT),a	; point at RR1
	in a,(SIO_COMMAND_CTRL_PORT)
	ld (IOC_DIAG_RR1),a
	ld a,(ioc_rx_synced)
	ld (IOC_DIAG_SYNCED),a
	ld a,(ioc_link_ready)
	ld (IOC_DIAG_READY),a
	ret

; Set once the bulk lane has completed a CRC-verified transfer, which is the
; only evidence its character boundary was established.  Cleared by LINK_SYNC.
; Lives here rather than in slot 4, which is full to the byte.
ioc_bulk_synced:	.db 0
