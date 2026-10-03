; Transient supervisor: the resident owner of the foreground transient.
;
; This is a SINGLE-FOREGROUND-TRANSIENT supervisor, not a scheduler.  Exactly
; one program owns the TPA at a time; there are no process IDs, no task
; switching and no resident parent.  The supervisor owns one decision:
;
;     "nothing is in the foreground -- what runs next?"
;
; Division of labour, which the code below must not blur:
;
;     BOOT        initializes the machine, then asks the supervisor.
;     WBOOT       tears down whatever a transient left behind (interrupts,
;                 devices, page zero, DMA, native handles, console), then asks
;                 the supervisor.  WBOOT stays the only CP/M exit path.
;     SUPERVISOR  decides, from a clean OS-owned machine, what runs next.  It
;                 knows nothing about the CTC, SIO, V9958 or filesystem
;                 providers; it never resets a device.
;     LOADER      BDOS 219 (common/exec_loader.asm) launches a child and tells
;                 the supervisor it has replaced the shell.
;
; Lifecycle (only EXEC_REPLACE exists):
;
;     BOOT --> supervisor_cold_start ----------+
;                                              v
;     WBOOT teardown --> supervisor_after_teardown --> launch default shell
;                                              ^          role = FG_SHELL
;     FG_SHELL --BDOS 219--> FG_CHILD          |
;     FG_CHILD --RET / BDOS 0 / JP 0000h--> WBOOT
;     FG_SHELL --RET / BDOS 0 / JP 0000h--> WBOOT   (shell respawn)
;
; Extension point.  A future EXEC_RETURN policy would be selected in
; supervisor_after_teardown from the policy the terminated transient ran under,
; and would restore a saved parent instead of launching the shell.  It still
; runs after WBOOT teardown, so a child's interrupt and device state is gone
; before any parent comes back.  Nothing here saves a TPA image.
;
; Default shell identity.  The default shell is "whatever loader image sits in
; the pristine CCP slot, entered at CCP_CLEARBUF_ENTRY": the ZephyrShell shim,
; which loads A:ZSH.COM (CCP=zshell), or ZCPR2 itself (CCP=zcpr2).  Changing
; where the shell comes from -- /SYSTEM/ZSH.COM, say -- changes
; supervisor_launch_shell and that loader image, never BOOT or WBOOT.
;
; Every entry runs in latch mode 11 on the BIOS stack, called directly from
; common boot code or through xing_os_call_ix.  None of them blocks, enables or
; disables interrupts, or emits console/VDP traffic.  Not ISR-safe.

	.globl supervisor_cold_start,supervisor_after_teardown
	.globl supervisor_exec_replace_commit,native_vfs_entry
	.globl SUPERVISOR_CODE_START,SUPERVISOR_CODE_END
	.globl SUPERVISOR_STATE_START,SUPERVISOR_STATE_END
	.globl sup_version,sup_role,sup_policy,sup_flags

	.area CODE (ABS)
	.org CBIOS_SUPERVISOR_CODE_BASE

SUPERVISOR_CODE_START:

; supervisor_cold_start
; Purpose:
;   First supervisor decision after cold boot.  Initializes the state block,
;   then selects the default shell.  Called once, by BOOT, after the machine,
;   page zero and interrupts are fully initialized.
; Inputs:
;   TDRIVE in page zero.
; Outputs:
;   HL = foreground entry point, C = CCP drive argument; for
;   supervisor_enter_foreground.  The selected loader image is installed.
; Clobbers:
;   AF, BC, DE, HL.
supervisor_cold_start:
	xor a
	ld (sup_flags),a
supervisor_state_init:
	ld a,#SUP_STATE_VERSION
	ld (sup_version),a
	ld a,#FG_NONE
	ld (sup_role),a
	ld a,#EXEC_REPLACE
	ld (sup_policy),a
	jr supervisor_launch_shell

