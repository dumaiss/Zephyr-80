; Local Zephyr-80 CP/M 2.2 runtime definitions.
;
; Board-specific code includes this file instead of editing the stock CP/M
; source under cpm-2.2.
;
; ------------------------------------------------------------------------------
; Transitional fixed-slot BIOS map, with Virtual Drip
; ------------------------------------------------------------------------------
;
;   FFFFh ┌──────────────────────────────────────────────┐
;         │ BIOS stack / reserve                         │
;   FFF0h │   CBIOS_STACK_TOP                            │
;   FEF0h │   CBIOS_CONSOLE_STACK_TOP                    │
;         │   stack grows downward                       │
;   FB00h ├──────────────────────────────────────────────┤
;   FAFFh │ Runtime state end                            │
;   FA00h │ Runtime state start                          │
;         │   CURRENT_BANK / DMA / XMOVE                 │
;         │   storage state                              │
;         │   SIO core state                             │
;         │   console driver state                       │
;         ├──────────────────────────────────────────────┤
;   F9FFh │ Scratch / staging end                        │
;   F980h │   free scratch window                        │
;   F900h │   RAMDISK_DIRBUF                             │
;   F800h │   MOVE_BUFFER                                │
;         ├──────────────────────────────────────────────┤
;   F7FFh │ Driver slot 5 end                            │
;   F400h │ Driver slot 5 start: RAM disk backend        │
;         │                                              │
;   F3FFh │ Driver slot 4 end                            │
;   F000h │ Driver slot 4 start: Virtual Drip console    │
;         │                                              │
;   EFFFh │ Driver slot 3 end                            │
;   EC00h │ Driver slot 3 start: Virtual Drip console    │
;         │                                              │
;   EBFFh │ Driver slot 2 end                            │
;   E800h │ Driver slot 2 start: Virtual Drip console    │
;         │                                              │
;   E7FFh │ Driver slot 1 end                            │
;   E400h │ Driver slot 1 start: Virtual Drip console    │
;         │                                              │
;   E3FFh │ Driver slot 0 end                            │
;   E000h │ Driver slot 0 start: Virtual Drip console    │
;         ├──────────────────────────────────────────────┤
;   DFFFh │ Core BIOS end                                │
;   DF50h │   IOCALL transaction transport               │
;   DD10h │   SIO core + exact IM2 vector entry          │
;   DC00h │   banking / XMOVE / LAUNCH                   │
;   DBC0h │   storage facade                             │
;   DB79h │   console facade                             │
;   DA00h │ CBIOS_BASE / jump table / boot / WBOOT       │
;         └──────────────────────────────────────────────┘
;
; Important IM2 note:
;   The SIO core emits one exact two-byte IM2 table entry. SIO0/B WR2 is set to
;   the low byte of that entry, and WR1 status-affects-vector is kept disabled.
;
;   I register          = DDh
;   SIO WR2 vector      = 10h
;   CPU reads word at   = DD10h/DD11h
;   Table word there    = sio_core_isr
;
; ------------------------------------------------------------------------------

; ------------------------------------------------------------------------------
; Global System Constants
; ------------------------------------------------------------------------------
BIOS_OK                         = 0x00
BIOS_ERR                        = 0x01
BIOS_ERR_BAD_LEN                = 0x01
BIOS_ERR_TIMEOUT                = 0x02
BIOS_ERR_IO                     = 0x03
BIOS_ERR_BAD_REPLY              = 0x04
CONST_NO_CHAR                   = 0x00
CONST_HAS_CHAR                  = 0xff
CR                              = 0x0d
LF                              = 0x0a

; BIOS-owned SIO service channels.
;
; SIO_CH_CONSOLE is SIO0/B and backs the CP/M console transport.
; SIO_CH_IOCTRL is SIO1/A and backs the BIOS-owned synchronous IO Controller
; link. SIO0/A and the CTC remain application-owned.
SIO_CH_CONSOLE                  = 0x00
SIO_CH_IOCTRL                   = 0x01

; IOCALL caller-provided request block offsets.
IOCALL_CHAN                     = 0x00
IOCALL_CMD                      = 0x01
IOCALL_TX_LEN                   = 0x02
IOCALL_RX_MAX                   = 0x03
IOCALL_TX_PTR                   = 0x04
IOCALL_RX_PTR                   = 0x06
IOCALL_STATUS                   = 0x08
IOCALL_RX_LEN                   = 0x09
IOCALL_SIZE                     = 0x0a
IOCALL_MAX_LEN                  = 0x80

; Optional IO Controller response status values.
IOC_STATUS_OK                   = 0x00
IOC_STATUS_BAD_CHAN             = 0x01
IOC_STATUS_BAD_CMD              = 0x02
IOC_STATUS_BAD_LEN              = 0x03
IOC_STATUS_BUSY                 = 0x04

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
PROTECTED_TPA_END               = 0xc3ff

