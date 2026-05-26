; Local Zephyr-80 CP/M 2.2 runtime definitions.
;
; Board-specific code includes this file instead of editing the stock CP/M
; source under cpm-2.2.

; ------------------------------------------------------------------------------
; Global System Constants
; ------------------------------------------------------------------------------
BIOS_OK                         = 0x00
BIOS_ERR                        = 0x01
CONST_NO_CHAR                   = 0x00
CONST_HAS_CHAR                  = 0xff
CR                              = 0x0d
LF                              = 0x0a

; ------------------------------------------------------------------------------
; CP/M Page Zero & Environment Setup
; ------------------------------------------------------------------------------
PZWBOOT                         = 0x0000
PZBDOS                          = 0x0005
DEFAULT_DMA                     = 0x0080
DEFAULT_DMA_LEN                 = 0x80
MONITOR_ENTRY                   = 0x0100
CCP_ENTRY                       = CBASE         ; Requires external CBASE definition
CCP_CLEARBUF_ENTRY              = CBASE + 0x0003
APP_STACK_TOP                   = 0xb000
BANK_MASK                       = RAM_BANK_MASK ; Requires external definition

; ------------------------------------------------------------------------------
; TPA Boundaries
; ------------------------------------------------------------------------------
; Protected TPA area in the non-banked region. Preserved across bank switches.
; Available for application data/code, but restricted from CBIOS usage.
PROTECTED_TPA_START             = 0xc000
PROTECTED_TPA_END               = 0xcfff

; ------------------------------------------------------------------------------
; CBIOS Memory Layout (Ordered sequentially by offset)
; ------------------------------------------------------------------------------
CBIOS_BASE                      = 0xda00

; Code Segments
CBIOS_JUMP_TABLE                = CBIOS_BASE
CBIOS_CONSOLE_CODE_BASE         = CBIOS_BASE + 0x0180
CBIOS_STORAGE_CODE_BASE         = CBIOS_BASE + 0x0200
CBIOS_RAMDISK_CODE_BASE         = CBIOS_BASE + 0x0800
CBIOS_CONSOLE_DRIVER_CODE_BASE  = CBIOS_BASE + 0x0940
CBIOS_BANKING_CODE_BASE         = CBIOS_BASE + 0x0d00
CBIOS_CODE_LIMIT                = CBIOS_BASE + 0x1c00

; Scratch Area & Buffers (0x1c00 - 0x1d7f)
CBIOS_SCRATCH_BASE              = CBIOS_BASE + 0x1c00
MOVE_BUFFER                     = CBIOS_SCRATCH_BASE
MOVE_BUFFER_SIZE                = 0x0100
RAMDISK_DIRBUF                  = CBIOS_SCRATCH_BASE + 0x0100
CBIOS_SCRATCH_END               = CBIOS_SCRATCH_BASE + 0x017f

; Stack & Guard
CBIOS_STACK_GUARD               = CBIOS_BASE + 0x1e80
CBIOS_STACK_TOP                 = 0xfff0

; Work Areas (0x1f00 - 0x1fff)
CBIOS_WORK_AREA                 = CBIOS_BASE + 0x1f00
CBIOS_CONSOLE_WORK_AREA         = CBIOS_WORK_AREA + 0x0004
CBIOS_BANK_WORK_AREA            = CBIOS_WORK_AREA + 0x0020
CBIOS_STORAGE_WORK_AREA         = CBIOS_WORK_AREA + 0x0040
CBIOS_CONSOLE_DRIVER_WORK_AREA  = CBIOS_WORK_AREA + 0x0070
CBIOS_AREA_END                  = CBIOS_BASE + 0x1fff

; IM2 Interrupt Vectors
CBIOS_IM2_VECTOR_PAGE           = 0xe5
CBIOS_IM2_VECTOR_BYTE           = 0xe4
CBIOS_IM2_VECTOR_ENTRY          = CBIOS_BASE + 0x0ae4
CBIOS_IM2_VECTOR_TABLE          = CBIOS_BASE + 0x0b00
CBIOS_SIO_VECTOR                = 0x00

; ------------------------------------------------------------------------------
; RAM Disk Configuration (DPB Mapping)
; ------------------------------------------------------------------------------
RAMDISK_DRIVE                   = 0x00
RAMDISK_FIRST_BANK              = 0x02
RAMDISK_LAST_BANK               = 0x07
RAMDISK_BANK_COUNT              = 0x06
RAMDISK_BANK_BASE               = 0x0000
RAMDISK_BANK_LIMIT              = 0xc000
RAMDISK_BANK_BYTES              = 0xc000
RAMDISK_RECORD_BYTES            = 0x0080
RAMDISK_RECORDS_PER_BANK        = 0x0180
RAMDISK_TOTAL_RECORDS           = 0x0900
RAMDISK_SECTORS_PER_TRACK       = 0x0030
RAMDISK_TRACKS                  = 0x0030
RAMDISK_OFFSET_TRACKS           = 0x0000
RAMDISK_BLOCK_SHIFT             = 0x04
RAMDISK_BLOCK_MASK              = 0x0f
RAMDISK_EXTENT_MASK             = 0x01
RAMDISK_MAX_BLOCK               = 0x008f
RAMDISK_DIR_ENTRIES             = 0x003f
RAMDISK_ALLOC0                  = 0x80
RAMDISK_ALLOC1                  = 0x00
RAMDISK_CHECK_SIZE              = 0x0010
RAMDISK_ALV_SIZE                = 0x0012

; ------------------------------------------------------------------------------
; Build-Time Validation Boundaries
; ------------------------------------------------------------------------------
; Emitted for external script/assembler validation checks.
RESERVED_BIOS_CODE_START        = CBIOS_BASE
RESERVED_BIOS_CODE_END          = CBIOS_CODE_LIMIT
RESERVED_WORK_AREA_START        = CBIOS_WORK_AREA
RESERVED_WORK_AREA_END          = CBIOS_STACK_GUARD
RESERVED_STACK_START            = CBIOS_STACK_GUARD
RESERVED_STACK_END              = CBIOS_AREA_END
WBOOT_PROTECTED_START           = CBIOS_BASE
WBOOT_PROTECTED_END             = CBIOS_AREA_END