; supervisor_after_teardown
; Purpose:
;   Decide what runs after WBOOT has completed transient teardown.  The role
;   and policy recorded for the terminated transient select the next program.
;   Must only be called as WBOOT's final step, from a clean OS-owned machine.
; Inputs:
;   Supervisor state as left by the last launch or BDOS 219 commit.
; Outputs, clobbers:
;   As supervisor_cold_start.
; Policy:
;   FG_CHILD under EXEC_REPLACE   -> the default shell.
;   FG_SHELL (shell terminated)   -> the default shell again (respawn).
;   FG_NONE  (not reachable today: every launch records a role)
;                                 -> the default shell.
;   An invalid state block is reinitialized, SUP_FLAG_STATE_REPAIRED is set,
;   and the default shell is launched.  There is no other safe choice.
supervisor_after_teardown:
	ld a,(sup_version)
	cp #SUP_STATE_VERSION
	jr nz,supervisor_repair
	ld a,(sup_role)
	cp #FG_ROLE_LIMIT
	jr nc,supervisor_repair
	ld a,(sup_policy)
	cp #EXEC_POLICY_LIMIT
	jr nc,supervisor_repair
	; The foreground transient no longer exists.
	ld a,#FG_NONE
	ld (sup_role),a
	; Policy dispatch.  EXEC_REPLACE is the only policy; its successor is
	; always the default shell.  EXEC_RETURN would branch here.
	jr supervisor_launch_shell

supervisor_repair:
	ld a,(sup_flags)
	or #SUP_FLAG_STATE_REPAIRED
	ld (sup_flags),a
	jr supervisor_state_init

; supervisor_launch_shell
; Purpose:
;   Make the default shell the foreground program: install its loader image in
;   the CCP slot from the pristine copy in bank 7, record FG_SHELL under
;   EXEC_REPLACE, and return its entry point.
; Inputs:
;   Mode 11: bank 7 and the common CCP slot are both visible.
; Outputs, clobbers:
;   As supervisor_cold_start.
supervisor_launch_shell:
	ld hl,#CCP_RESTORE_BASE
	ld de,#CBASE
	ld bc,#CCP_RESTORE_SIZE
	ldir
	ld a,#FG_SHELL
	ld (sup_role),a
	ld a,#EXEC_REPLACE
	ld (sup_policy),a
	ld a,(TDRIVE)
	ld c,a
	ld hl,#CCP_CLEARBUF_ENTRY
	ret

; supervisor_exec_replace_commit
; Purpose:
;   BDOS 219's notice that a child has been loaded and is about to replace the
;   shell, combined with the loader's final handle close so that the loader in
;   common memory does not grow.  Records FG_CHILD under EXEC_REPLACE, then
;   performs the native CLOSE the loader has already staged.
; Inputs:
;   FAC_SFCB_BUF holds the loader's descriptor with op = ZNATIVE_CLOSE.
;   Reached from zexec_commit_close through xing_os_call_ix.
; Outputs:
;   A = native_vfs_entry status (the loader ignores it).
; Clobbers:
;   As native_vfs_entry.
supervisor_exec_replace_commit:
	ld a,#FG_CHILD
	ld (sup_role),a
	ld a,#EXEC_REPLACE
	ld (sup_policy),a
	ld de,#FAC_SFCB_BUF
	jp native_vfs_entry

SUPERVISOR_CODE_END:

	.ifgt (SUPERVISOR_CODE_END - SUPERVISOR_CODE_START) - (CBIOS_SUPERVISOR_CODE_LIMIT - CBIOS_SUPERVISOR_CODE_BASE)
	.error 1
	.endif

; Persistent supervisor state.  Bank 7, never visible to a program in mode 10.
; Written in full by supervisor_cold_start; survives every warm boot.
	.area SUPV_WORK (ABS)
	.org CBIOS_SUPERVISOR_STATE_BASE
SUPERVISOR_STATE_START:
sup_version:
	.ds 1
sup_role:
	.ds 1
sup_policy:
	.ds 1
sup_flags:
	.ds 1
SUPERVISOR_STATE_END:
; The SUP_OFF_* offsets in layout/memory.inc describe this block; the
; supervisor lifecycle test checks them against these labels.

	.ifne (SUPERVISOR_STATE_END - SUPERVISOR_STATE_START) - SUP_STATE_BYTES
	.error 1
	.endif
	.ifgt (SUPERVISOR_STATE_END - SUPERVISOR_STATE_START) - (CBIOS_SUPERVISOR_STATE_LIMIT - CBIOS_SUPERVISOR_STATE_BASE)
	.error 1
	.endif
