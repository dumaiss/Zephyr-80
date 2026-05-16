; Monitor context snapshot routine used by the R command.
;
; The monitor records its own working registers after each command line is read.
; This is not a trap frame and does not describe an interrupted user program.
; PC is therefore intentionally unavailable in the R command output.

; Save the monitor's current working context for the R command.
; This is monitor state, not an interrupted user program context. PC is omitted.
; Input: current monitor register state.
; Output: REG_*_SAVE workspace fields updated; HL restored to entry value.
; Clobbers: memory at REG_*_SAVE.
save_monitor_context:
	ld (REG_HL_SAVE),hl
	ld (REG_BC_SAVE),bc
	ld (REG_DE_SAVE),de
	ld (REG_IX_SAVE),ix
	ld (REG_IY_SAVE),iy
	push af
	pop hl
	ld (REG_AF_SAVE),hl
	; At entry, the return address for this call is on the stack. Add two so
	; the saved SP reports the caller's stack position rather than the temporary
	; stack position inside save_monitor_context.
	ld hl,#0
	add hl,sp
	inc hl
	inc hl
	ld (REG_SP_SAVE),hl
	ld hl,(REG_HL_SAVE)
	ret