; ------------------------------------------------------------------------------
; CBIOS Memory Layout
; ------------------------------------------------------------------------------
CBIOS_BASE                      = 0xda00

; ------------------------------------------------------------------------------
; Core BIOS Region
; ------------------------------------------------------------------------------
; DA00h-DFFFh = core BIOS.
;
; This is one contiguous BIOS-owned core region.
; Banking / XMOVE / LAUNCH are core BIOS services, not drivers.
;
; Current intended packing:
;   DA00h  BIOS jump table
;   DA42h  BDOS shim / boot glue area
;   DB79h  console facade
;   DBC0h  storage facade
;   DC00h  banking / XMOVE / LAUNCH
;   DD10h  SIO core

CBIOS_CORE_BASE                 = CBIOS_BASE
CBIOS_CORE_LIMIT                = 0xe000
CBIOS_CORE_END                  = CBIOS_CORE_LIMIT - 1
CBIOS_CORE_SIZE                 = CBIOS_CORE_LIMIT - CBIOS_CORE_BASE

; Existing public symbols kept.
CBIOS_JUMP_TABLE                = CBIOS_BASE
CBIOS_CONSOLE_CODE_BASE         = CBIOS_BASE + 0x0179      ; DB79h
CBIOS_STORAGE_CODE_BASE         = CBIOS_BASE + 0x01c0      ; DBC0h

; Banking is core BIOS, not a driver.
; Existing public symbol name kept, moved into the core BIOS region.
CBIOS_BANKING_CODE_BASE         = CBIOS_BASE + 0x0200      ; DC00h

; ------------------------------------------------------------------------------
; Fixed Driver Slots
; ------------------------------------------------------------------------------
; E000h-F7FFh = six fixed 1 KiB driver/code slots.
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

CBIOS_DRIVER_SLOT0_BASE         = 0xe000
CBIOS_DRIVER_SLOT0_LIMIT        = CBIOS_DRIVER_SLOT0_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT0_END          = CBIOS_DRIVER_SLOT0_LIMIT - 1

CBIOS_DRIVER_SLOT1_BASE         = 0xe400
CBIOS_DRIVER_SLOT1_LIMIT        = CBIOS_DRIVER_SLOT1_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT1_END          = CBIOS_DRIVER_SLOT1_LIMIT - 1

CBIOS_DRIVER_SLOT2_BASE         = 0xe800
CBIOS_DRIVER_SLOT2_LIMIT        = CBIOS_DRIVER_SLOT2_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT2_END          = CBIOS_DRIVER_SLOT2_LIMIT - 1

CBIOS_DRIVER_SLOT3_BASE         = 0xec00
CBIOS_DRIVER_SLOT3_LIMIT        = CBIOS_DRIVER_SLOT3_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT3_END          = CBIOS_DRIVER_SLOT3_LIMIT - 1

CBIOS_DRIVER_SLOT4_BASE         = 0xf000
CBIOS_DRIVER_SLOT4_LIMIT        = CBIOS_DRIVER_SLOT4_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT4_END          = CBIOS_DRIVER_SLOT4_LIMIT - 1

CBIOS_DRIVER_SLOT5_BASE         = 0xf540
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
;   Slot 5:
;     F400h... current RAM disk backend
;
;   Slots 0-4:
;     E000h... Virtual Drip console driver (code, font, shadow, queues)
;
; These names are kept so existing source can still ORG against them.

CBIOS_RAMDISK_CODE_BASE         = CBIOS_DRIVER_SLOT5_BASE              ; F540h
CBIOS_SIO_CORE_CODE_BASE        = CBIOS_BASE + 0x0310                  ; DD10h
CBIOS_VDREP_CONSOLE_CODE_BASE   = CBIOS_DRIVER_SLOT0_BASE              ; E000h
CBIOS_IOCTRL_CODE_BASE          = CBIOS_BASE + 0x0550                  ; DF50h

; Resident code region ends before scratch.
; LIMIT is one byte past the end.
CBIOS_CODE_LIMIT                = CBIOS_DRIVER_SLOT5_LIMIT
CBIOS_CODE_END                  = CBIOS_CODE_LIMIT - 1

; ------------------------------------------------------------------------------
; Scratch Area & Buffers
; ------------------------------------------------------------------------------
; F800h-F9FFh = BIOS scratch / staging.
;
; Current active buffers:
;   F800h-F8FFh MOVE_BUFFER
;   F900h-F97Fh RAMDISK_DIRBUF
;
; The remaining gaps are available for later temporary BIOS work buffers.

CBIOS_SCRATCH_BASE              = CBIOS_DRIVER_SLOT5_LIMIT             ; F940h
CBIOS_SCRATCH_LIMIT             = CBIOS_SCRATCH_BASE + 0x0200          ; FB40h
CBIOS_SCRATCH_END               = CBIOS_SCRATCH_LIMIT - 1

