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
;   FF80h │   CBIOS_CONSOLE_STACK_TOP                    │
;         │   stack grows downward                       │
;   FE80h ├──────────────────────────────────────────────┤
;   FE7Fh │ Runtime state end                            │
;   FE00h │ Runtime state start                          │
;         │   CURRENT_BANK / DMA / XMOVE                 │
;         │   storage state                              │
;         │   SIO core state                             │
;         │   console driver state                       │
;         ├──────────────────────────────────────────────┤
;   FDFFh │ Scratch / staging end                        │
;   FC00h │   VDRIP_STORAGE_ALV                         │
;   FB80h │   VDRIP_STORAGE_DIRBUF                      │
;   FA80h │   MOVE_BUFFER                                │
;         ├──────────────────────────────────────────────┤
;   FA7Fh │ Driver slot 5 end                            │
;   F7EBh │   VDrip storage backend                      │
;   F680h │ Driver slot 5 start: IOCALL / storage        │
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
;   DF50h │   VIDEO_SEND (BIOS display extension)         │
;   DD10h │   SIO core + exact IM2 vector entry          │
;   DC00h │   banking / XMOVE                            │
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

; IOCALL caller-provided request block offsets (legacy variable-length protocol).
; Retained for reference; the active IOCALL now uses the fixed-frame contract.
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
; IOC Fixed-Frame Transport Constants
; ------------------------------------------------------------------------------
; Command channel = SIO1/B (ports 32h data, 33h ctrl).
; Bulk    channel = SIO1/A (ports 30h data, 31h ctrl) — inactive in Phase 1.
;
; Naming convention matches the Z80 SIO channel letters (A/B), not the MCU
; KiCad schematic net names (SIO_PORTA_CS / SIO_PORTB_CS).

SIO_COMMAND_DATA_PORT           = SIO1B_DATA      ; 32h — Command channel data
SIO_COMMAND_CTRL_PORT           = SIO1B_CTRL      ; 33h — Command channel control
SIO_BULK_DATA_PORT              = SIO1A_DATA      ; 30h — Bulk channel data
SIO_BULK_CTRL_PORT              = SIO1A_CTRL      ; 31h — Bulk channel control

; All IOC Command-channel frames are exactly 32 bytes.
; Frame layout (owned by callers/consumers — BIOS transport does not decode):
;   byte 0      class / command / response type
;   byte 1      sequence number
;   byte 2      status / flags
;   byte 3      payload length (consumer-defined)
;   bytes 4-19  payload bytes
;   bytes 20-31 reserved / command-specific
IOC_FRAME_SIZE                  = 0x20

; BIOS transport status codes returned by IOCALL.
; These are transport-layer codes; MCU command status is in the 32-byte frame.
IOC_XPORT_OK                    = 0x00
IOC_XPORT_TIMEOUT               = 0x01
IOC_XPORT_BAD_FRAME             = 0x02
IOC_XPORT_HW_ERROR              = 0x03

; SIO1/B Command channel register values — External Sync mode.
; MCU is the synchronous clock master; Z80 SIO1/B is externally clocked x1.
;
; SDLC mode cannot be used on this board: SIO1/B /SYNCB is wired to an
; MCU-owned net (it also gates the SIO->MCU MISO buffer), and SDLC/Monosync/
; Bisync drive /SYNC as an OUTPUT, contending with the MCU.  External Sync mode
; makes /SYNC an INPUT (MCU-owned), so the MCU drives it low for the whole
; transaction with no contention.  Framing (preamble + 32-byte frame + CRC) is
; handled in software on both sides; the SIO's hardware CRC is disabled.
;
; WR4 = 0x30:  bits 5:4 = 11 = External Sync mode, bits 7:6 = 00 = x1 clock
; WR3 = 0xD1:  8-bit RX, enter hunt, RX enable, RX CRC disabled
; WR5 = 0x68:  8-bit TX, TX enable, TX CRC disabled, RTS inactive
; WR5 = 0x6A:  same with RTS asserted (to request MCU service)
; WR7 = 0x7E:  receive sync char / transmit underrun fill (not used for
;              detection in External Sync; sync is via the /SYNC pin)
SIO_WR4_CMD_EXTSYNC             = 0x30
SIO_WR3_CMD_RX                  = 0xd1
SIO_WR5_CMD_TX_RTS_OFF          = 0x68
SIO_WR5_CMD_TX_RTS_ON           = 0x6a
SIO_SDLC_FLAG                   = 0x7e

; External Sync framing: software byte-alignment preamble.  Sent as the first
; byte of every frame; the receiver hunts for it to find the frame boundary.
; (Mostly-zero PING/RESET payloads cannot contain this pattern.)
IOC_SYNC_PREAMBLE               = 0x7e

; Timeout for Command channel polled byte operations.
; The MCU only clocks during active transactions; timeout prevents indefinite hang
; if the MCU is absent or not clocking.
SIO_COMMAND_TIMEOUT             = 0xffff

