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
; Retained for reference; active callers use the 32-byte compatibility mailbox,
; which IOCALL maps to and from the common variable-length wire packet.
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
; IOC compatibility-mailbox and common-packet constants
; ------------------------------------------------------------------------------
; Command channel (IOCALL transport) = SIO1/B (ports 32h data, 33h ctrl).
; Bulk    channel                     = SIO1/A (ports 30h data, 31h ctrl).
;
; BRING-UP RETARGET: SIO1/A channel-A outputs failed hardware probing, so the
; PIC bit-bang PING-echo bring-up uses SIO1/B.  SIO_COMMAND_*_PORT is used only
; by cbios_iocall.asm and cbios_ioc_command.asm.
;
; Naming convention matches the Z80 SIO channel letters (A/B), not the MCU
; KiCad schematic net names (SIO_PORTA_CS / SIO_PORTB_CS).

SIO_COMMAND_DATA_PORT           = SIO1B_DATA      ; 32h — Command channel data (B)
SIO_COMMAND_CTRL_PORT           = SIO1B_CTRL      ; 33h — Command channel control (B)
SIO_BULK_DATA_PORT              = SIO1A_DATA      ; 30h — Bulk channel data
SIO_BULK_CTRL_PORT              = SIO1A_CTRL      ; 31h — Bulk channel control

; BIOS-facing compatibility mailboxes remain 32 bytes.  The wire format on both
; SIO lanes is the common variable-length packet below.
;
; Mailbox layout (owned by callers/consumers):
;   byte 0      class / command / response type
;   byte 1      sequence number
;   byte 2      status / flags
;   byte 3      payload length (consumer-defined)
;   bytes 4-19  payload bytes
;   bytes 20-31 reserved / command-specific
IOC_FRAME_SIZE                  = 0x20
IOC_OFF_CLASS                   = 0x00
IOC_OFF_STATUS                  = 0x02
IOC_OFF_LEN                     = 0x03
IOC_OFF_PAYLOAD                 = 0x04

; Common packet, both lanes and both directions:
;   A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
; LEN counts TYPE + SEQ + STATUS + DATA.  CRC covers LEN_LO through DATA,
; polynomial 1021h, init 0000h, MSB-first, no final XOR.
IOC_PACKET_SYNC0                = 0xa5
IOC_PACKET_SYNC1                = 0x5a
IOC_PACKET_FIXED_LEN            = 0x03
IOC_PACKET_CRC_BYTES            = 0x02
IOC_COMMAND_MAX_DATA            = 0x1a       ; bytes 4..29 in compatibility frame

; Sequence ownership is transport-wide.  Callers build type/status/length/data;
; IOCALL stamps the sequence, puts the CRC only on the wire, and verifies both
; before returning.  Compatibility-mailbox bytes 30 and 31 remain reserved.
IOC_OFF_SEQ                     = 0x01

; BIOS transport status codes returned by IOCALL.
; These are transport-layer codes; MCU command status is in mailbox byte 2.
IOC_XPORT_OK                    = 0x00
IOC_XPORT_TIMEOUT               = 0x01
IOC_XPORT_BAD_FRAME             = 0x02
IOC_XPORT_HW_ERROR              = 0x03
IOC_XPORT_NOT_READY             = 0x04       ; MCU never advertised COMMAND_READY
IOC_XPORT_BAD_CRC               = 0x05       ; reply CRC did not match
IOC_XPORT_BAD_SEQ               = 0x06       ; reply echoed the wrong sequence
IOC_XPORT_TIMEOUT_REPLY_MARKER  = 0x11       ; bring-up diagnostic: no reply byte seen
IOC_XPORT_TIMEOUT_REPLY_BODY    = 0x12       ; bring-up diagnostic: reply began, then stalled

; IOC command/response type bytes used by bring-up diagnostics.
IOC_CMD_PING                    = 0x01
IOC_RSP_PING                    = 0x81

