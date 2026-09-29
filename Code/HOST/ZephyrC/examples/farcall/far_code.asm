; far_code.asm -- position-independent payload for FARCALL.COM.
;
; zep_bank_call enters with HL = the caller's argument and returns the callee's
; HL.  Keep this payload self-contained: while it runs, bank 1 has replaced the
; program, so bank-0 code and static data are not accessible.

    SECTION code_user
    PUBLIC _far_code_start, _far_code_end

_far_code_start:
    ld de,0x0100
    add hl,de
    ret
_far_code_end:
