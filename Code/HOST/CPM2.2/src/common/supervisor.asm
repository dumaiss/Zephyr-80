; Common half of the transient supervisor.  The policy, and all of its state,
; is in bank 7 (core/supervisor.asm).  What must be common is only what runs
; while the mapping changes: the final switch into the selected program, and
; the BDOS 219 loader's crossing into bank 7.  Neither makes a decision.

	.globl supervisor_enter_foreground,zexec_commit_close
	.globl supervisor_exec_replace_commit,xing_os_call_ix

; supervisor_enter_foreground
; Purpose:
;   Transfer control to the foreground program the supervisor selected.  The
;   last step of both BOOT and WBOOT; it carries no policy.
; Inputs:
;   Mode 11.  HL = entry point, C = argument for the entry (the CCP drive),
;   both from supervisor_cold_start or supervisor_after_teardown.
; Outputs:
;   Does not return.  Mode 10, SP = FAC_STACK_TOP; the entry resets SP.
; Important invariants:
;   The BIOS stack is in bank 7, so move to a common stack before leaving mode
;   11: an interrupt between the switch and the program setting its own stack
;   would otherwise push onto bank 0's C000h-DFFFh.
supervisor_enter_foreground:
	ld sp,#FAC_STACK_TOP
	ld a,#MEM_MODE_APPLICATION
	out (BANK_PORT),a
	jp (hl)

; zexec_commit_close
; Purpose:
;   BDOS 219's final handle close, routed through the supervisor so that it
;   records the child as the foreground transient (FG_CHILD, EXEC_REPLACE)
;   before the loader jumps to 0100h.  Same call shape as zexec_native_call.
; Inputs:
;   FAC_SFCB_BUF descriptor with op = ZNATIVE_CLOSE.  SP in common memory.
; Outputs:
;   A = close status.  IX preserved.
; Clobbers:
;   AF, BC, DE, HL.  Nonblocking, no VDP traffic, not ISR-safe.
zexec_commit_close:
	push ix
	ld ix,#supervisor_exec_replace_commit
	call xing_os_call_ix
	pop ix
	ret
