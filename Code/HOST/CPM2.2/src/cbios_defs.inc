; Local Zephyr-80 CP/M 2.2 runtime definitions.
;
; Board-specific code includes this file instead of editing the stock CP/M
; source under cpm-2.2.
;
; ------------------------------------------------------------------------------
; Transitional fixed-slot BIOS map, before Virtual Drip
; ------------------------------------------------------------------------------
;
;   FFFFh ┌──────────────────────────────────────────────┐
;         │ BIOS stack / reserve                         │
;   FFF0h │   CBIOS_STACK_TOP                            │
;         │   stack grows downward                       │
;   FA00h ├──────────────────────────────────────────────┤
;   F9FFh │ Runtime state end                            │
;   F900h │ Runtime state start                          │
;         │   CURRENT_BANK / DMA / XMOVE                 │
;         │   storage state                              │
;         │   console driver state                       │
;         ├──────────────────────────────────────────────┤
;   F7FFh │ Scratch / staging end                        │
;   F700h │   RAMDISK_DIRBUF                             │
;   F680h │   free scratch window                        │
;   F600h │   MOVE_BUFFER                                │
;         ├──────────────────────────────────────────────┤
;   F5FFh │ Driver slot 5 end                            │
;   F200h │ Driver slot 5 start                          │
;         │                                              │
;   F1FFh │ Driver slot 4 end                            │
;   EE00h │ Driver slot 4 start                          │
;         │                                              │
;   EDFFh │ Driver slot 3 end                            │
;   EA00h │ Driver slot 3 start                          │
;         │                                              │
;   E9FFh │ Driver slot 2 end                            │
;   E600h │ Driver slot 2 start                          │
;         │                                              │
;   E5FFh │ Driver slot 1 end                            │
;   E500h │   SIO IM2 repeated-byte table, 256 bytes     │
;   E4E4h │   SIO IM2 trampoline: JP sio_console_isr     │
;   E200h │ Driver slot 1 start: legacy SIO console      │
;         │                                              │
;   E1FFh │ Driver slot 0 end                            │
;   DE00h │ Driver slot 0 start: RAM disk backend        │
;         ├──────────────────────────────────────────────┤
;   DDFFh │ Core BIOS end                                │
;   DC80h │   banking / XMOVE / LAUNCH                   │
;   DC00h │   storage facade                             │
;   DB80h │   console facade                             │
;   DA00h │ CBIOS_BASE / jump table / boot / WBOOT       │
;         └──────────────────────────────────────────────┘
;
; Important IM2 note:
;   The SIO console backend must emit exactly 256 bytes at CBIOS_IM2_VECTOR_TABLE.
;   With the table at E500h, 256 bytes occupies E500h-E5FFh exactly.
;   The old 257-byte table would spill one byte into E600h.
;
;   I register          = E5h
;   SIO WR2 vector      = 00h
;   CPU reads word at   = E500h/E501h
;   Table bytes there   = E4h/E4h
;   CPU jumps to        = E4E4h
;   E4E4h contains      = JP sio_console_isr
;
; ------------------------------------------------------------------------------

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
;
; In this MEM=56 build, the CCP begins at C400h, so the effective protected
; common TPA currently available to applications is C000h-C3FFh. That 1 KiB
; window remains application-owned even though it is common across banks; the
; BIOS must not claim it for persistent state, scratch, vectors, or drivers.
PROTECTED_TPA_START             = 0xc000
PROTECTED_TPA_END               = 0xcfff

; ------------------------------------------------------------------------------
; CBIOS Memory Layout
; ------------------------------------------------------------------------------
CBIOS_BASE                      = 0xda00

; ------------------------------------------------------------------------------
; Core BIOS Region
; ------------------------------------------------------------------------------
; DA00h-DDFFh = core BIOS.
;
; This is one contiguous BIOS-owned core region.
; Banking / XMOVE / LAUNCH are core BIOS services, not drivers.
;
; Current intended packing:
;   DA00h  BIOS jump table
;   DA42h  BDOS shim / boot glue area
;   DB80h  console facade
;   DC00h  storage facade
;   DC80h  banking / XMOVE / LAUNCH

