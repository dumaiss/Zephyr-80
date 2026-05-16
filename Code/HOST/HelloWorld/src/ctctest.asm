; Zephyr-80 CTC channel 0 sampling test
;
; Walkthrough:
;   1. This file is assembled at 8000h so it can be loaded into RAM and called
;      from the monitor.
;   2. CTC0 names I/O port 40h, the CTC channel being sampled.
;   3. SAMPLE_BUF names RAM address 8100h, where samples are stored.
;   4. start loads HL with SAMPLE_BUF and uses HL as the write pointer.
;   5. B is loaded with 32, so DJNZ controls a 32-sample loop.
;   6. Each loop reads one byte from CTC0 into A, stores A at (HL), advances HL,
;      and repeats until B reaches zero.
;   7. RET returns to the caller. The sample bytes are left at 8100h-811Fh.

                org 8000h

CTC0:            equ 040h
SAMPLE_BUF:      equ 8100h

start:
                ld hl,SAMPLE_BUF
                ld b,32

sample_loop:
                in a,(CTC0)
                ld (hl),a
                inc hl
                djnz sample_loop

                ret
