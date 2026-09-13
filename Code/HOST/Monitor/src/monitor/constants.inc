; Zephyr-80 monitor CP/M BIOS constants.
;
; These are absolute runtime ABI values. Monitor runs after CP/M BIOS setup and
; therefore uses the BIOS jump table instead of initializing or polling console
; hardware directly.

; CP/M BIOS jump table entries, as offsets.  The banked OS publishes no fixed
; addresses: bios_console (sio_console.inc) finds the table through page zero's
; warm-boot vector.  Bank moves use Zephyr BDOS functions (zbdos.inc).
BIOS_CONST_OFFSET	= 0x06
BIOS_CONIN_OFFSET	= 0x09
BIOS_CONOUT_OFFSET	= 0x0c
