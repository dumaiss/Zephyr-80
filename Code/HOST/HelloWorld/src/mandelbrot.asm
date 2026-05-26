; ------------------------------------------------------------
; mandel_bios_conout_z80asm.asm
;
; Monitor-launched Mandelbrot test for Zephyr-80.
; Intended load/run address: 8000h
;
; Uses CP/M BIOS CONOUT directly:
;   BOOT   = CBIOS_BASE + 0
;   WBOOT  = CBIOS_BASE + 3
;   CONST  = CBIOS_BASE + 6
;   CONIN  = CBIOS_BASE + 9
;   CONOUT = CBIOS_BASE + 12
;
; CONOUT expects character in C.
;
; Assemble as flat binary and load to 8000h.
; ------------------------------------------------------------

        org     8000h

CBIOS_BASE:      equ     0DA00h
BIOS_CONOUT:     equ     CBIOS_BASE + 000Ch
BDOS:            equ     00005h

W:               equ     64
H:               equ     24
MAXITER:         equ     24

; Signed Q4.4 fixed point:
;   1.0 = 16
;   2.0 = 32
;   4.0 = 64
CX0:             equ     -34        ; about -2.125 * 16
CY0:             equ     -19        ; about -1.1875 * 16
DX:              equ     1
DY:              equ     2
THRESH:          equ     64

CR:              equ     13
LF:              equ     10

start:
        ld      hl,msg_start
        call    puts

        xor     a
        ld      (py),a
        ld      hl,CY0
        ld      (cy),hl

row_loop:
        ld      a,(py)
        cp      H
        jp      nc,done

        ; Print row marker: "ROW xx"
        ld      hl,msg_row
        call    puts
        ld      a,(py)
        call    print_hex8
        call    crlf

        xor     a
        ld      (px),a
        ld      hl,CX0
        ld      (cx),hl

col_loop:
        ld      a,(px)
        cp      W
        jp      nc,end_row

        ; X=0, Y=0, I=0
        ld      hl,0
        ld      (x),hl
        ld      (y),hl
        xor     a
        ld      (iter),a

iter_loop:
        ; x2 = x*x >> 4
        ld      hl,(x)
        ld      de,(x)
        call    mul_q4
        ld      (x2),hl

        ; y2 = y*y >> 4
        ld      hl,(y)
        ld      de,(y)
        call    mul_q4
        ld      (y2),hl

        ; if x2+y2 > 4.0 then escape
        ld      hl,(x2)
        ld      de,(y2)
        add     hl,de
        ld      a,h
        or      a
        jp      nz,escaped
        ld      a,l
        cp      THRESH+1
        jp      nc,escaped

        ; if I >= MAXITER, inside set
        ld      a,(iter)
        cp      MAXITER
        jp      nc,inside

        ; xx = x2 - y2 + cx
        ld      hl,(x2)
        ld      de,(y2)
        or      a
        sbc     hl,de
        ld      de,(cx)
        add     hl,de
        ld      (xx),hl

        ; y = 2*x*y + cy
        ld      hl,(x)
        ld      de,(y)
        call    mul_q4
        add     hl,hl
        ld      de,(cy)
        add     hl,de
        ld      (y),hl

        ; x = xx
        ld      hl,(xx)
        ld      (x),hl

        ; I++
        ld      a,(iter)
        inc     a
        ld      (iter),a
        jp      iter_loop

escaped:
        ; char index = min(iter >> 1, 9)
        ld      a,(iter)
        srl     a
        cp      10
        jr      c,esc_idx_ok
        ld      a,9
esc_idx_ok:
        ld      e,a
        ld      d,0
        ld      hl,palette
        add     hl,de
        ld      a,(hl)
        call    putc_a
        jp      next_col

inside:
        ld      a,'@'
        call    putc_a

next_col:
        ; px++
        ld      a,(px)
        inc     a
        ld      (px),a

        ; cx += DX
        ld      hl,(cx)
        ld      de,DX
        add     hl,de
        ld      (cx),hl

        jp      col_loop

