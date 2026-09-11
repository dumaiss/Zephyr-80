; ---------------------------------------------------------------------------
; ROM service ABI -- shared by the resident gate and the ROM service page.
;
; This file is included by BOTH sides of the call:
;
;   src/cbios_rom_gate.asm   the resident gate, assembled into the firmware
;   src/romsvc_page4.asm     the service page, assembled standalone into
;                            build/romservices.bin and attached at ROM page 4
;
; They are separate binaries linked at different origins, so nothing but this
; file keeps them agreeing about the entry address, the service numbers and the
; register contract.  Change it on one side only and the machine jumps into the
; middle of something at run time.
;
; Mechanism, in one paragraph: the gate writes the banking latch to enter
; shadow/copy mode with ROM page 4 selected, which replaces reads of
; 0000h-BFFFh with that ROM page while leaving C000h-FFFFh as common SRAM
; bank 0.  The gate, its stack and all mutable state live in that common
; window, so they stay addressable while the service runs.  The service returns,
; the gate restores the latch, and the caller's low RAM reappears.
;
; Two consequences shape every service:
;
;   A service CANNOT READ the caller's memory below C000h.  It is looking at
;   ROM there, not at RAM.  Arguments arrive in registers or in the common
;   window, never as a pointer to a buffer the caller filled.
;
;   A service CAN WRITE the caller's memory below C000h.  Shadow mode replaces
;   reads only; writes still land in the selected SRAM bank.  This is what lets
;   a future disk read deliver a sector straight to the caller's DMA address
;   with no staging buffer, and ROMSVC_WRITE_SIG exists to prove it on hardware
;   rather than on the strength of the decoder equations.
; ---------------------------------------------------------------------------

; ROM page carrying the service image.  Pages 0-3 are taken: 0 is the firmware,
; 1-3 are the A: ROM disk.  4-7 are free on the 512 KiB part.
ROMSVC_PAGE                 = 4

; Page offsets.  Both are inside 0000h-BFFFh, the range shadow mode exposes.
;
; The signature sits at offset 0 rather than the entry point because offset 0 is
; also where a page would be executed from if something went wrong with the
; latch, and a run of text is a safer thing to land on than a dispatch table.
ROMSVC_SIGNATURE            = 0x0000
ROMSVC_SIGNATURE_LEN        = 16
ROMSVC_ENTRY                = 0x0100

; Returned by ROMSVC_IDENT.  Arbitrary, but neither 00h nor FFh: those are what
; an unprogrammed or unselected page reads as, and a test that cannot tell "the
; service answered" from "nothing answered" is not a test.
ROMSVC_MAGIC                = 0x5a

