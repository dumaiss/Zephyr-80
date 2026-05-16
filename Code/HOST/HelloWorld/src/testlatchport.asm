; Zephyr-80 latch/input port read test
;
; Walkthrough:
;   1. Start at 0000h for use as simple ROM code.
;   2. Disable interrupts and move the stack to FFFFh.
;   3. Repeatedly read I/O port 00h into A.
;   4. Run two DJNZ delay loops. Loading B with 0 causes each DJNZ loop to count
;      through 256 iterations before falling through.
;   5. Jump back and read the port again, creating a slow repeated input cycle
;      for observing latch or input-port behavior.

        org 0000h
        di
        ld sp,0FFFFh

loop:
        in a,(00h)

        ld b,0
delay1:
        djnz delay1

        ld b,0
delay2:
        djnz delay2

        jr loop
