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

; Memory banking latch at I/O port 00h:
; - D0-D2 = SRAM bank number 0-7
; - D3    = shadow/copy mode
; - D4    = ROM disable
; - D5-D7 = ROM page number 0-7
BANK_PORT		= 0x00
SHADOW_BIT		= 0x08
ROMDIS_BIT		= 0x10
COPY_LATCH0		= SHADOW_BIT
RAM_ONLY_BANK0		= ROMDIS_BIT

HIGH_COPY_START		= 0xe000
HIGH_COPY_LEN		= 0x2000
PAGE_COPY_START		= 0x0000
PAGE_COPY_LEN		= 0xe000
SHADOW_COPY_BANK_VAR	= 0xfffe

; The monitor relocates ROM into RAM before initializing this stack. The stack
; lives in the high common SRAM bank-0 area so it remains stable across later
; low-bank switching.
STACK_TOP		= 0xffff