; SIO1/B Command channel register values — External Sync mode.
; MCU is the synchronous clock master; Z80 SIO1/B is externally clocked x1.
;
; SDLC mode cannot be used on this board: SIO1/B /SYNCB is wired to an
; MCU-owned net (it also gates the SIO->MCU MISO buffer), and SDLC/Monosync/
; Bisync drive /SYNC as an OUTPUT, contending with the MCU.  External Sync mode
; makes /SYNC an INPUT (MCU-owned), so the MCU drives it low for the whole
; transaction with no contention.  Framing is the common A5/5A variable-length
; packet described above.  No SIO hardware CRC/FCS is used.
;
; WR4 = 0x30:  bits 5:4 = 11 = External Sync mode, bits 7:6 = 00 = x1 clock
; WR3 = 0xC0:  8-bit RX format, receiver disabled.
; WR3 = 0xD1:  8-bit RX, enter hunt, RX enable, RX CRC disabled
; WR3 = 0xC1:  same, but without entering hunt.  Used while receiving the PIC
;              reply as a raw externally-clocked byte stream during bring-up.
; WR5 = 0x68:  8-bit TX, TX enable, TX CRC disabled, RTS inactive
; WR5 = 0x6A:  same with RTS asserted (to request MCU service)
; WR5 = 0x00:  TX DISABLED, RTS inactive — the idle/release value.
; WR7 = 0x7E:  receive sync char / transmit underrun fill (not used for
;              detection in External Sync; sync is via the /SYNC pin)
;
; RTS-release note (External Sync):  In External Sync the enabled transmitter
; never goes "empty" (it streams sync/fill idle on underrun), so the SIO's
; delayed /RTS-deassert — which waits for the transmitter to finish — never
; completes.  Clearing only the RTS bit (0x6A -> 0x68) therefore leaves /RTS
; latched LOW.  Releasing RTS must also DISABLE the transmitter (WR5 = 0x00) so
; the transmit-empty condition is met and /RTS returns HIGH; sio_command_init
; re-enables TX (0x68) at the start of the next transaction.
SIO_WR4_CMD_EXTSYNC             = 0x30
SIO_WR0_RESET_ERROR             = 0x30
; WR0 command bits 5-3 = 010, Reset External/Status Interrupts.  Needed before
; trusting RR0's modem-status bits: the SIO latches them on change, so a stale
; latch would report a level the pin no longer carries.
SIO_WR0_RESET_EXT_STATUS        = 0x10

; RR0 bit 3 is /DCD.  A SET bit means the pin is LOW, i.e. asserted -- the same
; convention this code uses for RR0 bit 5 / CTS.  On the command channel the MCU
; drives /DCDB as COMMAND_READY.
SIO_RR0_DCD                     = 0x08

; How long IOCALL waits for COMMAND_READY before giving up.  Must comfortably
; exceed the MCU's longest legitimate busy period -- SD initialisation is up to
; about a second and a block write adds ~0.5 s -- while still failing far sooner
; than the ~11 s byte timeout, so a dead controller is reported quickly instead
; of looking like a slow one.  Inner DE x outer B at ~5.6 us per iteration:
; 65536 x 8 x 5.6 us is roughly 2.9 s.
SIO_COMMAND_READY_TIMEOUT       = 0xffff
SIO_COMMAND_READY_OUTER         = 8
SIO_WR3_CMD_RX_OFF              = 0xc0
SIO_WR3_CMD_RX                  = 0xd1
SIO_WR3_CMD_RX_NO_HUNT          = 0xc1
SIO_WR5_CMD_TX_RTS_OFF          = 0x68
SIO_WR5_CMD_TX_RTS_ON           = 0x6a
SIO_WR5_CMD_IDLE                = 0x00
; MUST NOT equal IOC_SYNC_PREAMBLE.
;
; This is the character the SIO shifts out on transmit underrun.  It was 7Eh --
; byte-identical to the frame preamble the MCU hunts for.  Because RTS was
; asserted before the Z80 had loaded the preamble, the wire carried one or more
; fill bytes ahead of it, and the MCU's alignment scan locked onto the FIRST 7Eh
; it saw, which was fill.  The frame then appeared to start N bytes early: the
; MCU read garbage as the command class and echoed the host's class byte back in
; the sequence slot, which the host rejected as BAD_SEQ.
;
; FFh is idle marking, which the MCU already discards, so fill is now
; unambiguously not a preamble.
SIO_EXTSYNC_FILL                = 0xff

