; PCTRACE's interrupt callback, copied to E100h.
;
; Records where the machine was each time an interrupt arrived, so that after
; control has gone somewhere it should not, the last moments are still on
; record.  RAM survives the fault: the operator's cookie in TIMTEST proved the
; program is not reloaded.
;
; The BIOS CTC entry saves the interrupted SP at CBIOS_ISR_SP_SAVE (FE80h)
; before it pushes anything, and the CPU pushed the return address before that,
; so the word at the saved SP is the interrupted PC.
;
; In: C = channel, per the BIOS callback contract.
; Uses AF, BC, DE, HL only; preserves IX, IY and the alternate set; ends with
; RET.  No BDOS, no BIOS, no I/O except reading the bank latch.
;
; Addresses are mirrored in pc_probe.h.

    SECTION code_user
    PUBLIC _zep_pc_probe_install
    PUBLIC _zep_pc_probe_image, _zep_pc_probe_size

    defc isr_sp_save = 0xfe80       ; BIOS: the interrupted SP
    defc pc_count    = 0xe006       ; 32-bit interrupt count
    defc pc_index    = 0xe004       ; next ring slot
    defc pc_wrapped  = 0xe005
    defc pc_ring     = 0xe1c0       ; 40 entries of 6 bytes, to E2AFh
    defc PC_SLOTS    = 40
    defc pc_heart    = 0xe00d       ; foreground heartbeat
    defc pc_stall    = 0xe00e       ; interrupts since the heartbeat moved
    defc pc_limit    = 0xe010       ; watchdog limit, 0 disables
    defc pc_fired    = 0xe012
    defc pc_seen     = 0xe013       ; heartbeat as last seen here
    defc pc_minsp    = 0xe014       ; lowest interrupted SP seen, 0 = unset

_zep_pc_probe_install:
    ld hl,_zep_pc_probe_image
    ld de,0xe100
    ld bc,probe_end - _zep_pc_probe_image
    ldir
    ret

_zep_pc_probe_image:
    ld hl,pc_count
    inc (hl)
    jr nz,pc_slot
    inc hl
    inc (hl)
    jr nz,pc_slot
    inc hl
    inc (hl)
    jr nz,pc_slot
    inc hl
    inc (hl)

pc_slot:
    ld a,(pc_index)
    ld e,a
    add a,a
    add a,e                         ; 3 x index
    add a,a                         ; 6 x index
    ld e,a
    ld d,0
    ld hl,pc_ring
    add hl,de
    ex de,hl                        ; DE -> this slot

    ld hl,(isr_sp_save)             ; HL = interrupted SP
    ld a,(hl)
    ld (de),a                       ; PC low
    inc hl
    ld a,(hl)
    inc de
    ld (de),a                       ; PC high
    dec hl                          ; HL = interrupted SP again
    inc de
    ld a,l
    ld (de),a                       ; SP low
    inc de
    ld a,h
    ld (de),a                       ; SP high
    inc de
    in a,(0)                        ; bank latch: which mapping was running
    ld (de),a
    inc de
    ld a,c
    ld (de),a                       ; channel

    ; Lowest interrupted SP seen.  The C stack grows down through the CCP area;
    ; if it ever reaches E3FFh it is standing on this ring and the tick stub.
    ; HL still holds the interrupted SP.
    ld de,(pc_minsp)
    ld a,d
    or e
    jr z,pc_setmin                  ; nothing recorded yet
    ld a,h
    cp d
    jr c,pc_setmin
    jr nz,pc_index_step
    ld a,l
    cp e
    jr nc,pc_index_step
pc_setmin:
    ld (pc_minsp),hl

pc_index_step:
    ld hl,pc_index
    ld a,(hl)
    inc a
    cp PC_SLOTS
    jr c,pc_keep
    ld (hl),0
    ld hl,pc_wrapped
    ld (hl),1
    jr pc_watchdog
pc_keep:
    ld (hl),a

; Watchdog.  The foreground bumps pc_heart as it works; if it stops moving while
; interrupts keep arriving, the machine is hung, and a hang has to be ended with
; the reset button -- which cold boot answers by copying ROM over C000h-FFFFh,
; erasing this ring along with it.  So end it here instead: warm boot leaves
; E000h-E3FFh alone, and the next run prints where the foreground was stuck.
;
; This can only catch a hang in which interrupts are still being serviced. A
; hang with interrupts disabled never reaches this code.
pc_watchdog:
    ld hl,(pc_limit)
    ld a,h
    or l
    ret z                           ; watchdog off
    ld a,(pc_heart)
    ld hl,pc_seen
    cp (hl)
    jr z,pc_stalled
    ld (hl),a                       ; foreground moved: start the count again
    ld hl,0
    ld (pc_stall),hl
    ret
pc_stalled:
    ld hl,(pc_stall)
    inc hl
    ld (pc_stall),hl
    ld de,(pc_limit)
    or a
    sbc hl,de
    ret c                           ; not stuck long enough yet
    ld a,1
    ld (pc_fired),a
    jp 0                            ; warm boot, ring intact
probe_end:
    ASSERT probe_end - _zep_pc_probe_image <= 0xc0

_zep_pc_probe_size:
    defw probe_end - _zep_pc_probe_image
