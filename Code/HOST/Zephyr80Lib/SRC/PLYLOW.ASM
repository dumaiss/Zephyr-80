;  PLYLOW.ASM -- hot leaf routines of PlyCore, in Z80.
;
;  MD PLYLOW.DEF
;  ASM PLYLOW.ASM PLYLOW.REL
;  LABEL exports below MUST follow the procedure order in PLYLOW.DEF.
;
;  FTL parameter convention, as used by PORTIO.ASM and verified against Dave
;  Moore's own source: parameters are pushed left to right, two bytes each, and
;  the callee removes them.  A VAR parameter arrives as the address.
;
;  MacroState is eight bytes: offset+0, position+2, timer+4, delay+6.
;
;  Clobbers AF, BC, DE, HL.  Preserves IX/IY and the interrupt state.

NONE    EQU     0FFFFH          ; 65535 -- "no loop" / "no release"

        CSECT

;  PROCEDURE BoundMacro(VAR macro : MacroState; released : BOOLEAN;
;                       count, loopAt, releaseAt : CARDINAL);
;
;  Clamps macro.position into the macro's bounds.  The caller reads the three
;  header words once and passes them in; they cannot change while a macro runs.
        LABEL
        POP     HL
        LD      (RETADR),HL     ; return address
        POP     HL
        LD      (RELAT),HL      ; releaseAt   (last pushed, first popped)
        POP     HL
        LD      (LOOPAT),HL     ; loopAt
        POP     HL
        LD      (COUNT),HL      ; count
        POP     HL
        LD      A,L
        LD      (RELSED),A      ; released
        POP     HL
        LD      (MACRO),HL      ; VAR macro

;  IF (NOT released) AND (releaseAt <> NONE) AND (position >= releaseAt)
        LD      A,(RELSED)
        OR      A
        JR      NZ,PART2
        LD      HL,(RELAT)
        LD      DE,NONE
        OR      A
        SBC     HL,DE
        JR      Z,PART2
        CALL    GETPOS          ; HL = position
        LD      DE,(RELAT)
        OR      A
        SBC     HL,DE
        JR      C,PART2         ; position < releaseAt
        LD      HL,(LOOPAT)
        LD      DE,NONE
        OR      A
        SBC     HL,DE
        JR      Z,P1NOLOOP
        LD      HL,(LOOPAT)     ; position := loopAt
        JR      P1SET
P1NOLOOP:
        LD      HL,(RELAT)
        LD      A,H
        OR      L
        JR      Z,P1SET         ; releaseAt = 0 -> position := 0
        DEC     HL              ; position := releaseAt - 1
P1SET:
        CALL    SETPOS

;  IF position >= count
PART2:
        CALL    GETPOS
        LD      DE,(COUNT)
        OR      A
        SBC     HL,DE
        JR      C,BDONE         ; position < count
        LD      A,(RELSED)
        OR      A
        JR      Z,P2LOOP        ; not released
        LD      HL,(RELAT)
        LD      DE,NONE
        OR      A
        SBC     HL,DE
        JR      NZ,P2COUNT      ; released AND releaseAt <> NONE
P2LOOP:
        LD      HL,(LOOPAT)
        LD      DE,NONE
        OR      A
        SBC     HL,DE
        JR      Z,P2COUNT
        LD      HL,(LOOPAT)     ; position := loopAt
        JR      P2SET
P2COUNT:
        LD      HL,(COUNT)
        DEC     HL              ; position := count - 1
P2SET:
        CALL    SETPOS
BDONE:
        LD      HL,(RETADR)
        JP      (HL)

;  HL = macro.position
GETPOS:
        LD      HL,(MACRO)
        INC     HL
        INC     HL
        LD      E,(HL)
        INC     HL
        LD      D,(HL)
        EX      DE,HL
        RET

;  macro.position := HL
SETPOS:
        EX      DE,HL
        LD      HL,(MACRO)
        INC     HL
        INC     HL
        LD      (HL),E
        INC     HL
        LD      (HL),D
        RET

RETADR: DW      0
MACRO:  DW      0
COUNT:  DW      0
LOOPAT: DW      0
RELAT:  DW      0
RELSED: DB      0

        END
