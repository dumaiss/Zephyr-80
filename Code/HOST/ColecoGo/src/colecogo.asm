; COLECOGO.COM -- CP/M launcher for ColecoVision software on Zephyr-80.
;
; CPU:       Z80
; Assembler: SDCC / ASxxxx sdasz80
; Entry:     CP/M transient-program origin 0100h
;
; This is a one-way takeover. All fallible CP/M file operations finish before
; bank 7 or common RAM is changed. Once construct_target_bank begins, there is
; deliberately no error or return path.

	.module colecogo
	.area CODE (ABS)
	.org 0x0100

; ---------------------------------------------------------------------------
; CP/M 2.2 BDOS interface.
; ---------------------------------------------------------------------------
BDOS			= 0x0005
BDOS_PRINT		= 0x09
BDOS_OPEN		= 0x0f
BDOS_CLOSE		= 0x10
BDOS_READ_SEQ		= 0x14
BDOS_SET_DMA		= 0x1a
BDOS_FILE_SIZE		= 0x23

DEFAULT_FCB		= 0x005c
DEFAULT_DMA		= 0x0080
FCB_NAME_BYTES		= 12
FCB_BYTES		= 36
FCB_R0			= 33
FCB_R1			= 34
FCB_R2			= 35

; ---------------------------------------------------------------------------
; Zephyr extended BIOS ABI. These are public jump-table entries, not internal
; map-file helper addresses. Keep in sync with CPM2.2 ZBIOS_EXT_BASE at DA33h.
; ---------------------------------------------------------------------------
ZBIOS_MOVE		= 0xda33
ZBIOS_XMOVE		= 0xda36
ZBIOS_SETBNK		= 0xda3c

; ---------------------------------------------------------------------------
; Zephyr hardware and takeover layout.
; ---------------------------------------------------------------------------
BANK_PORT		= 0x00
RAM_BANK_MASK		= 0x07
ROMDIS_BIT		= 0x10
TARGET_BANK		= 0x07
TARGET_BANK_LATCH	= ROMDIS_BIT | TARGET_BANK

BIOS_BUFFER		= 0x1800
BIOS_BYTES		= 0x2000
CART_BUFFER		= BIOS_BUFFER + BIOS_BYTES	; 3800h
CART_HALF_BYTES		= 0x4000
CART_BYTES		= 0x8000
CART_BUFFER_END		= CART_BUFFER + CART_BYTES	; B800h
PRIVATE_STACK_TOP	= 0xbc00

TARGET_BIOS		= 0x0000
TARGET_UPPER_STAGE	= 0x2000
TARGET_CART_LOWER	= 0x8000
TARGET_STAGE_B		= 0x5f80
TARGET_TAIL_BACKUP	= 0x7f80
TARGET_CART_TAIL	= 0xff80
STAGE_RECORD_BYTES	= 0x0080
TARGET_UPPER_PREFIX	= CART_HALF_BYTES - STAGE_RECORD_BYTES

COMMON_STAGE_A		= 0xc000
COMMON_STAGE_LIMIT	= 0xc400

; Physical I/O ports from platform_zephyr80.inc.
SIO0A_CTRL		= 0x21
SIO0B_CTRL		= 0x23
SIO1A_CTRL		= 0x31
SIO1B_CTRL		= 0x33
CTC0_CTRL		= 0x40
CTC1_CTRL		= 0x41
CTC2_CTRL		= 0x42
CTC3_CTRL		= 0x43
CTC_RESET_DISABLE	= 0x03

V9958_COMMAND_PORT	= 0xa1
V9958_PALETTE_PORT	= 0xa2
V9958_CONFIG_PORT	= 0xa4
V9958_CONFIG_NMI	= 0x01
V9958_CONFIG_PORCH_OFF	= 0x02
V9958_R8_64K_DRAM	= 0x08
V9958_R25_WAIT_OFF	= 0x00
V9958_R25_WAIT_ON	= 0x04
V9958_BOOT_DELAY_COUNT	= 16