; Filler clocked after a request frame so the last frame byte is fully shifted
; out before IOCALL drops RTS (which disables the transmitter).  FFh is the
; marking idle level, and is deliberately not the A5/5A marker so it can never
; be mistaken for the start of another frame.
IOC_SEND_TRAILER_BYTES          = 2
IOC_SEND_TRAILER_FILL           = 0xff

; Bulk channel (SIO1/A) register values, matching the command lane's persistent
; receiver discipline.
;
; Auto Enables is OFF on both variants.  With it on, /DCDA can disable the
; receiver in hardware -- and a disabled receiver is one of the three things the
; SIO manual says destroys character synchronisation, which makes persistent
; External Sync impossible.  The flow control it provided is belt-and-braces
; anyway: IOCBULK and IOCBULKW already poll /CTSA and /DCDA as RR0 status bits.
;
; HUNT is used only until the boundary has been established once; after that
; NO_HUNT keeps the receiver enabled and leaves the boundary alone.
SIO_WR3_BULK_RX_HUNT            = 0xd1   ; 8-bit RX, hunt, RX enable
SIO_WR3_BULK_RX_NO_HUNT         = 0xc1   ; 8-bit RX, RX enable, boundary kept
SIO_WR5_BULK_RTS_ON             = 0xea   ; DTR on, 8-bit TX, TX enable, RTS on
SIO_WR5_BULK_RTS_OFF            = 0xe8   ; same, RTS off
SIO_WR5_BULK_IDLE               = 0xe0   ; same format, TX disabled, RTS off

; Bulk WRITE (Z80 -> MCU): the receiver stays ENABLED during transmit.  The
; host polls /CTSA before streaming instead of using Auto Enables to gate TX.
; The old per-transfer resync tolerated disabling RX; with a persistent
; boundary, that throws the boundary away.  The idle bytes collected while the
; host transmits are removed by the drain before the next receive.
SIO_WR3_BULK_TX                 = 0xc1   ; 8-bit RX, RX stays enabled
; WR0 command: reset the Tx Underrun/EOM latch.  Must be issued AFTER the first
; byte is in the transmit buffer -- see IOCBULKW.
SIO_WR0_RESET_EOM               = 0xc0
; RR1 bit 6: Tx Underrun/EOM.  Set after a transfer means the transmitter ran
; dry and streamed WR7 fill in place of data.
SIO_RR1_TX_UNDERRUN             = 0x40

; RR1 bit 0, "All Sent": the transmitter has no buffered byte AND nothing left
; in its shift register.  It is the only way to know a byte written with
; put_byte has actually reached the wire, because put_byte returns as soon as
; the BUFFER is free -- one byte earlier than that.
SIO_RR1_ALL_SENT                = 0x01

; Bounded wait for All Sent.  One byte at the bulk lane's pacing is ~24 us, so
; a couple of byte times is generous; this only has to outlast the shift
; register, not the transfer.
SIO_BULK_DRAIN_TIMEOUT          = 0x2000

; Packet marker the host sends ahead of a bulk packet.  Receiving is not
; symmetric with sending: the MCU supplies the clock but cannot know which edge
; the host's transmitter started on, so it searches for both bytes at arbitrary
; bit phase and accepts only a length/header/CRC-consistent candidate.
; Sacrificial lead-in, sent before the preamble.
;
; The first byte out of the transmitter was measured as unreliable during the
; original Auto-Enables bring-up.  Persistent sync no longer uses Auto Enables,
; but retaining the sacrificial byte keeps the established wire format and
; costs essentially nothing.
;
; Keep it disposable: the lead-in absorbs any startup transient and A5 5A
; follows on a transmitter that is already running.  00h rather than something
; distinctive on purpose -- it must not be mistaken for the preamble by the
; MCU's bit search.
IOC_BULK_LEADIN                 = 0x00
IOC_BULK_PREAMBLE_0             = IOC_PACKET_SYNC0
IOC_BULK_PREAMBLE_1             = IOC_PACKET_SYNC1
IOC_BULK_PACKET_SCAN_LIMIT      = 0x08

