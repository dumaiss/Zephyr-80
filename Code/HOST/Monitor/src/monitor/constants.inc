; Zephyr-80 monitor CP/M BIOS constants.
;
; These are absolute runtime ABI values. Monitor runs after CP/M BIOS setup and
; therefore uses the BIOS jump table instead of initializing or polling console
; hardware directly.

; CP/M-style BIOS jump table. Keep these symbol names short and unique because
; ASxxxx only treats the leading characters as significant in some modes.
BBASE			= 0xda00
BCNST			= BBASE + 0x06
BCIN			= BBASE + 0x09
BCOUT			= BBASE + 0x0c
BXMOVE			= BBASE + 0x36
BMOVE			= BBASE + 0x33
BLAUNCH			= BBASE + 0x3f
