; Zephyr-80 monitor hardware constants.
;
; These are absolute hardware and memory-map values. They are included before
; executable code so every module uses the same port addresses and safety
; limits without allocating storage.

; Z80 SIO port map. The board wires A0 to SIO C/D and A1 to SIO B/A:
;   20h = SIO A data, 21h = SIO A control
;   22h = SIO B data, 23h = SIO B control
; The monitor uses channel B only.
SIOB_DATA		= 0x22
SIOB_CTRL		= 0x23

; RR0 status bits used by the polling console routines.
SIO_RR0_RX_AVAIL	= 0x01
SIO_RR0_TX_EMPTY	= 0x04

; The monitor stack starts at the top of SRAM. RAM_SAFE_BASE is the first
; address where reads and writes both access SRAM while ROM_DIS=0.
STACK_TOP		= 0xffff
RAM_SAFE_BASE		= 0x6000
