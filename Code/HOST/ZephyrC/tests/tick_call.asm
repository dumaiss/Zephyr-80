; tick_call.asm -- enter the CTC tick stub the way the BIOS dispatcher does.

    SECTION code_user
    PUBLIC _zep_test_tick

; void zep_test_tick(uint8_t channel) __z88dk_fastcall
; The BIOS calls the callback with C = channel; it may use AF, BC, DE, HL.
_zep_test_tick:
    push ix
    push iy
    ld c,l
    call 0xE300
    pop iy
    pop ix
    ret
