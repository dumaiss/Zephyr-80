;===========================================================================
; ctc_test.asm — Z80 CTC Interrupt Test for Zephyr-80
;
; Assembler: z80asm 1.8
;   Build:  z80asm -l -o ctc_test.bin ctc_test.asm
;   HEX:    python3 make_hex.py
;
; SDCC/asxxxx (sdasz80) equivalent notes:
;   - Replace  LABEL: equ VALUE   with  LABEL .equ VALUE  (no colon)
;   - Add      .area _CODE (ABS)  before the first  org
;   - Labels that are entry points get double colon (::) in asxxxx
;   - Assemble: sdasz80 -l ctc_test.rel ctc_test.asm
;     Link:     sdld -i ctc_test.ihx ctc_test.lnk  (with absolute link script)
;
; -----------------------------------------------------------------------
; Memory layout
; -----------------------------------------------------------------------
;   0x8000-0x8029   Setup code  (this section, loaded via Intel HEX)
;   0x8100          COUNTER_LOW  — low byte of 16-bit interrupt counter
;   0x8101          COUNTER_HIGH — high byte of 16-bit interrupt counter
;   0x8102          HEARTBEAT    — toggles 0x00<->0xFF on every interrupt
;   0x8200-0x8300   IM2 vector table (257 bytes, all = 0x83)
;   0x8383-0x8396   ISR (this file, second section)
;
; -----------------------------------------------------------------------
; IM2 vector table trick
; -----------------------------------------------------------------------
;   The Z80 in IM 2 forms a 16-bit table address: high byte = I register,
;   low byte = vector byte supplied by the interrupting device.
;   The CPU then reads a 16-bit pointer from that address and jumps to it.
;
;   Strategy:
;     Set I = 0x82.
;     Fill 0x8200-0x8300 (257 bytes) with 0x83.
;     Place ISR at 0x8383.
;
;   For any CTC vector byte V in range 0x00-0xFE (even values):
;     Table address = 0x8200 | V
;     Low  byte of pointer = (0x82VV+0) = 0x83
;     High byte of pointer = (0x82VV+1) = 0x83
;     → CPU jumps to 0x8383  (ISR)  (v)
;
;   This eliminates the need to know the exact CTC channel bit offsets
;   during first bring-up.  We program a plausible vector base (0x80)
;   and the ISR is reached regardless of which bits the CTC ORs in.
;
; -----------------------------------------------------------------------
; CTC channel 0 control word: 0xA7 = 1010 0111b
; -----------------------------------------------------------------------
;   Bit 7 = 1  Interrupt enabled
;   Bit 6 = 0  Timer mode  (1 would be counter/event mode)
;   Bit 5 = 1  Prescaler = 256  (0 would be prescaler = 16)
;   Bit 4 = 0  Rising edge  (irrelevant — automatic trigger selected)
;   Bit 3 = 0  Automatic trigger  (timer starts on time-constant load)
;   Bit 2 = 1  Time constant follows this control word
;   Bit 1 = 1  Software reset  (clears channel before reprogramming)
;   Bit 0 = 1  Control word  (0 would be an IM2 vector byte)
;
; -----------------------------------------------------------------------
; Expected interrupt rate
; -----------------------------------------------------------------------
;   CTC clock  : 10,000,000 Hz
;   Prescaler  : 256
;   Time const : 0x00 = 256 counts
;   Rate = 10,000,000 / (256 × 256) = 152.59 Hz  (~153 interrupts/second)
;
; -----------------------------------------------------------------------
; Monitor G-command trampoline
; -----------------------------------------------------------------------
;   Monitor G pushes a return address then does JP (HL).
;   This routine uses plain RET to return to the monitor prompt.
;   SP is not touched — the monitor owns the stack.
;
; -----------------------------------------------------------------------
; Usage after loading
; -----------------------------------------------------------------------
;   L              
; load the Intel HEX file
;   G 8000         
; run setup — returns immediately to prompt
;   D 8100 0010    
; dump 16 bytes from 0x8100
; repeat to watch counter grow
;===========================================================================

; -----------------------------------------------------------------------
; Equates
; -----------------------------------------------------------------------
CTC0_PORT:      equ 0x40        ; CTC channel 0 I/O port (confirmed)

