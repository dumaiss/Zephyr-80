; Shared level constants for the Zephyr-80 IOC diagnostic tools.
;
; These were duplicated in every tool and drifted: five programs still expected
; controller level 62 after the firmware had moved on, and the mismatch text in
; ioc_ping and ioc_sdfmt still named 3E.  Nothing catches that at build time --
; a stale tool assembles cleanly and then refuses to talk to good hardware.  One
; definition, included everywhere, is the only form that stays true.
;
; Track these against their authorities:
;   IOC_FW_LEVEL       -> Code/MCU/IOController/include/ioc_frame.h
;   ZBIOS_XPORT_LEVEL  -> Code/HOST/CPM2.2/src/cbios_defs.inc
;
; Both are read back from the running hardware, so a stale tool reports a
; mismatch rather than misbehaving -- which is why the check exists at all.

IOC_FW_LEVEL		= 70		; 46h — controller firmware expected
ZBIOS_XPORT_LEVEL	= 0x08		; BIOS transport level expected
ZBIOS_XPORT_LEVEL_ADDR	= 0xDF7A	; one byte below IOCALL, readable from ROM

; Printable forms.  The assembler cannot format a number into .ascii, so the
; digits live beside the value they describe: changing the level means editing
; them here, in the same file, instead of hunting message strings across four
; programs -- which is exactly how "level 3E" outlived level 62.
IOC_FW_LEVEL_HEX_HI	= '4
IOC_FW_LEVEL_HEX_LO	= '6
ZBIOS_XPORT_LEVEL_HEX_HI = '0
ZBIOS_XPORT_LEVEL_HEX_LO = '8
IOC_FW_LEVEL_DEC_HI	= '6
IOC_FW_LEVEL_DEC_LO	= '0
