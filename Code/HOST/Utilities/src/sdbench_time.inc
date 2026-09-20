; sdbench_time.inc — the benchmark's clock, its 32-bit arithmetic, and the
; numeric printing both of those feed.
;
; ---------------------------------------------------------------------------
; THE CLOCK: TWO COUNTERS, NO INTERRUPTS
; ---------------------------------------------------------------------------
;
; CTC channels 3 and 1, both timer mode, INTERRUPT DISABLED, read with a single
; IN each.  Nothing here ever vectors.
;
; MEASURED TICK RATE: on this board one counter step is 10 MHz / 16 = 1.6 us.
; The control word's prescaler bit D5 has NO OBSERVED EFFECT here: 27h (/16)
; and 2Fh (/256) both produced a 1.6 us step, which is how every reported time
; came out sixteen times the wall clock until the arithmetic below was
; rescaled.  Do not re-enable /256 arithmetic, or change the control word in
; the hope of one, without re-measuring the step rate on hardware.
;
; WHY NOT AN INTERRUPT
;
; THE IO CONTROLLER LINK CANNOT SURVIVE ONE.  cbios_ioc_command.asm is polled
; byte I/O against an externally clocked SIO -- "ISR-safe: No.  Blocking poll"
; -- with a three-byte receive FIFO, about 18 us at 6 us/byte.  A BIOS IM2
; dispatch saves four register pairs, calls the callback and issues EI/RETI,
; comfortably more than that budget; IOC_SDSOAK.COM's own header puts a bare
; 60 T-state callback at the edge of what "a read can just absorb".
;
; An earlier version of this file timed the run from a 1 kHz CTC interrupt.  It
; did not perturb the measurement, it destroyed it: BDOS reported "Bad Sector"
; on call 20 and CMD_FS_READ timed out with no reply byte.
;
; WHY TWO COUNTERS
;
; One 8-bit counter at 1.6 us repeats every 409.6 us, and the gap between two
; samples is only recoverable while it stays under that.  The first polled
; version assumed a 128-byte record read was about a millisecond; it was not.
;
; ON THIS MACHINE A RECORD READ IS ABOUT 19.5 MS -- nearly 48 full counter
; cycles, so a single counter aliased every read and the benchmark reported a
; throughput far above a stopwatch reading.  A clock that silently divides by
; an unknown integer is worse than no clock, because the answer still looks
; plausible.
;
; So the counter is widened instead.  Channel 3 runs with a time constant of 256
; and channel 1 with 255.  The two periods are coprime, so the pair of residues
; identifies the elapsed count uniquely over 256 * 255 = 65280 steps, which at
; 1.6 us is about 104 ms -- five times a normal read, and enough for a badly
; stalled one.
;
; The Chinese remainder step is unusually cheap here because 256 = 1 (mod 255):
;
;     a = (prevA - nowA) mod 256          residue from channel 3
;     b = (prevB - nowB) mod 255          residue from channel 1
;     k = (b - (a mod 255)) mod 255
;     elapsed = a + 256 * k
;
; No division, no table: one 8-bit subtract per channel and one more to combine.
; The two channels need no common start and are never synchronised -- only their
; own differences are used, so a pass can begin at any point in either cycle.
;
; Channel 1 is the partner because channel 0's TO0 is SIO0/A's clock and must
; not be touched, while TO1 leaves the board.  Channels 1 and 2 have never been
; seen to VECTOR, which is why nothing here asks them to; the CTC note in
; ../CPM2.2/docs/ records that they do COUNT with the interrupt bit clear and a
; control word of 27h.  The measured step is 10 MHz / 16 = 1.6 us (see above),
; and 2Fh steps at 1.6 us too, so the constant keeps the verified 27h and the
; arithmetic is scaled for the step the hardware actually makes.  tk_start
; proves the channels run anyway rather than trusting the note.
;
; WHAT IS STILL NOT MEASURABLE
;
; A single read longer than about 104 ms.  Nothing detects that, so if a
; reported total ever falls well short of a stopwatch, treat every figure as
; aliased -- the same cross-check that caught the single-counter ceiling.
;
; TICK UNITS
;
; ctc_tc holds the arithmetic scale, not a hardware time constant: one tick is
; ctc_tc * 1.6 us, and these counters make that exactly 1.

CTC_A		= 0x43		; channel 3
CTC_B		= 0x42		; channel 1.  The board wires CS0/CS1 to A1/A0,
				; so 40h 42h 41h 43h are channels 0 1 2 3.