; Longest bulk PAYLOAD, one SD sector.  Back to 512 now that the CRC trailer is
; the transport's business: IOCBULK and IOCBULKW carry it on the wire themselves
; and callers pass a payload-sized buffer and a payload-sized count.
;
; It was briefly 514 while the trailer was the caller's problem, and that was a
; wart -- raising the bound without fixing the 16-bit comparison beneath it
; rejected every transfer until it was found.
IOC_BULK_MAX_LEN                = 512

; External Sync framing: software byte-alignment preamble.  Sent as the first
; byte of every frame; the receiver hunts for it to find the frame boundary.
; (Mostly-zero PING/RESET payloads cannot contain this pattern.)
IOC_SYNC_PREAMBLE               = IOC_PACKET_SYNC0
IOC_SYNC_PREAMBLE_1             = IOC_PACKET_SYNC1

; Link bring-up.  Clears the MCU's "boundary already established" flag so the
; reply to THIS request carries the falling /SYNC edge the host's receiver needs.
; Issued once from cold boot, right after the SIO channels are configured; it is
; idempotent, so it is also the recovery path if synchronisation is ever
; declared suspect.
IOC_CMD_LINK_SYNC               = 0x0c
IOC_RSP_LINK_SYNC               = 0x8c

; Bring-up attempts before giving up.  Each one re-enters Hunt on this side and
; makes the MCU emit a fresh sync edge, so they are genuinely independent tries
; rather than the same failed state repeated.
IOC_LINK_BRINGUP_TRIES          = 4

; Z80 SIO receive FIFO: three buffer registers behind the shift register.
IOC_RX_FIFO_DEPTH               = 3

; Reply-marker scan budget.  The PIC bit-bang bring-up clocks a full
; SDLC_RX_WINDOW_BYTES receive window while it is collecting the Z80 request.
; During that full-duplex phase the Z80 RX side sees idle/fill bytes before the
; PIC dispatches and starts sending the reply.  Keep this above the PIC receive
; window so IOCALL does not return BAD_FRAME before the reply can begin.
SIO_COMMAND_REPLY_SCAN_LIMIT    = 0xa0

; Timeout for Command channel polled byte operations.
; The MCU only clocks during active transactions; timeout prevents indefinite hang
; if the MCU is absent or not clocking.
;
; DEBUG BRING-UP: the byte-poll wait is a 24-bit countdown = SIO_COMMAND_TIMEOUT
; (16-bit inner) repeated SIO_COMMAND_TIMEOUT_OUTER times.  This is deliberately
; huge (order of minutes at a few MHz) so the PIC side can be single-stepped in
; the debugger without the Z80 giving up; it still returns IOC_XPORT_TIMEOUT
; instead of hanging forever.  For production, drop OUTER back to 1.
SIO_COMMAND_TIMEOUT             = 0xffff
; 0x04, not 0x20.  At ~5.6 us per inner iteration this is ~1.5 s instead of
; ~11 s, and it must only exceed the MCU's longest legitimate silence: the card
; read inside a SD_READ_BULK transaction, worst case ~1 s during initialisation.
; COMMAND_READY on /DCDB now gates "MCU busy" separately, so this timeout only
; has to cover a reply that is genuinely coming.
;
; This is a bring-up throughput decision, not a correctness one: every failure
; costs its full timeout, so at 0x20 a handful of errors made a soak run take
; minutes and the interrupt counter measured waiting rather than work.
SIO_COMMAND_TIMEOUT_OUTER       = 0x04