end_row:
        call    crlf

        ; py++
        ld      a,(py)
        inc     a
        ld      (py),a

        ; cy += DY
        ld      hl,(cy)
        ld      de,DY
        add     hl,de
        ld      (cy),hl

        jp      row_loop

done:
        ld      hl,msg_done
        call    puts
        jp start                     ; monitor G should return if it CALLs us

; ------------------------------------------------------------
; Output helpers
; ------------------------------------------------------------

; A = character.
; BIOS CONOUT expects C = character.
; Preserve all normal and index registers to make this a clean test.
putc_a:
        push    af
        push    bc
        push    de
        push    hl
        push    ix
        push    iy

        ld      c, 6
        ld      e, a
        call    BDOS

        ld      c,6
        ld      e,0ffh
        call    BDOS

        or      a  
        jr      z,no_char

        cp      03h
        jr      z,break


no_char:
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        ret

break:
        pop     iy
        pop     ix
        pop     hl
        pop     de
        pop     bc
        pop     af
        jp      00100h                     ; monitor G should return if it CALLs 

puts:
        ld      a,(hl)
        or      a
        ret     z
        call    putc_a
        inc     hl
        jr      puts

crlf:
        ld      a,CR
        call    putc_a
        ld      a,LF
        call    putc_a
        ret

print_hex8:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    print_hex_nibble
        pop     af
        call    print_hex_nibble
        ret

print_hex_nibble:
        and     0Fh
        add     a,'0'
        cp      '9'+1
        jr      c,print_hex_digit_ok
        add     a,7
print_hex_digit_ok:
        call    putc_a
        ret

; ------------------------------------------------------------
; Signed Q4.4 multiply
;
; Input:
;   HL = signed Q4.4 A
;   DE = signed Q4.4 B
;
; Output:
;   HL = (A * B) >> 4
;
; This simple version effectively uses low-byte magnitudes.
; Fine for this Mandelbrot stress test because values are kept
; small by the escape test.
; ------------------------------------------------------------

mul_q4:
        xor     a
        ld      (mul_sign),a

        ; abs(HL)
        bit     7,h
        jr      z,mul_x_pos
        call    neg_hl
        ld      a,(mul_sign)
        xor     1
        ld      (mul_sign),a

mul_x_pos:
        ; save abs(x) low byte into E
        ld      e,l
        ld      d,0

        ; abs(original DE) by moving it into HL
        ex      de,hl
        bit     7,h
        jr      z,mul_y_pos
        call    neg_hl
        ld      a,(mul_sign)
        xor     1
        ld      (mul_sign),a

mul_y_pos:
        ; multiplier = low byte of abs(y)
        ld      a,l

        ; restore multiplicand in DE approximately
        ex      de,hl

        ; unsigned 8x8 multiply:
        ;   E * A -> HL
        ld      h,0
        ld      l,0
        ld      d,0
        ld      b,8

mul_loop:
        srl     a
        jr      nc,mul_no_add
        add     hl,de

mul_no_add:
        sla     e
        rl      d
        djnz    mul_loop

        ; >> 4
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l

        ; apply sign
        ld      a,(mul_sign)
        or      a
        ret     z
        call    neg_hl
        ret

neg_hl:
        ld      a,h
        cpl
        ld      h,a
        ld      a,l
        cpl
        ld      l,a
        inc     hl
        ret

; ------------------------------------------------------------
; Data
; ------------------------------------------------------------

msg_start:
        defb    CR,LF
        defm    "Z80 BIOS CONOUT MANDELBROT"
        defb    CR,LF,0

msg_row:
        defm    "ROW "
        defb    0

msg_done:
        defb    CR,LF
        defm    "DONE"
        defb    CR,LF,0

palette:
        defm    " .:-=+*#%@"

py:
        defb    0
px:
        defb    0
iter:
        defb    0
mul_sign:
        defb    0

x:
        defw    0
y:
        defw    0
xx:
        defw    0
x2:
        defw    0
y2:
        defw    0
cx:
        defw    0
cy:
        defw    0