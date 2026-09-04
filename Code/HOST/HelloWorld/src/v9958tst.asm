; Zephyr-80 V9958 VRAM datapath and access-timing diagnostic.
; CPU: Z80
; Assembler: SDCC sdasz80 / ASxxxx Z80 syntax
;
; This is a console-reporting diagnostic for the direct-hardware Lunch Crema
; V9958 card. It does not select a display mode, touch R#0..R#11, initialize a
; palette, or depend on the V9958 display output. Only R#14 and the VRAM
; address/data ports are used.
;
; Build:
;   make build/v9958tst.com
;
; Run from CP/M:
;   V9958TST S    slow VDP accesses (DELAY_COUNT iterations per access)
;   V9958TST F    fast VDP accesses (no added delay)
;
; Interpretation:
;   slow pass + fast pass  -> VRAM datapath and access timing are both good
;   slow pass + fast fail  -> datapath is good; access timing is the fault
;   slow fail              -> speed-independent VRAM wiring/datapath fault
;   R14-BANK fail          -> R#14 or upper VRAM address selection is faulty
;   slow MARCH pass + OTIR-STRESS fail
;                           -> OTIR overruns VDP write recovery
;
; Tests 1-3 use the selected delay. OTIR-STRESS always writes its 256-byte
; block at full OTIR cadence, matching mandelbrot_v9958_real.asm. Its readback
; is deliberately padded so a write-timing failure is not confused with a
; read-timing failure. Each test stops at its first mismatch.

	.module v9958tst
	.area CODE (ABS)
	.org 0x0100

; ---------------------------------------------------------------------------
; CP/M interface
; ---------------------------------------------------------------------------

BDOS			= 0x0005
BDOS_EXIT		= 0x00
BDOS_CONOUT		= 0x02
BDOS_PRINT		= 0x09

CMD_TAIL_LENGTH		= 0x0080
CMD_TAIL_TEXT		= 0x0081

; ---------------------------------------------------------------------------
; V9958 direct-hardware interface
; Copied from mandelbrot_v9958_real.asm / the IO_DECODER mapping.
; ---------------------------------------------------------------------------

VDP_DATA		= 0xa0
VDP_CMD			= 0xa1
VDP_PAL			= 0xa2
VDP_REG			= 0xa3
VDP_CONFIG		= 0xa4		; A2=1 selects LunchCrema /INT_MODE

; U3 captures D0 and D1 together. D0=0 preserves the reset-default interrupt
; route. D1=1 drives physical /WS_EN high and bypasses only U11's porch;
; D1=0 drives /WS_EN low and enables the porch. Native V9958 /WAIT continues
; to propagate through U11 in either state.
VDP_CONFIG_PORCH_ON	= 0x00
VDP_CONFIG_PORCH_OFF	= 0x02

V9958_R25_WAIT_OFF	= 0x00		; WTE=0, VDS=0
V9958_R25_WAIT_ON	= 0x04		; WTE=1, VDS=0
V9958_R8_64K_DRAM	= 0x08		; VR=1 for 64Kx1/64Kx4 DRAMs

; Extra delay used by slow mode after each VDP port access. Fast mode changes
; the first opcode of vdp_access_delay to RET, leaving the access paths intact.
DELAY_COUNT		= 16

DATA_PATTERN_COUNT	= 20
MARCH_END_HIGH		= 0x10		; exclusive end: 0x1000
AUTOINC_ADDRESS		= 0x0200
OTIR_ADDRESS		= 0x0400
R14_BANK_OFFSET		= 0x0123

; ---------------------------------------------------------------------------
; Entry point and command-tail parsing
; ---------------------------------------------------------------------------

start:
	ld de,#msg_banner
	call print_string

	ld a,(CMD_TAIL_LENGTH)
	or a
	jp z,show_usage
	ld b,a
	ld hl,#CMD_TAIL_TEXT

parse_mode_skip_space:
	ld a,(hl)
	cp #' '
	jr nz,parse_mode_character
	inc hl
	djnz parse_mode_skip_space
	jp show_usage