; Code placement for IOC Command-channel transport helpers.
; The generated map is authoritative for VDRIP_CONSOLE_CODE_END.
;
; Moved to F000h, taking driver slot 4.
;
; First step was F52Ch -> F400h, using the genuine slack between slot 4's end
; and slot 5's base, which bought ~300 bytes for the command-frame CRC.  That
; left 124 free, which is not enough for the bulk write entry.
;
; Slot 4 (F000h-F3FFh) is nominally part of the VDrip console driver's five-slot
; reserve, but the driver ends around ECB8h -- slots 3 and 4 have never been
; used.  Reallocating slot 4 to the transport costs nothing today and is
; reversible if the console driver ever grows that far; slot 3 remains as its
; headroom.
;
; MOVE_BUFFER was NOT reclaimed for this.  Despite looking idle it is live
; scratch for the VDrip storage backend, cbios_bank's cross-bank MOVE and the
; ramdisk path.
CBIOS_IOC_COMMAND_CODE_BASE     = 0xf000

; Overflow half of the unified IOC transport.  The active VDrip console image
; ends at ECB9h, leaving ED00h-EFFFh unused inside its reserved slot-3
; headroom.  IOCBULKW and the small link helpers live here so the SD backend
; remains contiguous and no scratch/TPA allocation is consumed.
CBIOS_IOC_BULK_CODE_BASE        = 0xed00

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
CBIOS_CONSOLE_CODE_BASE         = CBIOS_BASE + 0x017c      ; DB7Ch
CBIOS_STORAGE_CODE_BASE         = CBIOS_BASE + 0x01c3      ; DBC3h

; Banking is core BIOS, not a driver.
; Existing public symbol name kept, moved into the core BIOS region.
; Console, storage and banking bases were each shifted up 3 bytes to make room
; for the IOCBULKW vector at ZBIOS_EXT_BASE + 15h.  The core run DA00h-DB78h,
; which holds the CP/M jump table and the extension vectors, was exactly full.
; Banking had 98 bytes of slack and absorbs the shift; nothing at or above the
; SIO core base (DD10h) moves, so the IM2 vector entry is untouched.
CBIOS_BANKING_CODE_BASE         = CBIOS_BASE + 0x0203      ; DC03h

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
;   Slots 0-4:
;     E000h... Virtual Drip V9958 console (no BIOS screen mirror)
;
; Moved up from F900h to reclaim room for the transport, which sits immediately
; below it and was FULL -- adding nine bytes to vdrip_transport_wait_ready
; overflowed straight into this base.  Slot 5 ends at FA7Fh and the storage
; backend ended at FA63h, so the 28 unused bytes were on the wrong side of this
; constant.  Shifting it up 16 hands those to the transport and still leaves the
; storage backend clear of FA80h; check_overlap.py enforces both ends.
CBIOS_STORAGE_VDRIP_CODE_BASE         = 0xf910                                ; follows common VDrip transport
CBIOS_VDRIP_TRANSPORT_CODE_BASE       = CBIOS_DRIVER_SLOT5_BASE              ; F680h
; Reclaimed gap between the banking module (ends DCB0h) and the SIO core, which
; is pinned at DD10h.  95 bytes that belonged to nothing.
;
; It exists because the core BIOS regions are byte-full: boot (DAADh-DB7Bh),
; banking and the SIO core all have ZERO free bytes, so adding a single 3-byte
; call to cold boot overflowed into the console facade.  Small self-contained
; routines are relocated here to buy that space back.
CBIOS_SPARE_CODE_BASE           = CBIOS_BASE + 0x02b1                  ; DCB1h

; Link diagnostic block, at a FIXED address so a .COM can read it directly when
; the link itself is too broken to answer a PING.  The command portion is
; written on reply-marker timeout; the Bulk portion is refreshed by IOCBULK.
;
;   +0  RR0 at the moment of failure.  Bit 4 is Sync/Hunt: 1 = the receiver is
;       STILL HUNTING, i.e. the MCU's falling /SYNC edge never landed.
;   +1  RR1 (receive error latches)
;   +2  ioc_rx_synced
;   +3  ioc_link_ready
;   +4..+13  command marker-scan state
;   +0Eh      Bulk rejection stage
;   +0Fh      Bulk marker-scan count (on marker exhaustion)
;   +10h      last Bulk marker-scan byte; +11h..+17h reserved
;   +18h..+1Ch decoded Bulk LEN/TYPE/SEQ/STATUS header
;   +1Dh..+1Fh Bulk RR0, RR1, and verified-sync flag
;   +20h..+23h expected Bulk LEN, TYPE, and SEQ
CBIOS_IOC_DIAG_BASE             = CBIOS_BASE + 0x02c0                  ; DCC0h