; --- Service numbers, passed in A --------------------------------------------
;
; ROMSVC_IDENT      In:  nothing
;                   Out: A = ROMSVC_MAGIC
;                   Proves the gate reached ROM page 4 and came back.
;
; ROMSVC_ECHO       In:  HL = any value
;                   Out: HL = HL + 1, A = 0
;                   Proves arguments cross the gate in both directions.
;
; ROMSVC_WRITE_SIG  In:  DE = destination, anywhere in the caller's bank
;                   Out: A = 0, DE = DE + ROMSVC_SIGNATURE_LEN
;                   Copies the signature from ROM to the caller's memory.  The
;                   source is ROM the caller cannot see and the destination is
;                   RAM the service cannot read, so a correct result can only
;                   come from shadow mode behaving as the decoder says.
;
; ROMSVC_SPIN       In:  B = delay units, roughly a millisecond each
;                   Out: A = 0
;                   A deliberately slow service.  Phase 2's services returned
;                   in microseconds, which proves nothing about the interrupt
;                   question: the console's real cost is the V9958 command
;                   wait, and whole-screen fills block for milliseconds.  This
;                   reproduces that duration without needing the console, so
;                   the gate's decision to leave interrupts enabled can be
;                   observed rather than argued.
ROMSVC_IDENT                = 0x00
ROMSVC_ECHO                 = 0x01
ROMSVC_WRITE_SIG            = 0x02
;
; ROMSVC_UPLOAD_ATLAS  In:  nothing
;                      Out: A = 0
;                      Rebuilds both glyph atlases in VRAM from the CP850 font.
;                      The first real migration: the font itself lives on this
;                      page now, not at 8000h in the TPA where a transient could
;                      overwrite it between one console reset and the next.
ROMSVC_SPIN                 = 0x03
;
; ROMSVC_DISPLAY_INIT   In/Out: nothing
;                       The whole display bring-up: G6 mode, hardware wait,
;                       paced palette, atlas, clear, cursor, present, display
;                       on.  One service rather than eight, because it is one
;                       sequence with an exact ordering -- and because the gate
;                       is not reentrant, so the steps must call each other on
;                       the ROM side rather than through their resident names.
;
; ROMSVC_RESET_DISPLAY  In/Out: nothing
;                       ESC-c and VIDEO_SEND reset.  Same cluster, entered from
;                       the terminal parser instead of from boot.
ROMSVC_UPLOAD_ATLAS         = 0x04
ROMSVC_DISPLAY_INIT         = 0x05
;
; ROMSVC_CONSOLE_BYTE   In:  C = console byte
;                       Out: nothing
;                       The terminal layer: parser, ANSI handlers and text
;                       semantics.  Entered only for what the resident fast path
;                       will not handle -- a control byte, an escape sequence, a
;                       full run buffer, or the last column.
ROMSVC_RESET_DISPLAY        = 0x06
;
; ROMSVC_FLUSH_SYNC     In/Out: nothing
;                       Flush the pending printable run, publish the cursor
;                       sprite, and present the frame.  CONST and CONIN both
;                       did these three calls back to back; they are one
;                       service so the pair crosses the gate once rather than
;                       three times.
;
;                       CONST keeps its own test of print_run_count on the
;                       resident side, so a program polling for input with
;                       nothing pending never enters ROM at all -- which
;                       matters, because BDOS calls CONST once per character
;                       printed.
ROMSVC_CONSOLE_BYTE         = 0x07
;
; SD storage transactions.  The record staging is NOT here: sd_copy_to_dma and
; sd_copy_from_dma select the caller's DMA bank, and a service that writes the
; bank latch unmaps the ROM it is executing from.  The resident thunks bracket
; these calls with the staging instead.
;
; ROMSVC_SD_READ    fills MOVE_BUFFER from the card; the thunk copies it out
; ROMSVC_SD_WRITE   sends MOVE_BUFFER, which the thunk filled first
; ROMSVC_SD_FLUSH   flush the controller's deferred writes
; ROMSVC_SD_PROBE   B: select probe, returns the DPH or zero
; ROMSVC_SD_PROBE2  C: select probe
ROMSVC_FLUSH_SYNC           = 0x08
ROMSVC_SD_READ              = 0x09
ROMSVC_SD_WRITE             = 0x0a
ROMSVC_SD_FLUSH             = 0x0b
ROMSVC_SD_PROBE             = 0x0c
ROMSVC_SD_PROBE2            = 0x0d
ROMSVC_COUNT                = 0x0e

; Font base, as a page offset.  Deliberately the address the resident code used
; when the font lived in bank 0's TPA: the glyph-address arithmetic in the atlas
; builder is unchanged by the move, which is one fewer thing to get wrong.
ROMSVC_FONT_BASE            = 0x8000
ROMSVC_FONT_BYTES           = 2048

; IM1 landing pad.  The gate can read the IM2 vector page out of I, but no
; instruction reports the interrupt MODE, so it cannot tell whether an
; application has switched to IM1 -- where an interrupt vectors to 0038h, which
; is this page while a service runs.  A RETI here defers the interrupt instead
; of executing whatever byte happened to live at that offset: the device keeps
; its request asserted, IFF1 stays clear until the gate's exit path restores it,
; and the real handler takes the interrupt a few microseconds later.
ROMSVC_IM1_PAD              = 0x0038

; Status in A for services that do not return a value there.
ROMSVC_OK                   = 0x00
ROMSVC_BAD_SERVICE          = 0xff