parse_mode_character:
	and #0xdf			; accept lower-case input
	cp #'S'
	jr z,select_slow_mode
	cp #'F'
	jp nz,show_usage

select_fast_mode:
	ld a,#0xc9			; RET: disable the DJNZ delay body
	ld (vdp_access_delay),a
	ld de,#msg_mode_fast
	call print_string
	jr run_tests

select_slow_mode:
	ld de,#msg_mode_slow
	call print_string

run_tests:
	ld a,#VDP_CONFIG_PORCH_OFF
	out (VDP_CONFIG),a
	ld de,#msg_porch_off
	call print_string

	ld de,#msg_wte_disabling
	call print_string
	ld a,#V9958_R25_WAIT_OFF
	ld b,#25
	call vdp_write_register_delayed
	ld de,#msg_ok
	call print_string

	ld de,#msg_r8_64k
	call print_string
	ld a,#V9958_R8_64K_DRAM
	ld b,#8
	call vdp_write_register_delayed
	ld de,#msg_ok
	call print_string

	ld de,#msg_wte_enabling
	call print_string
	ld a,#V9958_R25_WAIT_ON
	ld b,#25
	call vdp_write_register_delayed
	ld de,#msg_ok
	call print_string

	ld a,#VDP_CONFIG_PORCH_ON
	out (VDP_CONFIG),a
	ld de,#msg_porch_on
	call print_string

	call test_databus
	call test_march
	call test_autoinc
	call test_r14_banks
	call test_otir_stress

	ld de,#msg_done
	call print_string
	jr exit_program

show_usage:
	ld de,#msg_usage
	call print_string

exit_program:
	ld c,#BDOS_EXIT
	jp BDOS

; ---------------------------------------------------------------------------
; Test 1: data bus patterns at VRAM address 0000h
; ---------------------------------------------------------------------------

test_databus:
	ld de,#msg_databus
	call print_string
	call vdp_reset_r14_delayed

	ld hl,#data_patterns
	ld (pattern_pointer),hl
	ld c,#DATA_PATTERN_COUNT

databus_loop:
	ld hl,(pattern_pointer)
	ld a,(hl)
	ld (fail_expected),a
	push bc

	ld hl,#0x0000
	call vdp_set_vram_write_addr_delayed
	ld a,(fail_expected)
	call vdp_data_write_delayed

	ld hl,#0x0000
	call vdp_set_vram_read_addr_delayed
	call vdp_data_read_delayed
	ld (fail_actual),a

	pop bc
	ld a,(fail_actual)
	ld e,a
	ld a,(fail_expected)
	cp e
	jr nz,databus_fail

	ld hl,(pattern_pointer)
	inc hl
	ld (pattern_pointer),hl
	dec c
	jr nz,databus_loop

	ld de,#msg_ok
	jp print_string

databus_fail:
	ld hl,#0x0000
	ld (fail_address),hl
	jp report_failure

; ---------------------------------------------------------------------------
; Test 2: 0000h-0FFFh address/data march using value = H XOR L
; ---------------------------------------------------------------------------

test_march:
	ld de,#msg_march
	call print_string
	call vdp_reset_r14_delayed

	ld hl,#0x0000
	call vdp_set_vram_write_addr_delayed
	ld hl,#0x0000

march_write_loop:
	ld a,h
	xor l
	call vdp_data_write_delayed
	inc hl
	ld a,h
	cp #MARCH_END_HIGH
	jr nz,march_write_loop

	ld hl,#0x0000
	call vdp_set_vram_read_addr_delayed
	ld hl,#0x0000

march_read_loop:
	call vdp_data_read_delayed
	ld e,a
	ld a,h
	xor l
	cp e
	jr nz,march_fail
	inc hl
	ld a,h
	cp #MARCH_END_HIGH
	jr nz,march_read_loop

	ld de,#msg_ok
	jp print_string

