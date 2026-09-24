; Function 218 common-memory gate.  The facade already owns a common stack.
; This gate reuses xing_os_call_ix and the existing common staging buffers.

	.globl native_gate_entry,NATIVE_GATE_START,NATIVE_GATE_END
	.globl fac_de,fac_zext_return,xing_os_call_ix,fat_native_entry
	.globl native_stage_write,native_deliver_read

	.area CODE (ABS)
	.org CBIOS_NATIVE_GATE_BASE
NATIVE_GATE_START:
native_gate_entry:
	ld hl,(fac_de)
	ld de,#FAC_SFCB_BUF
	ld bc,#ZNATIVE_DESC_BYTES
	ldir
	call native_stage_write
	ld de,#FAC_SFCB_BUF
	push ix
	ld ix,#fat_native_entry
	call xing_os_call_ix
	pop ix
native_gate_status_dispatch:
	call native_deliver_read
native_gate_copy_desc:
	ld hl,#FAC_SFCB_BUF
	ld de,(fac_de)
	ld bc,#ZNATIVE_DESC_BYTES
	ldir
	jp fac_zext_return
NATIVE_GATE_END:

	.ifgt (NATIVE_GATE_END - NATIVE_GATE_START) - (CBIOS_NATIVE_GATE_LIMIT - CBIOS_NATIVE_GATE_BASE)
	.error 1
	.endif
