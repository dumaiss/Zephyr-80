; IRQTEST foreground register/SP probe, copied to E100h.
;
; No private IM2 table and no ISR-stack changes: interrupts use the running
; BIOS and a registered common-memory callback. The probe is position-independent
; apart from its explicit common-memory data addresses (irq_probe.h).
;
; In: L = 0 for application mapping, 1 for OS mapping.
; Out: snapshot at E010h, stage at E007h. Returns on the original caller stack
;      with original latch, IX/IY and alternate registers restored; EI on exit.
; Clobbers: AF, BC, DE, HL. Foreground only, not ISR-safe. Bounded (~6.9 ms
; at 10 MHz plus interrupt service); no console, IOC, VDP or sound traffic.

    SECTION code_user
    PUBLIC _zep_irq_probe_install, _zep_irq_probe
    PUBLIC _zep_irq_probe_image, _zep_irq_probe_size

    defc probe_mode = 0xe004
    defc probe_stage = 0xe007
    defc observed = 0xe010
    defc saved_sp = 0xe060
    defc saved_ix = 0xe062
    defc saved_iy = 0xe064
    defc saved_bc_alt = 0xe066
    defc saved_de_alt = 0xe068
    defc saved_hl_alt = 0xe06a
    defc saved_af_alt = 0xe06c
    defc saved_latch = 0xe06e
    defc test_sp = 0xe300

_zep_irq_probe_install:
    ld hl,_zep_irq_probe_image
    ld de,0xe100
    ld bc,probe_end - _zep_irq_probe_image
    ldir
    ld hl,minimal_callback
    ld de,0xe080
    ld bc,minimal_callback_end - minimal_callback
    ldir
    ret

_zep_irq_probe:
    ld a,l
    ld (probe_mode),a
    jp 0xe100

_zep_irq_probe_image:
    di
    ld (saved_sp),sp
    ld (saved_ix),ix
    ld (saved_iy),iy
    exx
    ld (saved_bc_alt),bc
    ld (saved_de_alt),de
    ld (saved_hl_alt),hl
    exx
    ex af,af'
    push af
    pop hl
    ld (saved_af_alt),hl
    ex af,af'
    in a,(0)
    ld (saved_latch),a

    ; Switch only after PC and SP are common. Both mappings keep the selected
    ; application bank; mode 11 overlays bank 7 in 2000h-DFFFh.
    ld sp,test_sp
    ld a,1
    ld (probe_stage),a
    ld a,(probe_mode)
    or a
    ld a,(saved_latch)
    jr z,probe_application
    or 0x08
    jr probe_map
probe_application:
    and 0xf7
probe_map:
    out (0),a

    exx
    ld bc,0x6996
    ld de,0x8778
    ld hl,0x4bb4
    exx
    ld hl,0x5a28
    push hl
    pop af
    ex af,af'
    ld bc,0x00c3
    ld de,0x69a5
    ld ix,0x1357
    ld iy,0x2468
    ld hl,0xa5d7
    push hl
    pop af
    ld hl,0xa569

    ; DJNZ changes only B, which starts at 0 and ends at 0 after 256 passes.
    ; NOP and DJNZ preserve flags and every other register. No HALT: a dead
    ; timer must still let this test return and report zero interrupts.
    ei
probe_window:
    defs 64,0
    djnz probe_window
    di

    ; Capture SP before making any push, then recover a known stack even if
    ; it is wrong. The original caller return address is on a separate stack.
    ld (observed + 20),sp
    ld sp,test_sp
    ld (observed + 2),bc
    ld (observed + 4),de
    ld (observed + 6),hl
    ld (observed + 8),ix
    ld (observed + 10),iy
    push af
    pop hl
    ld (observed),hl
    exx
    ld (observed + 14),bc
    ld (observed + 16),de
    ld (observed + 18),hl
    exx
    ex af,af'
    push af
    pop hl
    ld (observed + 12),hl
    ex af,af'
    ld a,2
    ld (probe_stage),a

    ld a,(saved_latch)
    out (0),a
    ld ix,(saved_ix)
    ld iy,(saved_iy)
    exx
    ld bc,(saved_bc_alt)
    ld de,(saved_de_alt)
    ld hl,(saved_hl_alt)
    exx
    ld hl,(saved_af_alt)
    push hl
    pop af
    ex af,af'
    ld sp,(saved_sp)
    ei
    ret
probe_end:
    ASSERT probe_end - _zep_irq_probe_image <= 0x1d0

_zep_irq_probe_size:
    defw probe_end - _zep_irq_probe_image

; Optional minimal registered ISR callback, copied to E080h.
; In: C = channel (unused). Out: increments E090h counter; clobbers F/HL.
; RET to BIOS, no EI, no bank changes, no I/O, bounded and ISR-safe.
minimal_callback:
    ld hl,0xe090
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret
minimal_callback_end:
    ASSERT minimal_callback_end - minimal_callback <= 0x10