march_fail:
	ld (fail_address),hl
	ld (fail_expected),a
	ld a,e
	ld (fail_actual),a
	jp report_failure

; ---------------------------------------------------------------------------
; Test 3: 256-byte auto-increment sequence at 0200h
; ---------------------------------------------------------------------------

test_autoinc:
	ld de,#msg_autoinc
	call print_string
	call vdp_reset_r14_delayed

	ld hl,#AUTOINC_ADDRESS
	call vdp_set_vram_write_addr_delayed
	ld e,#0x00

autoinc_write_loop:
	ld a,e
	call vdp_data_write_delayed
	inc e
	jr nz,autoinc_write_loop

	ld hl,#AUTOINC_ADDRESS
	call vdp_set_vram_read_addr_delayed
	ld hl,#AUTOINC_ADDRESS
	ld e,#0x00

autoinc_read_loop:
	call vdp_data_read_delayed
	cp e
	jr nz,autoinc_fail
	inc e
	inc hl
	ld a,e
	or a
	jr nz,autoinc_read_loop

	ld de,#msg_ok
	jp print_string

autoinc_fail:
	ld d,a				; actual byte
	ld (fail_address),hl
	ld a,e
	ld (fail_expected),a
	ld a,d
	ld (fail_actual),a
	jp report_failure

; ---------------------------------------------------------------------------
; Test 4: R#14 selection of the four 16 KiB regions used by Mandelbrot
; ---------------------------------------------------------------------------

test_r14_banks:
	ld de,#msg_r14_banks
	call print_string

	ld hl,#R14_BANK_OFFSET
	call vdp_set_vram_write_addr_delayed
	ld a,#0x12
	call vdp_data_write_delayed

	ld hl,#(0x4000 + R14_BANK_OFFSET)
	call vdp_set_vram_write_addr_delayed
	ld a,#0x34
	call vdp_data_write_delayed

	ld hl,#(0x8000 + R14_BANK_OFFSET)
	call vdp_set_vram_write_addr_delayed
	ld a,#0x56
	call vdp_data_write_delayed

	ld hl,#(0xc000 + R14_BANK_OFFSET)
	call vdp_set_vram_write_addr_delayed
	ld a,#0x78
	call vdp_data_write_delayed

	ld hl,#R14_BANK_OFFSET
	ld a,#0x12
	call check_r14_bank_byte
	jp nz,report_failure

	ld hl,#(0x4000 + R14_BANK_OFFSET)
	ld a,#0x34
	call check_r14_bank_byte
	jp nz,report_failure

	ld hl,#(0x8000 + R14_BANK_OFFSET)
	ld a,#0x56
	call check_r14_bank_byte
	jp nz,report_failure

	ld hl,#(0xc000 + R14_BANK_OFFSET)
	ld a,#0x78
	call check_r14_bank_byte
	jp nz,report_failure

	ld de,#msg_ok
	jp print_string

; Input: HL=absolute VRAM address, A=expected byte.
; Output: Z if the byte matches, NZ otherwise. Records failure details.
check_r14_bank_byte:
	ld (fail_address),hl
	ld (fail_expected),a
	call vdp_set_vram_read_addr_delayed
	call vdp_data_read_delayed
	ld (fail_actual),a
	ld e,a
	ld a,(fail_expected)
	cp e
	ret

; ---------------------------------------------------------------------------
; Test 5: full-cadence OTIR write, padded scalar readback
; ---------------------------------------------------------------------------

test_otir_stress:
	ld de,#msg_otir
	call print_string
	call vdp_reset_r14_raw

	; Prepare the source buffer without involving the VDP access delay.
	ld hl,#otir_buffer
	ld b,#0x00
