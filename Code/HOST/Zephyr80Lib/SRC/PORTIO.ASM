; PORTIO.ASM -- native FTL Modula-2 port I/O bridge for Zephyr-80.
;
; MD PORTIO.DEF
; ASM PORTIO.ASM PORTIO.REL
; Link the resulting native FTL .REL with ML, not TM2's REL converter.
; LABEL exports below MUST follow the procedure order in PORTIO.DEF: In, Out.
;
; The calling sequence is not inferred.  It is the one Dave Moore's own
; PORTIO.ASM uses, read out of the ASMFILES.LQR the distribution ships.
; CARDINAL parameters occupy two stack bytes each and the callee removes them.
;
; In is a FUNCTION, so the caller reserves the result area before pushing the
; parameter.  That is why its pop order differs from Out's: the placeholder is
; discarded and the real result pushed back in its place.
;
; The port number is passed in BC, so IN/OUT drive all sixteen address bits;
; Zephyr decodes the low byte.  Clobbers BC, DE, HL; preserves IX/IY and IFF.
; No software wait and no console traffic; the addressed hardware may assert
; WAIT.  Sound.Put keeps its own settling delay and write counter.

        CSECT

        LABEL                   ; In(port : CARDINAL) : CARDINAL
        POP     HL              ; return address
        POP     BC              ; port
        POP     DE              ; discard the caller's result area
        IN      E,(C)
        LD      D,0             ; a port reads one byte; clear the high half
        PUSH    DE              ; function result
        JP      (HL)

        LABEL                   ; Out(port, value : CARDINAL)
        POP     HL              ; return address
        POP     DE              ; value
        POP     BC              ; port
        OUT     (C),E
        JP      (HL)

        END