; Code placement for IOC Command-channel transport helpers.
; VDrip console driver ends at F52Bh (VDRIP_CONSOLE_CODE_END).
; F52Ch is the first free byte in the gap before driver slot 5 (F680h).
CBIOS_IOC_COMMAND_CODE_BASE     = 0xf52c

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
; E000h-FA7Fh = fixed driver/code slots.
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

CBIOS_DRIVER_SLOT5_BASE         = 0xf680
CBIOS_DRIVER_SLOT5_LIMIT        = CBIOS_DRIVER_SLOT5_BASE + CBIOS_DRIVER_SLOT_SIZE
CBIOS_DRIVER_SLOT5_END          = CBIOS_DRIVER_SLOT5_LIMIT - 1

CBIOS_DRIVER_SLOTS_BASE         = CBIOS_DRIVER_SLOT0_BASE
CBIOS_DRIVER_SLOTS_LIMIT        = CBIOS_DRIVER_SLOT5_LIMIT
CBIOS_DRIVER_SLOTS_END          = CBIOS_DRIVER_SLOTS_LIMIT - 1

; ------------------------------------------------------------------------------
; Current Transitional Driver Placement
; ------------------------------------------------------------------------------
; Current VDrip placement:
;
;   Slot 5:
;     F7EBh... VDrip storage backend, deliberately packed against FA80h
;
;   Slots 0-5 tail:
;     E000h... Virtual Drip console driver (code, font, shadow, queues)
;
CBIOS_STORAGE_VDRIP_CODE_BASE         = 0xf900                                ; follows common VDrip transport
CBIOS_VDRIP_TRANSPORT_CODE_BASE       = CBIOS_DRIVER_SLOT5_BASE              ; F680h
CBIOS_SIO_CORE_CODE_BASE        = CBIOS_BASE + 0x0310                  ; DD10h
CBIOS_VDREP_CONSOLE_CODE_BASE   = CBIOS_DRIVER_SLOT0_BASE              ; E000h
CBIOS_BIOS_EXT_CODE_BASE        = CBIOS_BASE + 0x0550                  ; DF50h
CBIOS_IOCTRL_CODE_BASE          = CBIOS_BASE + 0x057B                  ; DF7Bh — immediately after VIDEO_SEND

; VDrip font placement in bank 0 TPA.
; Font data lives at VDRIP_FONT_ROM_BASE in the firmware binary (bank 0 ROM).
; The boot shadow copy writes it to SRAM bank 0. text_load_font reads from
; this address in bank 0 SRAM. restore_font_from_rom uses COPY_LATCH0 to
; re-copy from ROM to SRAM bank 0 at warm boot (same technique as CCP restore).
; Programs may overwrite this TPA address after boot; the warm-boot restore
; refreshes it from ROM before text_load_font is called.
VDRIP_FONT_ROM_BASE             = 0x8000                ; font start in bank 0 TPA

; Resident code region ends before scratch.
; LIMIT is one byte past the end.
CBIOS_CODE_LIMIT                = CBIOS_DRIVER_SLOT5_LIMIT
CBIOS_CODE_END                  = CBIOS_CODE_LIMIT - 1

; ------------------------------------------------------------------------------
; Scratch Area & Buffers
; ------------------------------------------------------------------------------
; FA80h-FDFFh = BIOS scratch / staging.
;
; Current active buffers:
;   FA80h-FB3Fh MOVE_BUFFER          (192 bytes; max storage transaction = 134)
;   FB40h-FB7Fh VDRIP_STORAGE_DPHDPB       (DPH+DPB, relocated out of the code slot)
;   FB80h-FBFFh VDRIP_STORAGE_DIRBUF
;   FC00h-FCFFh VDRIP_STORAGE_ALV
;
; VDRIP_STORAGE_ALV is 256 bytes for the 4 KiB allocation-block VDrip disk format.
;
; MOVE_BUFFER was shrunk from 256 to 192 bytes to carve VDRIP_STORAGE_DPHDPB out of
; the scratch area.  The DPH/DPB previously lived at the tail of the VDrip
; storage code slot, which overflowed past FA80h and overlapped MOVE_BUFFER's
; low bytes; every storage transfer then corrupted the DPH ALV pointer and the
; DPB geometry.  A 192-byte MOVE_BUFFER still covers the largest transaction
; (a 134-byte WRITE request: 6-byte header + 128-byte record).

CBIOS_SCRATCH_BASE              = CBIOS_DRIVER_SLOT5_LIMIT             ; FA80h
CBIOS_SCRATCH_LIMIT             = CBIOS_SCRATCH_BASE + 0x0380          ; FE00h
CBIOS_SCRATCH_END               = CBIOS_SCRATCH_LIMIT - 1

MOVE_BUFFER                     = CBIOS_SCRATCH_BASE                   ; FA80h
MOVE_BUFFER_SIZE                = 0x00c0                               ; 192 bytes