otir_fill_loop:
	ld a,b
	xor #0xa5
	ld (hl),a
	inc hl
	inc b
	jr nz,otir_fill_loop

	; Address setup and the 256-byte transfer are intentionally unpadded.
	ld hl,#OTIR_ADDRESS
	call vdp_set_vram_write_addr_raw
	ld hl,#otir_buffer
	ld c,#VDP_DATA
	ld b,#0x00			; OTIR interprets zero as 256 bytes
	otir

	; Force slow verification even when the command selected fast mode.
	ld a,#0xc5			; PUSH BC: restore vdp_access_delay body
	ld (vdp_access_delay),a
	ld hl,#OTIR_ADDRESS
	call vdp_set_vram_read_addr_delayed
	ld hl,#OTIR_ADDRESS
	ld e,#0x00

otir_read_loop:
	call vdp_data_read_delayed
	ld d,a
	ld a,e
	xor #0xa5
	cp d
	jr nz,otir_fail
	inc e
	inc hl
	ld a,e
	or a
	jr nz,otir_read_loop

	ld de,#msg_ok
	jp print_string

otir_fail:
	ld (fail_address),hl
	ld (fail_expected),a
	ld a,d
	ld (fail_actual),a
	jp report_failure

; ---------------------------------------------------------------------------
; V9958 delayed access helpers for tests 1-3 and OTIR verification
; ---------------------------------------------------------------------------

; Add DELAY_COUNT DJNZ iterations after a VDP port access.
; Preserves: AF, BC, DE, HL. Does not access the VDP and is not ISR-safe.
; Fast mode replaces the first opcode (PUSH BC) with RET.
vdp_access_delay:
	push bc
	ld b,#DELAY_COUNT
vdp_access_delay_loop:
	djnz vdp_access_delay_loop
	pop bc
	ret

; Write V9958 register B with value A, delaying after both command-port OUTs.
; Inputs: A=value, B=register. Clobbers: AF. May block briefly in slow mode.
vdp_write_register_delayed:
	out (VDP_CMD),a
	call vdp_access_delay
	ld a,b
	or #0x80
	out (VDP_CMD),a
	call vdp_access_delay
	ret

; Explicitly reset the VRAM high-address latch before a delayed test.
; Clobbers: AF, B. May block briefly in slow mode.
vdp_reset_r14_delayed:
	xor a
	ld b,#14
	jp vdp_write_register_delayed

; Set the VRAM auto-increment write address. Input: HL=00000h..0FFFFh.
; Clobbers: AF. May block briefly in slow mode.
vdp_set_vram_write_addr_delayed:
	ld a,h
	rlca
	rlca
	and #0x03			; A15..A14 -> R#14 bits 1..0
	push bc
	ld b,#14
	call vdp_write_register_delayed
	pop bc

	ld a,l
	out (VDP_CMD),a
	call vdp_access_delay
	ld a,h
	and #0x3f
	or #0x40			; bit 6 = VRAM write address
	out (VDP_CMD),a
	call vdp_access_delay
	ret

; Set the VRAM auto-increment read address. Input: HL=00000h..0FFFFh.
; The V9958 prefetches the selected byte during address setup, so the first
; subsequent IN returns [HL], then the pointer advances. Clobbers: AF.
vdp_set_vram_read_addr_delayed:
	ld a,h
	rlca
	rlca
	and #0x03			; A15..A14 -> R#14 bits 1..0
	push bc
	ld b,#14
	call vdp_write_register_delayed
	pop bc

	ld a,l
	out (VDP_CMD),a
	call vdp_access_delay
	ld a,h
	and #0x3f			; bit 6 = 0 for VRAM read address
	out (VDP_CMD),a
	call vdp_access_delay
	ret

; Write/read one VRAM byte with the selected post-access delay.
; Input/output: A=data. Clobbers: flags only. May block briefly in slow mode.
vdp_data_write_delayed:
	out (VDP_DATA),a
	call vdp_access_delay
	ret

vdp_data_read_delayed:
	in a,(VDP_DATA)
	call vdp_access_delay
	ret

; ---------------------------------------------------------------------------
; Raw V9958 access helpers used only by the OTIR write phase
; ---------------------------------------------------------------------------

; Write V9958 register B with value A. Clobbers: AF. No added delay.
vdp_write_register_raw:
	out (VDP_CMD),a
	ld a,b
	or #0x80
	out (VDP_CMD),a
	ret