; USB keyboard console input, merged into CONST/CONIN alongside the proxy
; keyboard's textq.  Placed in the tail of driver slot 3, after the IOC Bulk
; overflow ends at EF3Ah -- it belongs with the IOC code because it drives
; IOCALL, and the pre-storage gap at F41Bh is only 21 bytes before
; CBIOS_STORAGE_SD_CODE_BASE.  This fills slot 3; check_overlap.py enforces the
; EFFFh ceiling.
CBIOS_HID_INPUT_CODE_BASE       = 0xef3e
; HID mailbox/queue state occupies the otherwise-unused gap immediately after
; the SD backend.  It must not live in MOVE_BUFFER because CONST can fire from
; BDOS OUTCHAR while a storage request is staged, and it must not live at FD00h:
; FD00h-FDFFh is SD_STORAGE_ALV_BUFFER, the SD drive's CP/M allocation vector.
;
; The request frame is only five bytes (TYPE/SEQ/STATUS/LEN/max-wanted), not a
; full 32-byte mailbox.  Together with the 32-byte reply, 16-byte queue and five
; queue-control bytes, the state occupies 58 bytes: F642h-F67Bh.  The VDrip
; transport begins at F680h, leaving four guard bytes.
CBIOS_HID_INPUT_STATE_BASE      = 0xf642

CBIOS_SIO_CORE_CODE_BASE        = CBIOS_BASE + 0x0310                  ; DD10h
CBIOS_VDREP_CONSOLE_CODE_BASE   = CBIOS_DRIVER_SLOT0_BASE              ; E000h
CBIOS_BIOS_EXT_CODE_BASE        = CBIOS_BASE + 0x0550                  ; DF50h
CBIOS_IOCTRL_CODE_BASE          = CBIOS_BASE + 0x057B                  ; DF7Bh — immediately after VIDEO_SEND

; Transport level, readable directly from ROM at a fixed address.
;
; The MCU reports IOC_FW_LEVEL over PING, which proves the CONTROLLER is
; current and says nothing about the BIOS.  A stale ROM then presents as a
; transport fault: a wire change was made, flashed to the PIC only, and the
; capture came back byte-identical to the previous one three times running
; before the pairing was checked rather than assumed.
;
; Placed one byte below IOCALL, inside VIDEO_SEND's tail slack.  Both regions
; sit at fixed offsets from CBIOS_BASE and IOCALL's address is already published
; ABI, so this address moves only if the vector table's target does.
;
;   5  bulk writes lead with a sacrificial byte before their marker
;   6  both lanes use A5 5A/LEN/TYPE/SEQ/STATUS/DATA/CRC packets and persistent
;      External Sync; command mailboxes remain a compatibility API only
;   7  the hand-clocked sync-establishing byte is disposable; the complete
;      A5 5A packet marker always follows as aligned SPI bytes on both lanes
ZBIOS_XPORT_LEVEL               = 0x07
ZBIOS_XPORT_LEVEL_ADDR          = CBIOS_IOCTRL_CODE_BASE - 1           ; DF7Ah

; VDrip CP850 font placement in bank 0 TPA.
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
; ---------------------------------------------------------------------------
; Drive assignment
;
; A: is the VDrip proxy volume, B: is the SD card.  Both backends are linked;
; the facade routes on the drive selected by SELDSK.  The VDrip volume stays
; mounted so files can be copied across before it is retired.
;
; Geometry is identical for both -- 16384 tracks x 4 records x 128 bytes = 8 MiB
; -- so they share one DPB and one directory buffer.  Only the DPH and the
; allocation vector have to be per drive.
; ---------------------------------------------------------------------------
; CP/M searches the default drive on every command, so whichever backend is A:
; is the one a fault takes the machine down with.  Putting the known-good volume
; there means a misbehaving SD path costs a failed DIR on B: instead of an
; unusable prompt.
;
; To go back to SD as the boot volume, swap these two values.  Nothing else
; needs to change: the dispatcher routes on whatever SELDSK was given and each
; backend owns its own DPH and allocation vector.
SD_STORAGE_DRIVE                      = 0x01       ; B:
VDRIP_STORAGE_DRIVE                   = 0x00       ; A:

