; Zephyr-80 IORQ/output decode test
;
; Walkthrough:
;   1. Start at 0000h for use as simple ROM code.
;   2. Disable interrupts so nothing else changes bus activity.
;   3. Load A with the fixed test pattern 55h.
;   4. Forever write A to I/O port 80h and jump back to repeat.
;   5. Use this to observe IORQ activity, address decoding, and any hardware
;      connected to port 80h.

org 0000h        
        
        DI
        LD A,$55
loop:
        OUT ($80),A
        JR loop