CBIOS_CORE_BASE                 = CBIOS_BASE
CBIOS_CORE_LIMIT                = 0xde00
CBIOS_CORE_END                  = CBIOS_CORE_LIMIT - 1
CBIOS_CORE_SIZE                 = CBIOS_CORE_LIMIT - CBIOS_CORE_BASE

; Existing public symbols kept.
CBIOS_JUMP_TABLE                = CBIOS_BASE
CBIOS_CONSOLE_CODE_BASE         = CBIOS_BASE + 0x0180      ; DB80h
CBIOS_STORAGE_CODE_BASE         = CBIOS_BASE + 0x0200      ; DC00h

; Banking is core BIOS, not a driver.
; Existing public symbol name kept, moved into the core BIOS region.
CBIOS_BANKING_CODE_BASE         = CBIOS_BASE + 0x0280      ; DC80h

; ------------------------------------------------------------------------------
; Fixed Driver Slots
; ------------------------------------------------------------------------------
; DE00h-F5FFh = six fixed 1 KiB driver/code slots.
;
; Drivers may occupy one or more whole slots.
; Build-time validation should ensure drivers stay inside declared slots.
;
; The fixed slots intentionally trade a little internal slack for a stable map:
; a driver can move or grow without forcing every later driver to slide upward
; into a card castle. To add a driver:
;   1. choose one or more whole slots,
;   2. define code start/end symbols,
;   3. define a driver table or equivalent entry points,
;   4. keep persistent state in the runtime state area or a validated state
;      block,
;   5. use scratch only for temporary buffers,
;   6. update validation expectations,
;   7. regenerate the memory documentation.

CBIOS_DRIVER_SLOT_SIZE          = 0x0400

CBIOS_DRIVER_SLOT0_BASE         = 0xde00
CBIOS_DRIVER_SLOT0_LIMIT        = CBIOS_DRIVER_SLOT0_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT0_END          = CBIOS_DRIVER_SLOT0_LIMIT - 1

CBIOS_DRIVER_SLOT1_BASE         = 0xe200
CBIOS_DRIVER_SLOT1_LIMIT        = CBIOS_DRIVER_SLOT1_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT1_END          = CBIOS_DRIVER_SLOT1_LIMIT - 1

CBIOS_DRIVER_SLOT2_BASE         = 0xe600
CBIOS_DRIVER_SLOT2_LIMIT        = CBIOS_DRIVER_SLOT2_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT2_END          = CBIOS_DRIVER_SLOT2_LIMIT - 1

CBIOS_DRIVER_SLOT3_BASE         = 0xea00
CBIOS_DRIVER_SLOT3_LIMIT        = CBIOS_DRIVER_SLOT3_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT3_END          = CBIOS_DRIVER_SLOT3_LIMIT - 1

CBIOS_DRIVER_SLOT4_BASE         = 0xee00
CBIOS_DRIVER_SLOT4_LIMIT        = CBIOS_DRIVER_SLOT4_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT4_END          = CBIOS_DRIVER_SLOT4_LIMIT - 1

CBIOS_DRIVER_SLOT5_BASE         = 0xf200
CBIOS_DRIVER_SLOT5_LIMIT        = CBIOS_DRIVER_SLOT5_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT5_END          = CBIOS_DRIVER_SLOT5_LIMIT - 1

CBIOS_DRIVER_SLOTS_BASE         = CBIOS_DRIVER_SLOT0_BASE
CBIOS_DRIVER_SLOTS_LIMIT        = CBIOS_DRIVER_SLOT5_LIMIT
CBIOS_DRIVER_SLOTS_END          = CBIOS_DRIVER_SLOTS_LIMIT - 1