; The drive id the VDrip PROTOCOL carries, which is not the CP/M drive letter.
; It names the volume on the proxy side and has always been 0; moving the CP/M
; letter to B: must not change what goes on the wire.
VDRIP_STORAGE_PROTO_DRIVE             = 0x00

; SD storage backend: second half of driver slot 4.  The transport occupies
; F000h-F334h, so the split at F400h leaves it 204 bytes of headroom and gives
; the backend 640.
; Moved up from F400h to give slot 4 room.
;
; Slot 4 (F000h-F3FFh) holds the IOC transport helpers and is full to the byte;
; adding the bulk transmitter drain overflowed it by one.  The SD storage code
; below ends around F611h with roughly 110 spare bytes before FA80h, so the
; cheapest space is on this side of the boundary.  check_overlap.py enforces
; both ends, so a mistake here fails the build rather than the machine.
CBIOS_STORAGE_SD_CODE_BASE            = 0xf430
CBIOS_STORAGE_SD_CODE_LIMIT           = 0xf680
; The select probe is split across exact, otherwise-unused fixed-layout gaps.
; The generated memory-layout checks validate every fragment independently.
CBIOS_SD_PROBE_RECOVERY_BASE          = 0xdfed
CBIOS_SD_PROBE_REQUEST_BASE           = 0xf41b
CBIOS_SD_PROBE_SUCCESS_BASE           = 0xf909
CBIOS_SD_PROBE_RESULT_BASE            = 0xfa74

; Per-drive state.  The allocation vector is the only large piece; it lands in
; the 256 bytes of scratch that were unallocated, which it fills exactly.
SD_STORAGE_ALV_BUFFER                 = CBIOS_SCRATCH_BASE + 0x0280   ; FD00h
SD_STORAGE_DPH                        = VDRIP_STORAGE_DPHDPB_BASE + 0x20  ; FB60h

; Scratch layout inside MOVE_BUFFER for one SD transaction.  192 bytes divides
; exactly into one 128-byte record and the two 32-byte command frames, which is
; why the buffer is not shrunk any further.
SD_STORAGE_DATA_OFF                   = 0x0000     ; 128 bytes
SD_STORAGE_TX_OFF                     = 0x0080     ; 32 bytes
SD_STORAGE_RX_OFF                     = 0x00a0     ; 32 bytes

; Record commands on the IO Controller.
SD_CMD_PROBE                          = 0x03       ; MCU reads SD block 0 in-command
SD_CMD_READ_REC                       = 0x08
SD_RSP_READ_REC                       = 0x88
SD_CMD_WRITE_REC                      = 0x09
SD_RSP_WRITE_REC                      = 0x89
SD_CMD_FLUSH                          = 0x0a
SD_RSP_FLUSH                          = 0x8a
SD_CMD_XFER_STATUS                    = 0x06
SD_RSP_XFER_STATUS                    = 0x86
SD_STORAGE_RECORD_BYTES               = 0x0080

; SD backend state.  Lives in the storage work area's tail, which had 12 free
; bytes between the VDrip transport's block and storage_caller_sp.
SD_STORAGE_WORK_AREA                  = CBIOS_WORK_AREA + 0x005c        ; FE5Ch
sd_storage_track                      = SD_STORAGE_WORK_AREA + 0x00
sd_storage_sector                     = SD_STORAGE_WORK_AREA + 0x02
sd_storage_record                     = SD_STORAGE_WORK_AREA + 0x04
sd_storage_saved_bank                 = SD_STORAGE_WORK_AREA + 0x06
sd_storage_expect                     = SD_STORAGE_WORK_AREA + 0x07
stg_drive                             = SD_STORAGE_WORK_AREA + 0x08
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
