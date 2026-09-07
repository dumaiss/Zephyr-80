; Shared layout of the BIOS IOC link failure record.
;
; The BIOS fills a compact record at a fixed address describing the last
; transport failure on either lane.  It sits at a fixed address so a .COM can
; read it when the link is too broken to answer a PING -- that is the whole
; reason it is not simply a field in a reply.
;
; Track this against its authority:
;   Code/HOST/CPM2.2/src/cbios_defs.inc  -- FROZEN: IOC link failure record
;
; These offsets were previously open-coded in every tool that read the block:
; ioc_ping.asm carried its own IOC_DIAG_BASE and read +0..+13 by hand, while
; ioc_sdrec.asm and ioc_sdsoak.asm each hard-coded nine absolute addresses in
; the DCCEh-DCE3h range.  Three private copies of one layout is how a field
; moves and two of the three keep printing the old meaning.
;
; VERSION GATE.  This layout is governed by ZBIOS_XPORT_LEVEL, read from
; ZBIOS_XPORT_LEVEL_ADDR (see ioc_levels.inc).  A tool MUST check that the
; running BIOS reports at least IOC_DIAG_RECORD_MIN_XPORT_LEVEL before
; decoding these offsets, and say so plainly rather than printing fields it
; cannot vouch for.  The record carries no version byte of its own.

IOC_DIAG_BASE			= 0xDCC0
IOC_DIAG_SIZE			= 0x10

; The transport level at which this record layout became current.  A BIOS
; reporting less than this has the old 36-byte block and different offsets.
IOC_DIAG_RECORD_MIN_XPORT_LEVEL	= 0x08

; Field addresses.  The record describes THE LAST FAILURE, on the lane named
; at +01h.  A field means nothing without the STATUS and LANE beside it.
; LANE and BULK_REASON are adjacent, and so are READY and SYNCED, because the
; BIOS writes each pair with one 16-bit store.  The order is not cosmetic and
; tools/check_diag_record.py in the CPM2.2 project fails the build if this file
; and cbios_defs.inc disagree about any of it.
IOC_DIAG_STATUS			= IOC_DIAG_BASE + 0x00	; IOC_XPORT_*, 00 = none
IOC_DIAG_LANE			= IOC_DIAG_BASE + 0x01
IOC_DIAG_BULK_REASON		= IOC_DIAG_BASE + 0x02
IOC_DIAG_RR0			= IOC_DIAG_BASE + 0x03	; bit 4 set = still hunting
IOC_DIAG_RR1			= IOC_DIAG_BASE + 0x04
IOC_DIAG_READY			= IOC_DIAG_BASE + 0x05
IOC_DIAG_SYNCED			= IOC_DIAG_BASE + 0x06
IOC_DIAG_BULK_SYNCED		= IOC_DIAG_BASE + 0x07
IOC_DIAG_SEQ			= IOC_DIAG_BASE + 0x08
IOC_DIAG_BULK_TYPE		= IOC_DIAG_BASE + 0x09
IOC_DIAG_BULK_SEQ		= IOC_DIAG_BASE + 0x0A
IOC_DIAG_BULK_STATUS		= IOC_DIAG_BASE + 0x0B
IOC_DIAG_RESERVED		= IOC_DIAG_BASE + 0x0C	; 4 bytes, read as zero

; Lane codes for IOC_DIAG_LANE.
IOC_DIAG_LANE_COMMAND		= 0x00		; SIO1/B
IOC_DIAG_LANE_BULK		= 0x01		; SIO1/A

; Bulk rejection stages for IOC_DIAG_BULK_REASON.
IOC_BULK_REASON_NONE		= 0x00
IOC_BULK_REASON_INPUT		= 0x01		; invalid caller length
IOC_BULK_REASON_MARKER		= 0x02		; A5 5A never found in the scan
IOC_BULK_REASON_LEN		= 0x03
IOC_BULK_REASON_TYPE		= 0x04
IOC_BULK_REASON_SEQ		= 0x05
IOC_BULK_REASON_STATUS		= 0x06		; header carried nonzero status
IOC_BULK_REASON_CRC		= 0x07