; A ColecoVision selects its TMS9928A across A0h-BFh and uses only A0 to
; distinguish data (even) from command/status (odd). LunchCrema selects the
; V9958 across the same blocks, but passes A1:A0 through as its four-port mode
; selector. Consequently the stock BIOS's BEh/BFh accesses reach the palette
; and indirect-register ports. The loaded standard BIOS is guarded and adapted
; to the native A0h/A1h ports before it is copied into the takeover bank.
COLECO_VDP_DATA_PORT	= 0xbe
COLECO_VDP_COMMAND_PORT	= 0xbf
ZEPHYR_VDP_DATA_PORT	= 0xa0
ZEPHYR_VDP_COMMAND_PORT	= 0xa1
BIOS_PATCH_ENTRY_BYTES	= 4

BIOS_RECORDS		= BIOS_BYTES / 128
CART_MAX_RECORDS	= CART_BYTES / 128

; ===========================================================================
; CP/M loader.
; ===========================================================================

start:
	ld (entry_sp),sp
	ld sp,#PRIVATE_STACK_TOP

	ld de,#msg_banner
	call puts

	; Refuse to call through an absent or incompatible extended jump table.
	ld a,(ZBIOS_MOVE)
	cp #0xc3
	jp nz,error_bios_abi
	ld a,(ZBIOS_XMOVE)
	cp #0xc3
	jp nz,error_bios_abi
	ld a,(ZBIOS_SETBNK)
	cp #0xc3
	jp nz,error_bios_abi

	; The loader and both file buffers live in the currently selected low bank.
	; Selecting that same bank as the target would overwrite the running loader.
	in a,(BANK_PORT)
	and #RAM_BANK_MASK
	ld (source_bank),a
	cp #TARGET_BANK
	jp z,error_target_active

	; Keep the BIOS disk-DMA bank record consistent with our physical source.
	call ZBIOS_SETBNK

	call capture_cart_name
	or a
	jp nz,error_usage

	ld de,#msg_validating
	call puts
	call validate_bios_file
	call validate_cart_file

	; Read every record and close both files before modifying the takeover bank.
	; Any error through this point returns to CP/M with bank 7 untouched.
	ld de,#msg_loading
	call puts
	call load_bios_file
	call adapt_bios_vdp_ports
	call fill_cart_buffer
	call load_cart_file

	; No fallible operation follows this message.
	ld de,#msg_takeover
	call puts
	jp construct_target_bank

; Copy drive/name/type from CP/M's first default FCB and reject a missing name
; or wildcards. CP/M has already performed its normal command-tail parsing.
; Output: A=0 valid, A=1 invalid. Clobbers AF, BC, DE, HL. Does not block.
capture_cart_name:
	ld a,(DEFAULT_FCB + 1)
	cp #' '
	jr z,capture_cart_bad
	ld hl,#DEFAULT_FCB
	ld de,#cart_fcb_name
	ld bc,#FCB_NAME_BYTES
	ldir
	ld hl,#cart_fcb_name + 1
	ld b,#11
capture_cart_wildcard_loop:
	ld a,(hl)
	cp #'?'
	jr z,capture_cart_bad
	inc hl
	djnz capture_cart_wildcard_loop
	xor a
	ret
capture_cart_bad:
	ld a,#1
	ret

; Initialize the working FCB from a 12-byte drive/name/type template in HL.
; Output: work_fcb normalized with all extent/record fields zeroed.
; Clobbers AF, BC, DE, HL. Does not block.
init_work_fcb:
	ld de,#work_fcb
	ld bc,#FCB_NAME_BYTES
	ldir
	xor a
	ld b,#(FCB_BYTES - FCB_NAME_BYTES)
init_work_fcb_clear_loop:
	ld (de),a
	inc de
	djnz init_work_fcb_clear_loop
	ret

; Output: Z set if open failed, Z clear on success. May block in BDOS.
open_work_fcb:
	ld de,#work_fcb
	ld c,#BDOS_OPEN
	call BDOS
	cp #0xff
	ret

