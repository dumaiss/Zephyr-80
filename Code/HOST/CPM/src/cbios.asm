; Zephyr-80 CP/M 2.2-style CBIOS scaffold.
;
; This is not a working CP/M BIOS. It establishes the jump table, console
; primitives, disk stubs, and provisional work area for future porting work.

	.module zephyr80_cbios
	.area CODE (ABS)

	.include "cbios_defs.inc"
	.include "platform_zephyr80.inc"

	.org 0x0000
reset_vector:
	jp cpm_rom_entry_high

	.org CBIOS_BASE

	.include "cbios_jump_table.asm"
	.include "boot_shadow_copy.asm"
	.include "cbios_boot.asm"
	.include "cbios_console.asm"
	.include "cbios_disk_stub.asm"

; Provisional CBIOS work area. This will move when the final CP/M memory layout
; is defined.
	.org CBIOS_WORK_AREA

cbios_dma_addr:
	.dw 0x0080