; Explicitly reset the VRAM high-address latch before OTIR-STRESS.
; Clobbers: AF, B. No added delay.
vdp_reset_r14_raw:
	xor a
	ld b,#14
	jp vdp_write_register_raw

; Set the VRAM auto-increment write address. Input: HL=00000h..0FFFFh.
; Clobbers: AF. No added delay.
vdp_set_vram_write_addr_raw:
	ld a,h
	rlca
	rlca
	and #0x03
	push bc
	ld b,#14
	call vdp_write_register_raw
	pop bc

	ld a,l
	out (VDP_CMD),a
	ld a,h
	and #0x3f
	or #0x40
	out (VDP_CMD),a
	ret

; ---------------------------------------------------------------------------
; Console reporting
; ---------------------------------------------------------------------------

report_failure:
	ld de,#msg_fail_exp
	call print_string
	ld a,(fail_expected)
	call print_hex_byte
	ld de,#msg_actual
	call print_string
	ld a,(fail_actual)
	call print_hex_byte
	ld de,#msg_address
	call print_string
	ld hl,(fail_address)
	call print_hex_word
	ld de,#msg_crlf
	jp print_string

; Input: DE points to a '$'-terminated string. Clobbers: AF, BC, DE.
print_string:
	ld c,#BDOS_PRINT
	jp BDOS

; Input: HL=value. Clobbers: AF, BC, DE.
print_hex_word:
	ld a,h
	push hl
	call print_hex_byte
	pop hl
	ld a,l
	; fall through

; Input: A=value. Clobbers: AF, BC, DE.
print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
	; fall through

print_hex_nibble:
	add a,#0x30
	cp #0x3a
	jr c,print_hex_digit
	add a,#0x07
print_hex_digit:
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

; ---------------------------------------------------------------------------
; Data and workspace
; ---------------------------------------------------------------------------

msg_banner:
	.ascii "V9958 VRAM/timing diagnostic"
	.db 0x0d,0x0a,'$'
msg_mode_slow:
	.ascii "Mode: SLOW"
	.db 0x0d,0x0a,'$'
msg_mode_fast:
	.ascii "Mode: FAST"
	.db 0x0d,0x0a,'$'
msg_usage:
	.ascii "Usage: V9958TST S | V9958TST F"
	.db 0x0d,0x0a,'$'
msg_databus:
	.ascii "DATABUS: $"
msg_porch_off:
	.ascii "WAIT porch: OFF (native WAIT active)"
	.db 0x0d,0x0a,'$'
msg_wte_disabling:
	.ascii "R25 WTE: disabling... $"
msg_r8_64k:
	.ascii "R8 VR: 64K DRAM... $"
msg_wte_enabling:
	.ascii "R25 WTE: enabling... $"
msg_porch_on:
	.ascii "WAIT porch: ON (native WAIT active)"
	.db 0x0d,0x0a,'$'
msg_march:
	.ascii "MARCH: $"
msg_autoinc:
	.ascii "AUTOINC: $"
msg_r14_banks:
	.ascii "R14-BANK: $"
msg_otir:
	.ascii "OTIR-STRESS: $"
msg_ok:
	.ascii "OK"
	.db 0x0d,0x0a,'$'
msg_fail_exp:
	.ascii "FAIL exp=$"
msg_actual:
	.ascii " act=$"
msg_address:
	.ascii " @$"
msg_done:
	.ascii "DONE"
	.db 0x0d,0x0a,'$'
msg_crlf:
	.db 0x0d,0x0a,'$'

data_patterns:
	.db 0x00,0xff
	.db 0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80
	.db 0xfe,0xfd,0xfb,0xf7,0xef,0xdf,0xbf,0x7f
	.db 0x55,0xaa

pattern_pointer:
	.dw 0x0000
fail_address:
	.dw 0x0000
fail_expected:
	.db 0x00
fail_actual:
	.db 0x00

otir_buffer:
	.ds 256