; Output: Z set if close failed, Z clear on success. May block in BDOS.
close_work_fcb:
	ld de,#work_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	cp #0xff
	ret

; Update work_fcb R0:R1:R2 with the CP/M record-rounded file size.
; Clobbers AF, BC, DE, HL. May block in BDOS.
compute_work_file_size:
	ld de,#work_fcb
	ld c,#BDOS_FILE_SIZE
	call BDOS
	ret

validate_bios_file:
	ld hl,#bios_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_bios_open
	call compute_work_file_size
	ld a,(work_fcb + FCB_R2)
	or a
	jp nz,error_bios_size
	ld a,(work_fcb + FCB_R1)
	or a
	jp nz,error_bios_size
	ld a,(work_fcb + FCB_R0)
	cp #BIOS_RECORDS
	jp nz,error_bios_size
	call close_work_fcb
	jp z,error_bios_close
	ret

validate_cart_file:
	ld hl,#cart_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_cart_open
	call compute_work_file_size
	ld a,(work_fcb + FCB_R2)
	or a
	jp nz,error_cart_size
	ld hl,(work_fcb + FCB_R0)
	ld a,h
	or l
	jp z,error_cart_size
	; Valid range is 0001h through 0100h records (1 through 32768 bytes).
	ld a,h
	cp #0x01
	jp c,validate_cart_size_ok
	jp nz,error_cart_size
	ld a,l
	or a
	jp nz,error_cart_size
validate_cart_size_ok:
	ld (cart_records),hl
	call close_work_fcb
	jp z,error_cart_close
	ret

; Read BIOS_RECORDS into BIOS_BUFFER. All errors occur before bank mutation.
load_bios_file:
	ld hl,#bios_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_bios_open
	ld hl,#BIOS_BUFFER
	ld (load_ptr),hl
	ld hl,#BIOS_RECORDS
	ld (records_left),hl
	ld hl,#error_bios_read
	ld (read_error_target),hl
	call read_exact_records
	call close_work_fcb
	jp z,error_bios_close
	ret

; Adapt the standard ColecoVision BIOS's VDP port operands for LunchCrema.
; Each table entry contains an address in BIOS_BUFFER, the required original
; operand, and its replacement. Verifying every operand prevents an unknown
; 8 KiB BIOS variant from being patched at arbitrary locations.
; Output: the BIOS buffer uses A0h/A1h for VDP data/control. Clobbers AF, BC,
; DE, HL, IX. Does not block, emit I/O, or modify the takeover bank.
adapt_bios_vdp_ports:
	ld ix,#bios_vdp_patch_table
adapt_bios_vdp_loop:
	ld l,0(ix)
	ld h,1(ix)
	ld a,h
	or l
	ret z
	ld a,(hl)
	ld b,2(ix)
	cp b
	jp nz,error_bios_variant
	ld a,3(ix)
	ld (hl),a
	ld de,#BIOS_PATCH_ENTRY_BYTES
	add ix,de
	jr adapt_bios_vdp_loop

; Fill the complete cartridge source buffer with FFh before overlaying the
; record-rounded file. This deterministically fills every unused ROM byte.
fill_cart_buffer:
	ld hl,#CART_BUFFER
	ld (hl),#0xff
	ld de,#(CART_BUFFER + 1)
	ld bc,#(CART_BYTES - 1)
	ldir
	ret

load_cart_file:
	ld hl,#cart_fcb_name
	call init_work_fcb
	call open_work_fcb
	jp z,error_cart_open
	ld hl,#CART_BUFFER
	ld (load_ptr),hl
	ld hl,(cart_records)
	ld (records_left),hl
	ld hl,#error_cart_read
	ld (read_error_target),hl
	call read_exact_records
	call close_work_fcb
	jp z,error_cart_close
	ret