CTC_POLLED	= 0x27		; timer, TC follows, reset, control; NO interrupt.
				; Steps at 10 MHz/16 (1.6 us) on this board: D5 has
				; no observed effect (2Fh steps at /16 too).
CTC_STOP	= 0x03		; software reset, no interrupt
CTC_TC_A	= 0		; 0 means 256: the mod-256 residue
CTC_TC_B	= 255		; coprime with 256
TICK_SCALE	= 1		; one counter step is one tick of 1.6 us

; ---------------------------------------------------------------------------
; tk_start — free-run both channels and zero the accumulated time base.
; Out: A = 0, or 1 / 2 when channel 3 / channel 1 is not counting.
; ---------------------------------------------------------------------------
tk_start:
	ld a,#TICK_SCALE
	ld (ctc_tc),a
	xor a
	ld (tk_acc + 0),a
	ld (tk_acc + 1),a
	ld (tk_acc + 2),a
	ld (tk_acc + 3),a
	ld a,(no_timer)
	or a
	jr nz,tk_start_done

	ld a,#CTC_POLLED
	out (CTC_A),a
	ld a,#CTC_TC_A
	out (CTC_A),a			; the time constant starts the counter
	ld a,#CTC_POLLED
	out (CTC_B),a
	ld a,#CTC_TC_B
	out (CTC_B),a

	; A channel that is programmed but not counting reads as a constant, and
	; a constant residue is indistinguishable from "no time passed".  That
	; would report an infinitely fast disk, so it is checked, not assumed.
	call tk_verify
	or a
	ret nz

	in a,(CTC_A)
	ld (tk_last_a),a
	in a,(CTC_B)
	ld (tk_last_b),a
tk_start_done:
	xor a
	ret

; Both channels must move over about 330 us, which is about 200 steps -- less
; than one full wrap, so a channel that moved cannot read back its old residue.
; Out: A = 0, 1 or 2.
tk_verify:
	in a,(CTC_A)
	ld c,a
	ld b,#0
tk_spin_a:
	djnz tk_spin_a
	in a,(CTC_A)
	cp c
	jr z,tk_dead_a
	in a,(CTC_B)
	ld c,a
	ld b,#0
tk_spin_b:
	djnz tk_spin_b
	in a,(CTC_B)
	cp c
	jr z,tk_dead_b
	xor a
	ret
tk_dead_a:
	ld a,#1
	ret
tk_dead_b:
	ld a,#2
	ret

tk_stop:
	ld a,(no_timer)
	or a
	ret nz
	ld a,#CTC_STOP
	out (CTC_A),a
	ld a,#CTC_STOP
	out (CTC_B),a
	ret

; ---------------------------------------------------------------------------
; tk_read — advance the 32-bit time base from both counters, return it in acc32.
;
; Only differences between two tk_read results are ever used, so what has to
; stay inside the ~104 ms range is the interval being measured -- not the run.
; ---------------------------------------------------------------------------
tk_read:
	ld a,(no_timer)
	or a
	jr nz,tk_read_zero

	; SAMPLE BOTH CHANNELS IN ONE EPOCH.
	;
	; They are read by two separate IN instructions about a microsecond apart,
	; and a counter step is 1.6 us -- so a step frequently lands between the
	; two reads.  The two residues then describe different instants, and the
	; remainder combine turns that one-step skew into a 256-step error:
	; 0.41 ms.  A handful of those once dominated a total made of 15 ms reads,
	; which is how the benchmark reported a slower figure for a run that
	; finished sooner.  Reading channel 1 either side of channel 3 and
	; retrying when it moved makes the pair consistent by construction.
tk_sample:
	in a,(CTC_B)
	ld e,a				; E = channel 1, before
	in a,(CTC_A)
	ld c,a				; C = channel 3
	in a,(CTC_B)
	cp e
	jr nz,tk_sample			; channel 1 moved: the pair is not one epoch

	ld hl,#tk_last_a
	ld a,(hl)
	ld (hl),c
	sub c				; both channels count DOWN
	ld d,a				; D = a, the residue mod 256

	ld hl,#tk_last_b
	ld a,(hl)
	ld (hl),e
	sub e
	jr nc,tk_b_ok
	dec a				; an 8-bit borrow is 256; this wants 255
tk_b_ok:
	ld b,a				; B = b, the residue mod 255

	ld a,d				; a mod 255, for the combine
	cp #255
	jr nz,tk_have_am
	xor a
tk_have_am:
	ld c,a
	ld a,b
	sub c				; k = (b - (a mod 255)) mod 255
	jr nc,tk_have_k
	add a,#255
tk_have_k:
	ld h,a				; elapsed = a + 256 * k
	ld l,d

	ld de,#tk_acc
	call n_add_hl_to
