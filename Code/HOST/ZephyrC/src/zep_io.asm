; zep_io.asm -- low-level helpers for ZephyrC (z88dk-z80asm syntax).
;
; Calling convention: z88dk classic with SDCC, sdcccall(0).  Stack arguments
; start at SP+2, a uint8_t takes one byte, the caller removes them.  Results:
; uint8_t in L, uint16_t in HL.  IX and IY belong to the caller and are kept.

    SECTION code_user

    PUBLIC _zep__bdos_bcde
    PUBLIC _zep__call_saved
    PUBLIC _zep__in
    PUBLIC _zep__out2
    PUBLIC _zep__otir
    PUBLIC _zep__inir
    PUBLIC _zep__outn
    PUBLIC _zep__di
    PUBLIC _zep__ei
    PUBLIC _zep__iff

; uint16_t zep__bdos_bcde(zep__bdoscall_t *call) __z88dk_fastcall
; HL -> { C, B, DE }.  BDOS preserves neither IX nor IY; ZSDOS uses IX.
_zep__bdos_bcde:
    push ix
    push iy
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    call 5
    pop iy
    pop ix
    ret

; uint16_t zep__call_saved(uint16_t address) __z88dk_fastcall
; Calls the routine at HL and returns its HL, keeping IX and IY.
_zep__call_saved:
    push ix
    push iy
    call call_hl
    pop iy
    pop ix
    ret
call_hl:
    jp (hl)

; uint8_t zep__in(uint8_t port) __z88dk_fastcall
_zep__in:
    ld c,l
    in l,(c)
    ret

; void zep__out2(uint16_t port_and_value) __z88dk_fastcall   L = port, H = value
_zep__out2:
    ld c,l
    out (c),h
    ret

; void zep__otir(uint8_t port, const uint8_t *src, uint16_t n)
; The I/O decoders use A7-A0 only, so OTIR's count on A15-A8 is harmless.
_zep__otir:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ex de,hl                ; HL = src, DE = n
otir_chunk:
    ld a,d
    or e
    ret z
    ld a,d
    or a
    jr z,otir_tail
    ld b,0                  ; 256 bytes
    otir
    dec d
    jr otir_chunk
otir_tail:
    ld b,e
    otir
    ret

; void zep__inir(uint8_t port, uint8_t *dst, uint16_t n)
_zep__inir:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ex de,hl
inir_chunk:
    ld a,d
    or e
    ret z
    ld a,d
    or a
    jr z,inir_tail
    ld b,0
    inir
    dec d
    jr inir_chunk
inir_tail:
    ld b,e
    inir
    ret

; void zep__outn(uint8_t port, uint8_t value, uint16_t n)
_zep__outn:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld b,(hl)               ; value
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)               ; DE = n
outn_loop:
    ld a,d
    or e
    ret z
    out (c),b
    dec de
    jr outn_loop

; void zep__di(void) / void zep__ei(void)
;
; The library brackets multi-byte port sequences with these rather than with
; SDCC's __critical.  __critical saves the interrupt state with "ld a,i", and on
; an NMOS Z80 an interrupt arriving during that instruction reports IFF2 as
; clear, so the matching restore disables interrupts permanently.  ZephyrC calls
; are documented as running with interrupts enabled, so plain DI/EI is both
; correct and cheaper.
_zep__di:
    di
    ret

_zep__ei:
    ei
    ret

; uint8_t zep__iff(void) -- 1 when maskable interrupts are enabled.
;
; "ld a,i" copies IFF2 into P/V.  The erratum that makes this unreliable is an
; NMOS-only defect and this machine has a CMOS Z80, but it is only used for
; diagnostics here, never to decide whether to re-enable interrupts.
_zep__iff:
    ld a,i
    ld l,0
    ret po
    inc l
    ret