; Read records_left sequential 128-byte records from work_fcb directly into
; the current-bank TPA at load_ptr.
; Inputs: initialized work_fcb, load_ptr, records_left, read_error_target.
; Outputs: requested records present in memory. Clobbers AF, BC, DE, HL.
; May block in BDOS. Emits no Virtual Drip traffic except normal BIOS console
; traffic caused by a BDOS/disk error below the launcher.
read_exact_records:
	ld hl,(records_left)
	ld a,h
	or l
	ret z

	ld de,(load_ptr)
	ld c,#BDOS_SET_DMA
	call BDOS
	ld de,#work_fcb
	ld c,#BDOS_READ_SEQ
	call BDOS
	or a
	jr z,read_exact_record_ok
	ld hl,(read_error_target)
	jp (hl)

read_exact_record_ok:
	ld hl,(load_ptr)
	ld de,#128
	add hl,de
	ld (load_ptr),hl
	ld hl,(records_left)
	dec hl
	ld (records_left),hl
	jr read_exact_records

; ===========================================================================
; Deterministic target construction. No CP/M calls or recoverable errors below.
; ===========================================================================

construct_target_bank:
	; BIOS -> bank 7 0000h-1FFFh.
	ld de,#BIOS_BUFFER
	ld hl,#TARGET_BIOS
	ld bc,#BIOS_BYTES
	call xmove_source_to_target

	; Cartridge lower and upper halves. Unused bytes already contain FFh.
	ld de,#CART_BUFFER
	ld hl,#TARGET_CART_LOWER
	ld bc,#CART_HALF_BYTES
	call xmove_source_to_target
	ld de,#(CART_BUFFER + CART_HALF_BYTES)
	ld hl,#TARGET_UPPER_STAGE
	ld bc,#CART_HALF_BYTES
	call xmove_source_to_target

	; Preserve the record Stage B will replace, then install Stage B there.
	ld de,#TARGET_STAGE_B
	ld hl,#TARGET_TAIL_BACKUP
	ld bc,#STAGE_RECORD_BYTES
	call xmove_target_to_target
	ld de,#stage_b_template
	ld hl,#TARGET_STAGE_B
	ld bc,#(stage_b_template_end - stage_b_template)
	call xmove_source_to_target

	; Stage A is position-independent except for explicit COMMON_STAGE_A-based
	; references. It occupies only the application-owned C000h-C3FFh window.
	ld hl,#stage_a_template
	ld de,#COMMON_STAGE_A
	ld bc,#(stage_a_template_end - stage_a_template)
	ldir
	jp COMMON_STAGE_A

; Inputs: DE=current-bank source, HL=bank-7 destination, BC=count.
; Outputs: bytes copied; caller's bank restored. Clobbers AF, BC, DE, HL.
; May block while the BIOS stages chunks through common MOVE_BUFFER.
xmove_source_to_target:
	push bc
	ld a,(source_bank)
	ld c,a
	ld b,#TARGET_BANK
	call ZBIOS_XMOVE
	pop bc
	call ZBIOS_MOVE
	ret

; Inputs: DE=bank-7 source, HL=bank-7 destination, BC=count.
; Outputs and blocking behavior match xmove_source_to_target.
xmove_target_to_target:
	push bc
	ld c,#TARGET_BANK
	ld b,#TARGET_BANK
	call ZBIOS_XMOVE
	pop bc
	call ZBIOS_MOVE
	ret

; ===========================================================================
; Error exits. Every target is entered with CP/M and the source bank intact.
; ===========================================================================

error_usage:
	ld de,#msg_usage
	jr exit_error
error_bios_abi:
	ld de,#msg_bios_abi
	jr exit_error
error_target_active:
	ld de,#msg_target_active
	jr exit_error
error_bios_open:
	ld de,#msg_bios_open
	jr exit_error
error_bios_size:
	call close_work_fcb
	ld de,#msg_bios_size
	jr exit_error
error_bios_close:
	ld de,#msg_bios_close
	jr exit_error
error_bios_read:
	call close_work_fcb
	ld de,#msg_bios_read
	jr exit_error
error_bios_variant:
	ld de,#msg_bios_variant
	jr exit_error
