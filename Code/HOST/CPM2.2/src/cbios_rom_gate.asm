; Zephyr-80 ROM service gate.
;
; Phase 2 of docs/Zephyr80_Executable_ROM_Service_Architecture.md: the resident
; half of the executable-ROM mechanism.  ROM_GATE takes a service number, makes
; ROM page 4 visible at 0000h-BFFFh, calls a fixed entry inside it, and puts the
; machine back exactly as it found it.
;
; The whole architecture rests on one property of MEM_DECODER.pld: in
; shadow/copy mode, reads of 0000h-BFFFh come from the selected ROM page while
; C000h-FFFFh stays SRAM bank 0, and WRITES below C000h still reach the selected
; SRAM bank.  Reads are replaced; writes are not.
;
; Four things this routine has to get right, in order:
;
;   The stack.  A CP/M caller's SP is in the TPA, which is about to become ROM.
;   PUSH would still write SRAM, but POP would read ROM and return rubbish.  So
;   SP moves into the common window before the latch is touched, and every ROM
;   service runs on CBIOS_ROM_GATE_STACK_TOP.
;
;   The latch.  Saved by reading the port back, not by consulting CURRENT_BANK,
;   which records BIOS intent rather than hardware state.  The bank bits are
;   carried through unchanged so the service sees the caller's bank, and the
;   page and mode bits are replaced.
;
;   The service's results.  Restoring the latch needs A, and A is where a
;   service returns its answer.  PUSH AF / POP AF around the OUT is on the gate
;   stack, which is common RAM and addressable in both memory modes.
;
;   The caller's interrupt state.  Restored, never assumed: a transient may have
;   called in with interrupts off, and forcing EI on the way out would turn its
;   DI into a hard-to-find intermittent fault.
;
; Interrupts are disabled for the duration.  That is a Phase 2 scaffold, not the
; shipping behaviour -- see the interrupt section of the architecture note.  A
; service is currently trivial and the window is a few dozen T-states; a real
; console service will need the resident interrupt layer before it can hold a
; DI this long.

	.include "romsvc_abi.inc"

	.globl ROM_GATE
	.globl ROM_GATE_CODE_START,ROM_GATE_CODE_END
	.globl ROM_GATE_STATE_START,ROM_GATE_STATE_END
	.globl rom_gate_caller_sp,rom_gate_saved_latch
	.globl rom_gate_saved_iff,rom_gate_service

	.area CODE (ABS)
	.org CBIOS_ROM_GATE_CODE_BASE
ROM_GATE_CODE_START:

; ---------------------------------------------------------------------------
; ROM_GATE
;
; In:  A  = ROM service number (see romsvc_abi.inc)
;      BC/DE/HL = per-service arguments
; Out: per-service.  BC, DE and HL pass through to the service and back
;      untouched by the gate itself.
; Clobbers: AF, and whatever the service clobbers.
; Interrupts: disabled across the call, restored to the caller's state on exit.
; Virtual Drip traffic: none.
; ---------------------------------------------------------------------------
ROM_GATE:
	ld (rom_gate_service),a
	ld (rom_gate_caller_sp),sp
	ld sp,#CBIOS_ROM_GATE_STACK_TOP

	; Decide whether this service can run with interrupts left enabled.
	;
	; Blanket DI was the Phase 2 scaffold, and it does not survive contact
	; with the console: v9958_fill_cells and the scroll path busy-wait on the
	; V9958 command engine for whole-screen operations, which is milliseconds.
	; Holding DI that long overruns the SIO0/B receive FIFO -- a failure this
	; machine has already produced from the IOC lane, for the same reason.
	;
	; Interrupts are safe during a ROM service when the interrupt will vector
	; somewhere that is still mapped.  In IM2 that is decided by the vector
	; page in the I register:
	;
	;   I >= C0h   the table is in the common window, and so is the handler
	;              it points at.  The BIOS runs I = DDh.  Leave interrupts
	;              alone; the ISR runs normally, on the gate stack.
	;
	;   I <  C0h   the table is in the TPA, which is ROM for the duration.
	;              An application installed it.  Disable, and accept the
	;              latency: the alternative is vectoring into ROM.
	;
	; LD A,I yields both halves of the decision at once -- A is the vector
	; page, P/V is IFF2.  On NMOS parts P/V is cleared erroneously if an
	; interrupt is accepted during the instruction; the error only ever
	; reports "disabled" for a machine that was enabled, so the read is
	; repeated and either sighting of P/V is taken as proof.  A is unaffected
	; by the erratum.
	;
	; What this does not cover: IM1, where an interrupt vectors to 0038h in
	; the hidden TPA.  There is no instruction to read the interrupt mode, so
	; the gate cannot test for it.  The BIOS owns IM2 and sets it at boot;
	; the service page carries a landing pad at 0038h so that an application
	; that switched to IM1 and then called a ROM service is a lost interrupt
	; rather than a jump into the middle of a lookup table.
	ld a,i
	jp pe,rom_gate_iff_on
	ld a,i
	jp pe,rom_gate_iff_on

	; Caller had interrupts off.  Nothing to restore, nothing to disable.
	xor a
	ld (rom_gate_saved_iff),a
	jr rom_gate_latch

rom_gate_iff_on:
	; A is the vector page.  Test it before overwriting A: LD does not
	; affect flags, so the carry from this CP survives the two instructions
	; that record the interrupt state, which saves a PUSH/POP pair in a
	; region with five bytes to spare.
	cp #0xc0
	ld a,#0x01
	ld (rom_gate_saved_iff),a
	jr nc,rom_gate_latch		; vector table is common: leave EI
	di

rom_gate_latch:
	; Read the latch back rather than trusting a software copy, keep the
	; caller's bank bits, and replace page and mode.
	;
	; With interrupts possibly live from here, the ISR will run on the gate
	; stack and with ROM mapped low.  Both are fine: the SIO core ISR, its
	; IM2 table entry and the sinks it dispatches to are all above C000h.
	in a,(BANK_PORT)
	ld (rom_gate_saved_latch),a
	and #BANK_MASK
	or #((ROMSVC_PAGE << ROM_PAGE_SHIFT) | SHADOW_BIT)
	out (BANK_PORT),a

	; Low memory is ROM from here until the latch is restored.  Everything
	; touched between these two OUTs -- this code, the stack, the state bytes
	; below -- is above C000h for that reason.
	ld a,(rom_gate_service)
	call ROMSVC_ENTRY

	push af
	ld a,(rom_gate_saved_latch)
	out (BANK_PORT),a
	pop af

	ld sp,(rom_gate_caller_sp)

	push af
	ld a,(rom_gate_saved_iff)
	or a
	jr z,rom_gate_leave_di
	pop af
	ei				; harmless if they were never disabled
	ret
rom_gate_leave_di:
	pop af
	ret

ROM_GATE_CODE_END:

	.area WORK (ABS)
	.org CBIOS_ROM_GATE_WORK_AREA
ROM_GATE_STATE_START:
rom_gate_caller_sp:
	.dw 0x0000
rom_gate_saved_latch:
	.db 0x00
rom_gate_saved_iff:
	.db 0x00
rom_gate_service:
	.db 0x00
ROM_GATE_STATE_END:

	.area CODE (ABS)