tk_read_done:
	ld hl,#tk_acc
	jp n_load_acc
tk_read_zero:
	jp n_zero_acc

tk_acc:		.ds 4
tk_last_a:	.ds 1
tk_last_b:	.ds 1

; ---------------------------------------------------------------------------
; 32-bit arithmetic.
;
; Two operand slots and one result, all in memory: a Z80 has nowhere to keep two
; 32-bit values in registers and still address a third.  Everything here is
; little-endian, which is what the ISR counter and the IOC wire format both are.
; ---------------------------------------------------------------------------

; HL -> four bytes; acc32 = them.
n_load_acc:
	ld de,#acc32
	ld bc,#4
	ldir
	ret

; HL -> four bytes; arg32 = them.
n_load_arg:
	ld de,#arg32
	ld bc,#4
	ldir
	ret

; HL -> four bytes; they = acc32.
n_store_acc:
	ex de,hl
	ld hl,#acc32
	ld bc,#4
	ldir
	ret

n_zero_acc:
	xor a
	ld (acc32 + 0),a
	ld (acc32 + 1),a
	ld (acc32 + 2),a
	ld (acc32 + 3),a
	ret

; acc32 = HL, zero extended.
n_acc_from_hl:
	ld (acc32 + 0),hl
	xor a
	ld (acc32 + 2),a
	ld (acc32 + 3),a
	ret