error_cart_open:
	ld de,#msg_cart_open
	jr exit_error
error_cart_size:
	call close_work_fcb
	ld de,#msg_cart_size
	jr exit_error
error_cart_close:
	ld de,#msg_cart_close
	jr exit_error
error_cart_read:
	call close_work_fcb
	ld de,#msg_cart_read

exit_error:
	call puts
	ld de,#DEFAULT_DMA
	ld c,#BDOS_SET_DMA
	call BDOS
	ld sp,(entry_sp)
	ret

puts:
	ld c,#BDOS_PRINT
	call BDOS
	ret

; ===========================================================================
; Stage A template -- relocated to common application RAM at C000h.
;
; Public behavior: does not return. It disables CP/M interrupt sources,
; establishes the LunchCrema state original Coleco software cannot select,
; changes to bank 7, and jumps to Stage B. It may block briefly on paced V9958
; writes. It is not ISR-safe and emits no Virtual Drip traffic.
;
; Any absolute reference inside this template MUST be expressed relative to
; COMMON_STAGE_A. Ordinary source labels point into the discarded .COM image.
; ===========================================================================

stage_a_template:
	di

	; Quiesce every CTC channel used by CP/M.
	ld a,#CTC_RESET_DISABLE
	out (CTC0_CTRL),a
	out (CTC1_CTRL),a
	out (CTC2_CTRL),a
	out (CTC3_CTRL),a

	; Mask both channels' WR1 registers, then clear each chip's WR9 master
	; enable. SIO1/B is the current IOC command channel and SIO1/A is Bulk.
	ld a,#0x01
	out (SIO0B_CTRL),a
	xor a
	out (SIO0B_CTRL),a
	ld a,#0x01
	out (SIO0A_CTRL),a
	xor a
	out (SIO0A_CTRL),a
	ld a,#0x09
	out (SIO0A_CTRL),a
	xor a
	out (SIO0A_CTRL),a
	ld a,#0x01
	out (SIO1A_CTRL),a
	xor a
	out (SIO1A_CTRL),a
	ld a,#0x01
	out (SIO1B_CTRL),a
	xor a
	out (SIO1B_CTRL),a
	ld a,#0x09
	out (SIO1B_CTRL),a
	xor a
	out (SIO1B_CTRL),a

	; Bypass the external WAIT porch first, matching the proven LunchCrema
	; bootstrap path. D0=0 also holds the physical route on maskable INT.
	ld a,#V9958_CONFIG_PORCH_OFF
	out (V9958_CONFIG_PORT),a

	; CP/M leaves V9958-only state that a TMS9928A BIOS cannot reset. In
	; particular, the direct G6 console leaves R#0 in bitmap mode and R#14 on
	; VRAM page 7. The Coleco BIOS clears 16 KiB before programming R#0; without
	; this baseline that clear hits page 7 and the old page-zero glyphs remain
	; visible behind its title screen. Also reset the extended color/sprite table
	; selectors, scroll/adjust state, expansion-memory selector, and any command.
	; R#25 first disables native WAIT while the external porch is bypassed.
	ld hl,#(COMMON_STAGE_A + (stage_a_tms_baseline - stage_a_template))
	ld c,#((stage_a_tms_baseline_end - stage_a_tms_baseline) / 2)
stage_a_tms_baseline_loop:
	ld a,(hl)
	inc hl
	ld b,(hl)
	inc hl
	call COMMON_STAGE_A + (stage_a_vdp_write_paced - stage_a_template)
	dec c
	jr nz,stage_a_tms_baseline_loop

	; The table ends with R#8 configured for the installed 64Kx4 DRAM. Enable
	; native WAIT, then restore the external porch. Keep routing on INT for now.
	ld a,#V9958_R25_WAIT_ON
	ld b,#25
	call COMMON_STAGE_A + (stage_a_vdp_write_paced - stage_a_template)
	xor a
	out (V9958_CONFIG_PORT),a

	; Native WAIT and the porch are now active, so clear any stale VDP interrupt
	; request with a normal status-zero read before enabling the NMI route.
	in a,(V9958_COMMAND_PORT)

	; Install a 3-bit quantization of the TMS9928A palette. Select
	; every entry explicitly so retained V9958 palette state is irrelevant.
	ld hl,#(COMMON_STAGE_A + (stage_a_palette - stage_a_template))
	ld c,#0
	ld d,#16