COUNTER_LOW:    equ 0x8100      ; 16-bit interrupt counter, low byte
COUNTER_HIGH:   equ 0x8101      ; 16-bit interrupt counter, high byte
HEARTBEAT:      equ 0x8102      ; visual toggle byte (0x00 <-> 0xFF)
IM2_TABLE:      equ 0x8200      ; start of IM2 vector table
IM2_TABLE_END:  equ 0x8300      ; last byte of table (inclusive)
ISR_ENTRY:      equ 0x8383      ; ISR address — matches the 0x83 fill

; -----------------------------------------------------------------------
; SECTION 1: Setup code at 0x8000
; -----------------------------------------------------------------------
org     0x8000

setup:
di ; --- Step 1: disable interrupts during setup

;--- Step 2: clear 16-bit counter and heartbeat byte ---
xor     a                       ; A = 0x00
ld      (COUNTER_LOW),  a       ; (0x8100) = 0
ld      (COUNTER_HIGH), a       ; (0x8101) = 0
ld      (HEARTBEAT),    a       ; (0x8102) = 0

;--- Step 4: fill IM2 vector table 0x8200-0x8300 with 0x83 ---
; Write 0x83 to (0x8200), then LDIR copies it forward 256 more times.
; Result: every byte 0x8200-0x8300 = 0x83
; Any vector byte from CTC resolves to pointer 0x8383 = ISR.
ld      hl, IM2_TABLE           ; HL → 0x8200 (source for LDIR)
ld      de, IM2_TABLE + 1       ; DE → 0x8201 (dest for LDIR)
ld      bc, IM2_TABLE_END - IM2_TABLE  ; BC = 0x0100 = 256 iterations
ld      a, 0x83
ld      (hl), a                 ; seed first byte: (0x8200) = 0x83
ldir                            ; copy (HL)→(DE), HL++, DE++, BC-- until BC=0
                                ; fills 0x8201 through 0x8300 with 0x83

;--- Step 5+6: set I register and interrupt mode ---
ld      a, 0x82
ld      i, a                    ; I = 0x82 (high byte of vector table address)
im      2                       ; IM 2: vectored interrupt mode

;--- Step 7: program CTC channel 0 interrupt vector byte ---
; Bit 0 = 0 identifies this as an IM2 vector byte (not a control word).
; CTC will OR channel offset bits into this value at interrupt time.
; We use 0x80; exact value doesn't matter since the whole table is 0x83.
ld      a, 0x80
out     (CTC0_PORT), a          ; vector base → CTC channel 0

;--- Step 8: program CTC channel 0 control word ---
; 0xA7 = timer mode, prescaler 256, auto-trigger, reset, interrupt on, TC follows
ld      a, 0xA7
out     (CTC0_PORT), a          ; control word → CTC channel 0

; Time constant 0x00 = 256 counts.  Timer arms and starts on this write.
ld      a, 0x00
out     (CTC0_PORT), a          ; time constant → CTC channel 0 (starts timer)

;--- Step 9+10: enable interrupts and return to monitor ---
ei
ret                             ; return to monitor prompt (G-command trampoline)

; -----------------------------------------------------------------------
; SECTION 2: ISR at 0x8383
; -----------------------------------------------------------------------
; Placed here because the IM2 table (filled with 0x83) resolves any
; CTC-supplied vector to the 16-bit pointer 0x8383 at address 0x82VV.
;
; RETI vs RET:
;   RETI copies IEF2 → IEF1 (re-enables maskable interrupts after return).
;   RETI also signals IEO on the Z80 peripheral daisy chain.
;   Plain RET would leave IEF1 cleared, locking out all further interrupts.
; -----------------------------------------------------------------------

org     0x8383

isr:
push    af                      ; preserve accumulator and flags
push    hl                      ; preserve HL


ld a,055h
ld (08103h),a

;--- Increment 16-bit little-endian counter at 0x8100/0x8101 ---
; LD HL,(nn)   → L = (0x8100), H = (0x8101)   [little-endian load]
; INC HL       → 16-bit add 1 with carry propagation
; LD (nn),HL   → (0x8100) = L, (0x8101) = H   [little-endian store]
ld      hl, (COUNTER_LOW)       ; load 16-bit counter
inc     hl
ld      (COUNTER_LOW), hl       ; store back

;--- Toggle heartbeat byte 0x00 <-> 0xFF ---
; Visible with: D 8102 0001 — should flip between 00 and FF.
ld      hl, HEARTBEAT           ; HL = 0x8102
ld      a, (hl)
xor     0xFF                    ; flip all bits
ld      (hl), a

pop     hl
pop     af
ei
reti                            ; restore IEF1 from IEF2, signal IEO, return