VDRIP_STORAGE_DPHDPB_BASE             = MOVE_BUFFER + MOVE_BUFFER_SIZE       ; FB40h
VDRIP_STORAGE_DPHDPB_SIZE             = 0x0040                               ; 64 bytes (DPH+DPB = 31)

VDRIP_STORAGE_DIRBUF                  = CBIOS_SCRATCH_BASE + 0x0100          ; FB80h
VDRIP_STORAGE_DIRBUF_SIZE             = 0x0080

VDRIP_STORAGE_ALV_BUFFER              = CBIOS_SCRATCH_BASE + 0x0180          ; FC00h
VDRIP_STORAGE_ALV_BUFFER_SIZE         = 0x0200

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
; FE00h-FE7Fh = persistent BIOS runtime state.
;
; Keep existing public work-area names so current source keeps assembling.

CBIOS_WORK_AREA                 = CBIOS_SCRATCH_LIMIT              ; FE00h
CBIOS_WORK_AREA_LIMIT           = CBIOS_WORK_AREA + 0x0080          ; FE80h
CBIOS_WORK_AREA_END             = CBIOS_WORK_AREA_LIMIT - 1

CBIOS_CONSOLE_WORK_AREA         = CBIOS_WORK_AREA + 0x0004
CBIOS_BANK_WORK_AREA            = CBIOS_WORK_AREA + 0x0020
CBIOS_STORAGE_WORK_AREA         = CBIOS_WORK_AREA + 0x0040
CBIOS_VDRIP_TRANSPORT_WORK_AREA = CBIOS_WORK_AREA + 0x004b
CBIOS_STORAGE_CALLER_SP         = CBIOS_WORK_AREA + 0x0068
CBIOS_SIO_CORE_WORK_AREA        = CBIOS_WORK_AREA + 0x0070
CBIOS_CONSOLE_DRIVER_WORK_AREA  = CBIOS_WORK_AREA + 0x0080

; Optional clearer aliases for docs / validation.
CBIOS_RUNTIME_STATE_BASE        = CBIOS_WORK_AREA
CBIOS_RUNTIME_STATE_LIMIT       = CBIOS_WORK_AREA_LIMIT
CBIOS_RUNTIME_STATE_END         = CBIOS_WORK_AREA_END

; ------------------------------------------------------------------------------
; Stack & Guard
; ------------------------------------------------------------------------------
; FE80h-FFFFh = BIOS stack / reserve.
;
; Stack top remains FFF0h.
; Console backend calls use a lower private top so boot-time BIOS stack frames
; near FFF0h stay intact when CONOUT is called during BOOT.
; Stack grows downward and should not cross FE80h.

CBIOS_STACK_GUARD               = CBIOS_WORK_AREA_LIMIT            ; FE80h
CBIOS_STACK_TOP                 = 0xfff0
CBIOS_CONSOLE_STACK_TOP         = 0xff80

CBIOS_AREA_LIMIT                = 0x10000
CBIOS_AREA_END                  = 0xffff

; ------------------------------------------------------------------------------
; VDrip Storage Configuration (DPB Mapping)
; ------------------------------------------------------------------------------
VDRIP_STORAGE_DRIVE                   = 0x00
VDRIP_STORAGE_RECORD_BYTES            = 0x0080
VDRIP_STORAGE_TOTAL_RECORDS           = 0x10000
VDRIP_STORAGE_SECTORS_PER_TRACK       = 0x0004
VDRIP_STORAGE_TRACKS                  = 0x4000
VDRIP_STORAGE_OFFSET_TRACKS           = 0x0000
VDRIP_STORAGE_BLOCK_SHIFT             = 0x05
VDRIP_STORAGE_BLOCK_MASK              = 0x1f
VDRIP_STORAGE_EXTENT_MASK             = 0x01
VDRIP_STORAGE_MAX_BLOCK               = 0x07ff
VDRIP_STORAGE_DIR_ENTRIES             = 0x01ff
VDRIP_STORAGE_ALLOC0                  = 0xf0
VDRIP_STORAGE_ALLOC1                  = 0x00
VDRIP_STORAGE_CHECK_SIZE              = 0x0000
VDRIP_STORAGE_ALV_SIZE                = 0x0100

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
; Current VDrip build:
;   Slots 0-4 and the start of slot 5 contain the Virtual Drip console driver
;   (code, font, shadow, packet buffers, and terminal input queue).
;   Slot 5 also contains IOCALL (at CBIOS_DRIVER_SLOT5_BASE) and the VDrip
;   storage backend (at CBIOS_STORAGE_VDRIP_CODE_BASE).
;   SIO core is part of core BIOS, not a driver slot occupant.
;   The legacy SIO console driver (cbios_console_sio.asm) is preserved in the
;   repository but not linked in the active VDrip-console build.

VDRIP_STORAGE_SLOT_FIRST       = 5
VDRIP_STORAGE_SLOT_LAST        = 5

LEGACY_CONSOLE_SLOT_FIRST       = 1
LEGACY_CONSOLE_SLOT_LAST        = 1