; ------------------------------------------------------------------------------
; Current Transitional Driver Placement
; ------------------------------------------------------------------------------
; Before Virtual Drip:
;
;   Slot 0:
;     DE00h... current RAM disk backend
;
;   Slot 1:
;     E200h... current legacy SIO console driver
;     E4E4h... SIO IM2 trampoline
;     E500h... SIO IM2 repeated-byte table, 256 bytes
;
; These names are kept so existing source can still ORG against them.

CBIOS_RAMDISK_CODE_BASE         = CBIOS_DRIVER_SLOT0_BASE              ; DE00h
CBIOS_CONSOLE_DRIVER_CODE_BASE  = CBIOS_DRIVER_SLOT1_BASE              ; E200h

; Resident code region ends before scratch.
; LIMIT is one byte past the end.
CBIOS_CODE_LIMIT                = 0xf600
CBIOS_CODE_END                  = CBIOS_CODE_LIMIT - 1

; ------------------------------------------------------------------------------
; Scratch Area & Buffers
; ------------------------------------------------------------------------------
; F600h-F7FFh = BIOS scratch / staging.
;
; Current active buffers:
;   F600h-F67Fh MOVE_BUFFER
;   F700h-F77Fh RAMDISK_DIRBUF
;
; The remaining gaps are available for later temporary BIOS work buffers.

CBIOS_SCRATCH_BASE              = 0xf600
CBIOS_SCRATCH_LIMIT             = 0xf800
CBIOS_SCRATCH_END               = CBIOS_SCRATCH_LIMIT - 1

MOVE_BUFFER                     = CBIOS_SCRATCH_BASE
MOVE_BUFFER_SIZE                = 0x0080

RAMDISK_DIRBUF                  = CBIOS_SCRATCH_BASE + 0x0100

; Optional named free scratch windows.
CBIOS_SCRATCH_FREE0             = 0xf680
CBIOS_SCRATCH_FREE0_LIMIT       = 0xf700
CBIOS_SCRATCH_FREE1             = 0xf780
CBIOS_SCRATCH_FREE1_LIMIT       = 0xf800

; ------------------------------------------------------------------------------
; IM2 Interrupt Vectors
; ------------------------------------------------------------------------------
; E500h-E5FFh = SIO-owned IM2 repeated-byte table.
;
; This is deliberately inside Driver Slot 1 with the legacy SIO console driver.
;
; The current SIO console backend must emit exactly 256 bytes at
; CBIOS_IM2_VECTOR_TABLE. If it emits 257 bytes, it will overflow slot 1.

CBIOS_IM2_VECTOR_TABLE          = 0xe500
CBIOS_IM2_VECTOR_PAGE           = 0xe5

; Repeated byte used inside the IM2 table.
; E4h/E4h forms address E4E4h.
CBIOS_IM2_VECTOR_BYTE           = 0xe4

; Actual ISR trampoline address.
; The console backend does ".org CBIOS_IM2_VECTOR_ENTRY" and emits:
;   JP sio_console_isr
CBIOS_IM2_VECTOR_ENTRY          = 0xe4e4

; Byte written to SIO WR2.
; With I = E5h and vector = 00h, the CPU reads the vector word at E500h.
CBIOS_SIO_VECTOR                = 0x00

; Table is exactly 256 bytes in this layout.
CBIOS_IM2_VECTOR_SIZE           = 0x0100
CBIOS_IM2_VECTOR_LIMIT          = CBIOS_IM2_VECTOR_TABLE + CBIOS_IM2_VECTOR_SIZE
CBIOS_IM2_VECTOR_END            = CBIOS_IM2_VECTOR_LIMIT - 1

; ------------------------------------------------------------------------------
; Work Areas / Runtime State
; ------------------------------------------------------------------------------
; F900h-F9FFh = persistent BIOS runtime state.
;
; Keep existing public work-area names so current source keeps assembling.