MOVE_BUFFER                     = CBIOS_SCRATCH_BASE
MOVE_BUFFER_SIZE                = 0x0100

RAMDISK_DIRBUF                  = CBIOS_SCRATCH_BASE + 0x0100          ; FA40h
RAMDISK_DIRBUF_SIZE             = 0x0080

; Optional named free scratch windows.
CBIOS_SCRATCH_FREE0             = CBIOS_SCRATCH_BASE + 0x0180          ; FAC0h
CBIOS_SCRATCH_FREE0_LIMIT       = CBIOS_SCRATCH_LIMIT                  ; FB40h
CBIOS_SCRATCH_FREE0_SIZE        = CBIOS_SCRATCH_FREE0_LIMIT - CBIOS_SCRATCH_FREE0

; ------------------------------------------------------------------------------
; IM2 Interrupt Vectors
; ------------------------------------------------------------------------------
; DD10h-DD11h = SIO-core-owned exact IM2 vector table entry.
;
; The SIO core emits ".dw sio_core_isr" at this address.
CBIOS_IM2_VECTOR_TABLE          = CBIOS_SIO_CORE_CODE_BASE
CBIOS_IM2_VECTOR_PAGE           = 0xdd
CBIOS_IM2_VECTOR_ENTRY          = CBIOS_IM2_VECTOR_TABLE

; Byte written to SIO WR2.
; With I = DDh and vector = 10h, the CPU reads the vector word at DD10h.
CBIOS_SIO_VECTOR                = 0x10

; Table is exactly one IM2 entry in this layout.
CBIOS_IM2_VECTOR_SIZE           = 0x0002
CBIOS_IM2_VECTOR_LIMIT          = CBIOS_IM2_VECTOR_TABLE + CBIOS_IM2_VECTOR_SIZE
CBIOS_IM2_VECTOR_END            = CBIOS_IM2_VECTOR_LIMIT - 1

; ------------------------------------------------------------------------------
; Work Areas / Runtime State
; ------------------------------------------------------------------------------
; FB40h-FC3Fh = persistent BIOS runtime state.
;
; Keep existing public work-area names so current source keeps assembling.

CBIOS_WORK_AREA                 = CBIOS_SCRATCH_LIMIT              ; FB40h
CBIOS_WORK_AREA_LIMIT           = CBIOS_WORK_AREA + 0x0100          ; FC40h
CBIOS_WORK_AREA_END             = CBIOS_WORK_AREA_LIMIT - 1

CBIOS_CONSOLE_WORK_AREA         = CBIOS_WORK_AREA + 0x0004
CBIOS_BANK_WORK_AREA            = CBIOS_WORK_AREA + 0x0020
CBIOS_STORAGE_WORK_AREA         = CBIOS_WORK_AREA + 0x0040
CBIOS_SIO_CORE_WORK_AREA        = CBIOS_WORK_AREA + 0x0070
CBIOS_CONSOLE_DRIVER_WORK_AREA  = CBIOS_WORK_AREA + 0x0080

; Optional clearer aliases for docs / validation.
CBIOS_RUNTIME_STATE_BASE        = CBIOS_WORK_AREA
CBIOS_RUNTIME_STATE_LIMIT       = CBIOS_WORK_AREA_LIMIT
CBIOS_RUNTIME_STATE_END         = CBIOS_WORK_AREA_END

; ------------------------------------------------------------------------------
; Stack & Guard
; ------------------------------------------------------------------------------
; FB00h-FFFFh = BIOS stack / reserve.
;
; Stack top remains FFF0h.
; Console backend calls use a lower private top so boot-time BIOS stack frames
; near FFF0h stay intact when CONOUT is called during BOOT.
; Stack grows downward and should not cross FB00h.

CBIOS_STACK_GUARD               = CBIOS_WORK_AREA_LIMIT            ; FC40h
CBIOS_STACK_TOP                 = 0xfff0
CBIOS_CONSOLE_STACK_TOP         = CBIOS_STACK_TOP - 0x0100

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
;   Slots 0-4 contain the Virtual Drip console driver (code, font, shadow,
;   packet buffers, and terminal input queue).
;   Slot 5 contains current RAM disk backend.
;   SIO core is part of core BIOS, not a driver slot occupant.
;   IOCALL is part of core BIOS, not a driver slot occupant.
;   The legacy SIO console driver (cbios_console_sio.asm) is preserved in the
;   repository but not linked in the active VDrip-console build.

LEGACY_RAMDISK_SLOT_FIRST       = 5
LEGACY_RAMDISK_SLOT_LAST        = 5

LEGACY_CONSOLE_SLOT_FIRST       = 1
LEGACY_CONSOLE_SLOT_LAST        = 1