stage_a_palette_loop:
	ld a,c
	ld b,#16
	call COMMON_STAGE_A + (stage_a_vdp_write_paced - stage_a_template)
	ld a,(hl)
	inc hl
	out (V9958_PALETTE_PORT),a
	call COMMON_STAGE_A + (stage_a_vdp_delay - stage_a_template)
	ld a,(hl)
	inc hl
	out (V9958_PALETTE_PORT),a
	call COMMON_STAGE_A + (stage_a_vdp_delay - stage_a_template)
	inc c
	dec d
	jr nz,stage_a_palette_loop

	; D0=1 selects NMI and D1=0 leaves the LunchCrema WAIT porch enabled.
	ld a,#V9958_CONFIG_NMI
	out (V9958_CONFIG_PORT),a

	; C000h remains physical bank 0 across this write. Do not touch the old
	; low-bank stack after switching; Stage B is stackless.
	ld a,#TARGET_BANK_LATCH
	out (BANK_PORT),a
	jp TARGET_STAGE_B

; Input: A=value, B=V9958 register. Preserves BC. May block for pacing only.
stage_a_vdp_write_paced:
	out (V9958_COMMAND_PORT),a
	call COMMON_STAGE_A + (stage_a_vdp_delay - stage_a_template)
	ld a,b
	or #0x80
	out (V9958_COMMAND_PORT),a
	jp COMMON_STAGE_A + (stage_a_vdp_delay - stage_a_template)

stage_a_vdp_delay:
	push bc
	ld b,#V9958_BOOT_DELAY_COUNT
stage_a_vdp_delay_loop:
	djnz stage_a_vdp_delay_loop
	pop bc
	ret

; Value/register pairs establishing the state a freshly reset TMS9928A would
; expose to the Coleco BIOS, plus the V9958 DRAM and WAIT bootstrap controls.
; R#9=0 selects the standard BIOS's 192-line/60 Hz timing. R#10/R#11 clear the
; extended color and sprite-table address bits; R#14 selects VRAM page zero.
stage_a_tms_baseline:
	.db V9958_R25_WAIT_OFF,25
	.db 0x00,46
	.db 0x00,1
	.db 0x00,0
	.db 0x00,9
	.db 0x00,10
	.db 0x00,11
	.db 0x00,12
	.db 0x00,13
	.db 0x00,14
	.db 0x00,15
	.db 0x00,16
	.db 0x00,17
	.db 0x00,18
	.db 0x00,19
	.db 0x00,23
	.db 0x00,26
	.db 0x00,27
	.db 0x00,45
	.db V9958_R8_64K_DRAM,8
stage_a_tms_baseline_end:

; V9958 entries 0..15, encoded as RB then G (three bits per component).
stage_a_palette:
	.db 0x00,0x00, 0x00,0x00, 0x12,0x05, 0x33,0x06
	.db 0x27,0x02, 0x37,0x03, 0x62,0x02, 0x27,0x06
	.db 0x72,0x02, 0x73,0x03, 0x62,0x05, 0x64,0x06
	.db 0x12,0x05, 0x65,0x02, 0x66,0x06, 0x77,0x07
stage_a_template_end:

; ===========================================================================
; Stage B template -- installed at bank 7 address 5F80h.
;
; Public behavior: does not return. It copies the staged upper cartridge into
; physical common bank 0, restores the record hidden by this code, clears the
; full Coleco RAM range, and jumps (never calls) to 0000h. It is stackless,
; interrupt-disabled, not ISR-safe, and emits no I/O traffic.
; ===========================================================================