; Z set when acc32 is zero.  Clobbers A and HL.
n_acc_is_zero:
	ld hl,#acc32
	ld a,(hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	ret

; acc32 += arg32.  Neither ld a,(de) nor inc carries flags, so the chain is safe.
n_add:
	ld hl,#acc32
	ld de,#arg32
	or a				; clear carry
	ld b,#4
n_add_loop:
	ld a,(de)
	adc a,(hl)
	ld (hl),a
	inc hl
	inc de
	djnz n_add_loop
	ret

; acc32 -= arg32.
n_sub:
	ld hl,#acc32
	ld de,#arg32
	or a
	ld b,#4
n_sub_loop:
	ld a,(de)
	ld c,a
	ld a,(hl)
	sbc a,c
	ld (hl),a
	inc hl
	inc de
	djnz n_sub_loop
	ret

; Compare acc32 with arg32, most significant byte first.  Carry set = acc < arg,
; Z set = equal.
n_cmp:
	ld hl,#acc32 + 3
	ld de,#arg32 + 3
	ld b,#4
n_cmp_loop:
	ld a,(de)
	ld c,a
	ld a,(hl)
	cp c
	ret nz
	dec hl
	dec de
	djnz n_cmp_loop
	ret

; acc32 *= BC.  Shift and add, low bit of the multiplier first.  The product is
; truncated to 32 bits; every caller here bounds its operands first.
n_mul16:
	ld (n_mul_m),bc
	ld hl,#acc32
	call n_load_arg			; arg32 = the multiplicand, shifted below
	call n_zero_acc
	ld b,#16
n_mul_loop:
	push bc
	ld hl,(n_mul_m)
	ld a,h
	or l
	jr z,n_mul_done			; nothing left in the multiplier
	ld a,l
	and #1
	jr z,n_mul_skip
	call n_add
n_mul_skip:
	ld hl,(n_mul_m)
	srl h
	rr l
	ld (n_mul_m),hl
	call n_shl_arg
	pop bc
	djnz n_mul_loop
	ret
n_mul_done:
	pop bc
	ret

n_shl_arg:
	ld hl,#arg32
	ld b,#4
	or a				; clear carry into the low bit
n_shl_arg_loop:
	rl (hl)
	inc hl
	djnz n_shl_arg_loop
	ret

n_shl_acc:
	ld hl,#acc32
	ld b,#4
	or a
n_shl_acc_loop:
	rl (hl)
	inc hl
	djnz n_shl_acc_loop
	ret				; carry = the bit shifted out of the top

; acc32 /= BC; the remainder is left in n_rem.  Restoring division, MSB first.
;
; The remainder is doubled before every trial subtraction, so with a divisor
; above 32767 it can need seventeen bits.  Carrying that bit out of `adc hl,hl`
; and forcing the subtraction when it is set is what makes a divisor of 65535
; work; without it this would quietly produce a wrong answer for exactly the
; large read counts a long run generates.
n_div16:
	ld (n_div_d),bc
	ld hl,#0
	ld (n_rem),hl
	ld b,#32
n_div_loop:
	push bc
	call n_shl_acc			; carry = the bit leaving acc32
	ld hl,(n_rem)
	adc hl,hl			; remainder = remainder * 2 + that bit
	ld a,#0
	adc a,#0			; A = 1 when the remainder needed 17 bits
	ld (n_rem),hl
	ld de,(n_div_d)
	or a				; clear carry; A is untouched
	sbc hl,de
	jr nc,n_div_take
	or a				; did the remainder overflow 16 bits?
	jr z,n_div_next			; no, and it borrowed: remainder < divisor
n_div_take:
	ld (n_rem),hl
	ld hl,#acc32
	set 0,(hl)
n_div_next:
	pop bc
	djnz n_div_loop
	ret

; acc32 /= div32; the remainder is left in rem32.  Same restoring division as
; n_div16, widened so that no caller has to keep its divisor inside 16 bits.
; Throughput is bytes * 1000 / milliseconds, and a run of more than 65 seconds
; puts that divisor out of 16-bit range -- which is well inside what a large
; file on a slow card takes, so the narrow form would have failed on exactly the
; runs worth measuring.
n_div32:
	call n_rem32_zero
	ld b,#32
n_div32_loop:
	push bc
	call n_shl_acc			; carry = the bit leaving acc32
	call n_shl_rem			; remainder = remainder * 2 + that bit
	ld a,#0
	adc a,#0			; A = 1 when the remainder needed 33 bits
	ld (n_ovf),a
	call n_rem_minus_div		; tmp32 = remainder - divisor
	jr nc,n_div32_take
	ld a,(n_ovf)
	or a
	jr z,n_div32_next
n_div32_take:
	ld hl,#tmp32
	ld de,#rem32
	ld bc,#4
	ldir
	ld hl,#acc32
	set 0,(hl)
n_div32_next:
	pop bc
	djnz n_div32_loop
	ret

; HL -> four bytes; div32 = them.
n_load_div:
	ld de,#div32
	ld bc,#4
	ldir
	ret

; The incoming carry is the bit being shifted in, so nothing here may clear it.
; ld, call and djnz all leave the flags alone; only the rl instructions touch them.
n_shl_rem:
	ld hl,#rem32
	ld b,#4
n_shl_rem_loop:
	rl (hl)
	inc hl
	djnz n_shl_rem_loop
	ret

n_rem_minus_div:
	ld hl,#rem32
	ld de,#tmp32
	ld bc,#4
	ldir
	ld hl,#tmp32
	ld de,#div32
	or a
	ld b,#4
n_rmd_loop:
	ld a,(de)
	ld c,a
	ld a,(hl)
	sbc a,c
	ld (hl),a
	inc hl
	inc de
	djnz n_rmd_loop
	ret				; carry = borrow

n_rem32_zero:
	xor a
	ld (rem32 + 0),a
	ld (rem32 + 1),a
	ld (rem32 + 2),a
	ld (rem32 + 3),a
	ret

; HL -> destination, DE -> source: *HL += *DE.  Clobbers acc32 and arg32.
n_add_to:
	push hl
	ex de,hl
	call n_load_arg
	pop hl
	push hl
	call n_load_acc
	call n_add
	pop hl
	jp n_store_acc

; HL -> destination, DE -> source: *HL -= *DE.
n_sub_from:
	push hl
	ex de,hl
	call n_load_arg
	pop hl
	push hl
	call n_load_acc
	call n_sub
	pop hl
	jp n_store_acc

; Add HL, zero extended, to the four bytes at DE.
n_add_hl_to:
	push de
	call n_acc_from_hl
	ld hl,#acc32
	call n_load_arg
	pop hl
	push hl
	call n_load_acc
	call n_add
	pop hl
	jp n_store_acc

; ---------------------------------------------------------------------------
; Tick arithmetic.
;
; One tick is TC * 1.6 us, so ticks * TC is time in 1.6 us units and every
; conversion below is written in terms of that product.  A sampled interval can
; never exceed the 65280-step alias-free ceiling, so the largest intermediate,
; (ticks * TC) * 16 in ms_from_ticks, stays far inside 32 bits.  No benchmark
; run here comes close; a soak test should not use these routines.
; ---------------------------------------------------------------------------

; acc32 = ticks -> acc32 = elapsed milliseconds.
; ms = ticks * TC * 16 / 10000 = ticks * TC / 625.
ms_from_ticks:
	call n_mul_tc
	ld bc,#16
	call n_mul16
	ld bc,#625
	jp n_div16

; acc32 = ticks -> acc32 = elapsed milliseconds * 100.
; ms * 100 = ticks * TC * 1.6 * 100 / 1000 = ticks * TC * 16 / 100.
msx100_from_ticks:
	call n_mul_tc
	ld bc,#16
	call n_mul16
	ld bc,#100
	jp n_div16

n_mul_tc:
	ld a,(ctc_tc)
	ld c,a
	ld b,#0
	jp n_mul16

; ---------------------------------------------------------------------------
; Decimal output.
;
; Digits come out least significant first, so they are collected and then
; emitted backwards.  Ten is the most a 32-bit value can need.
; ---------------------------------------------------------------------------

; Print acc32 in decimal.  Destroys acc32.
print_dec32:
	xor a
	ld (n_dec_n),a
	ld hl,#n_dec_buf
	ld (n_dec_p),hl
print_dec32_gather:
	ld bc,#10
	call n_div16
	ld a,(n_rem)
	add a,#'0'
	ld hl,(n_dec_p)
	ld (hl),a
	inc hl
	ld (n_dec_p),hl
	ld hl,#n_dec_n
	inc (hl)
	call n_acc_is_zero
	jr nz,print_dec32_gather
	ld a,(n_dec_n)
	ld b,a
	ld hl,(n_dec_p)
print_dec32_emit:
	dec hl
	push bc
	push hl
	ld e,(hl)
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	djnz print_dec32_emit
	ret

; Print acc32 in decimal, right aligned in the field width in A.  A value too
; wide for the field is printed in full rather than truncated: a benchmark that
; silently drops a digit from a throughput figure is worse than a ragged column.
print_dec32_pad:
	ld (n_pad_w),a
	xor a
	ld (n_dec_n),a
	ld hl,#n_dec_buf
	ld (n_dec_p),hl
print_pad_gather:
	ld bc,#10
	call n_div16
	ld a,(n_rem)
	add a,#'0'
	ld hl,(n_dec_p)
	ld (hl),a
	inc hl
	ld (n_dec_p),hl
	ld hl,#n_dec_n
	inc (hl)
	call n_acc_is_zero
	jr nz,print_pad_gather
	ld a,(n_pad_w)
	ld hl,#n_dec_n
	sub (hl)
	jr c,print_pad_emit
	jr z,print_pad_emit
	ld b,a
print_pad_space:
	push bc
	call space
	pop bc
	djnz print_pad_space
print_pad_emit:
	ld a,(n_dec_n)
	ld b,a
	ld hl,(n_dec_p)
print_pad_out:
	dec hl
	push bc
	push hl
	ld e,(hl)
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	djnz print_pad_out
	ret

; Print acc32, which holds a value scaled by 100, as n.nn.  Destroys acc32.
; The two decimals are exact: acc32 came from an integer tick count through
; msx100_from_ticks, so nothing here invents precision the clock does not have.
print_x100:
	ld bc,#100
	call n_div16
	ld a,(n_rem)
	ld (n_frac),a
	call print_dec32
	ld e,#'.'
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(n_frac)
	ld b,#'0'
print_x100_tens:
	cp #10
	jr c,print_x100_emit
	sub #10
	inc b
	jr print_x100_tens
print_x100_emit:
	push af
	ld e,b
	ld c,#BDOS_CONOUT
	call BDOS
	pop af
	add a,#'0'
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

; print_x100 right aligned in the field width in A.  The integer part is padded
; to width - 3, which is the field less the point and the two decimals.
print_x100_pad:
	sub #3
	jr nc,print_x100_pad_ok
	xor a
print_x100_pad_ok:
	ld (n_pad_x),a
	ld bc,#100
	call n_div16
	ld a,(n_rem)
	ld (n_frac),a
	ld a,(n_pad_x)
	call print_dec32_pad
	ld e,#'.'
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(n_frac)
	ld b,#'0'
print_x100_pad_tens:
	cp #10
	jr c,print_x100_pad_emit
	sub #10
	inc b
	jr print_x100_pad_tens
print_x100_pad_emit:
	push af
	ld e,b
	ld c,#BDOS_CONOUT
	call BDOS
	pop af
	add a,#'0'
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

space:
	ld e,#' '
	ld c,#BDOS_CONOUT
	jp BDOS

acc32:		.ds 4
arg32:		.ds 4
div32:		.ds 4
rem32:		.ds 4
tmp32:		.ds 4
n_ovf:		.ds 1
n_mul_m:	.ds 2
n_div_d:	.ds 2
n_rem:		.ds 2
n_dec_p:	.ds 2
n_dec_n:	.ds 1
n_pad_w:	.ds 1
n_pad_x:	.ds 1
n_frac:		.ds 1
n_dec_buf:	.ds 12
ctc_tc:		.ds 1