CBIOS_WORK_AREA                 = 0xf900
CBIOS_WORK_AREA_LIMIT           = 0xfa00
CBIOS_WORK_AREA_END             = CBIOS_WORK_AREA_LIMIT - 1

CBIOS_CONSOLE_WORK_AREA         = CBIOS_WORK_AREA + 0x0004
CBIOS_BANK_WORK_AREA            = CBIOS_WORK_AREA + 0x0020
CBIOS_STORAGE_WORK_AREA         = CBIOS_WORK_AREA + 0x0040
CBIOS_CONSOLE_DRIVER_WORK_AREA  = CBIOS_WORK_AREA + 0x0070

; Optional clearer aliases for docs / validation.
CBIOS_RUNTIME_STATE_BASE        = CBIOS_WORK_AREA
CBIOS_RUNTIME_STATE_LIMIT       = CBIOS_WORK_AREA_LIMIT
CBIOS_RUNTIME_STATE_END         = CBIOS_WORK_AREA_END

; ------------------------------------------------------------------------------
; Stack & Guard
; ------------------------------------------------------------------------------
; FA00h-FFFFh = BIOS stack / reserve.
;
; Stack top remains FFF0h.
; Stack grows downward and should not cross FA00h.

CBIOS_STACK_GUARD               = 0xfa00
CBIOS_STACK_TOP                 = 0xfff0

CBIOS_AREA_LIMIT                = 0x10000
CBIOS_AREA_END                  = 0xffff

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
; Keep old validation symbol names where possible, but point them at the new map.
;
; The original RESERVED_BIOS_CODE_END pointed at CBIOS_CODE_LIMIT, so preserve
; that behavior for compatibility: this is a LIMIT, not an inclusive end.

RESERVED_BIOS_CODE_START        = CBIOS_BASE
RESERVED_BIOS_CODE_END          = CBIOS_CODE_LIMIT

RESERVED_WORK_AREA_START        = CBIOS_WORK_AREA
RESERVED_WORK_AREA_END          = CBIOS_WORK_AREA_END

RESERVED_STACK_START            = CBIOS_STACK_GUARD
RESERVED_STACK_END              = CBIOS_AREA_END

WBOOT_PROTECTED_START           = CBIOS_BASE
WBOOT_PROTECTED_END             = CBIOS_AREA_END

; New validation helpers for the fixed-slot map.

RESERVED_BIOS_CORE_START        = CBIOS_CORE_BASE
RESERVED_BIOS_CORE_END          = CBIOS_CORE_END

RESERVED_DRIVER_SLOTS_START     = CBIOS_DRIVER_SLOTS_BASE
RESERVED_DRIVER_SLOTS_END       = CBIOS_DRIVER_SLOTS_END

RESERVED_SCRATCH_START          = CBIOS_SCRATCH_BASE
RESERVED_SCRATCH_END            = CBIOS_SCRATCH_END

RESERVED_IM2_START              = CBIOS_IM2_VECTOR_TABLE
RESERVED_IM2_END                = CBIOS_IM2_VECTOR_END

RESERVED_RUNTIME_STATE_START    = CBIOS_RUNTIME_STATE_BASE
RESERVED_RUNTIME_STATE_END      = CBIOS_RUNTIME_STATE_END

; ------------------------------------------------------------------------------
; Transitional Slot Ownership
; ------------------------------------------------------------------------------
; These are for external layout validation/documentation.
;
; Before Virtual Drip:
;   Slot 0 contains current RAM disk backend.
;   Slot 1 contains current legacy SIO console driver, including its IM2 table
;   and trampoline.
;   Slots 2-5 are available for future drivers.

LEGACY_RAMDISK_SLOT_FIRST       = 0
LEGACY_RAMDISK_SLOT_LAST        = 0

LEGACY_CONSOLE_SLOT_FIRST       = 1
LEGACY_CONSOLE_SLOT_LAST        = 1