stage_b_template:
	ld hl,#TARGET_UPPER_STAGE
	ld de,#0xc000
	ld bc,#TARGET_UPPER_PREFIX
	ldir
	ld hl,#TARGET_TAIL_BACKUP
	ld de,#TARGET_CART_TAIL
	ld bc,#STAGE_RECORD_BYTES
	ldir

	; Stage B is below 6000h, so it can deterministically clear Coleco RAM
	; without overwriting the instructions that are still executing.
	xor a
	ld hl,#0x6000
	ld (hl),a
	ld de,#0x6001
	ld bc,#0x1fff
	ldir
	jp 0x0000
stage_b_template_end:

; ===========================================================================
; Resident loader data. No storage below FILE_BUFFER_BASE may follow this.
; ===========================================================================

bios_fcb_name:
	.db 0
	.ascii "COLECO  ROM"
cart_fcb_name:
	.ds FCB_NAME_BYTES
work_fcb:
	.ds FCB_BYTES

entry_sp:
	.dw 0
source_bank:
	.db 0
cart_records:
	.dw 0
load_ptr:
	.dw 0
records_left:
	.dw 0
read_error_target:
	.dw 0

; Standard BIOS CRC32 3AA93EF3. Addresses name operand bytes, not opcodes.
bios_vdp_patch_table:
	.dw BIOS_BUFFER + 0x18d7
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x18dc
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x18df
	.db COLECO_VDP_DATA_PORT,ZEPHYR_VDP_DATA_PORT
	.dw BIOS_BUFFER + 0x1c93
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1c98
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1cab
	.db COLECO_VDP_DATA_PORT,ZEPHYR_VDP_DATA_PORT
	.dw BIOS_BUFFER + 0x1ccc
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1cd1
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1d0a
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1d0d
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1d12
	.db COLECO_VDP_DATA_PORT,ZEPHYR_VDP_DATA_PORT
	.dw BIOS_BUFFER + 0x1d40
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1d43
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw BIOS_BUFFER + 0x1d47
	.db COLECO_VDP_DATA_PORT,ZEPHYR_VDP_DATA_PORT
	.dw BIOS_BUFFER + 0x1d58
	.db COLECO_VDP_COMMAND_PORT,ZEPHYR_VDP_COMMAND_PORT
	.dw 0
	.db 0,0

msg_banner:
	.ascii "ColecoGo 0.3 - Zephyr-80 ColecoVision loader\r\n$"
msg_validating:
	.ascii "Validating COLECO.ROM and cartridge...\r\n$"
msg_loading:
	.ascii "Reading images into the CP/M TPA...\r\n$"
msg_takeover:
	.ascii "Images loaded; starting ColecoVision (no return).\r\n$"
msg_usage:
	.ascii "Error: use COLECOGO GAME.ROM (wildcards are not allowed).\r\n$"
msg_bios_abi:
	.ascii "Error: required Zephyr extended BIOS banking ABI is unavailable.\r\n$"
msg_target_active:
	.ascii "Error: CP/M is executing in reserved takeover bank 7.\r\n$"
msg_bios_open:
	.ascii "Error: cannot open COLECO.ROM on the current drive.\r\n$"
msg_bios_size:
	.ascii "Error: COLECO.ROM must occupy exactly 64 CP/M records (8 KiB).\r\n$"
msg_bios_close:
	.ascii "Error: cannot close COLECO.ROM.\r\n$"
msg_bios_read:
	.ascii "Error: failed while reading COLECO.ROM. Bank 7 was not changed.\r\n$"
msg_bios_variant:
	.ascii "Error: COLECO.ROM is not the supported standard BIOS image.\r\n$"
msg_cart_open:
	.ascii "Error: cannot open the requested cartridge image.\r\n$"
msg_cart_size:
	.ascii "Error: cartridge must occupy 1 through 256 CP/M records (max 32 KiB).\r\n$"
msg_cart_close:
	.ascii "Error: cannot close the cartridge image.\r\n$"
msg_cart_read:
	.ascii "Error: failed while reading cartridge. Bank 7 was not changed.\r\n$"

program_end:
