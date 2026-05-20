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

; CP/M-style BIOS jump table. The monitor uses these console ABI entries
; instead of touching the SIO directly.
BIOS_BASE		= 0xe000
BIOS_BOOT		= BIOS_BASE + 0x00
BIOS_WBOOT		= BIOS_BASE + 0x03
BIOS_CONST		= BIOS_BASE + 0x06
BIOS_CONIN		= BIOS_BASE + 0x09
BIOS_CONOUT		= BIOS_BASE + 0x0c
BIOS_LIST		= BIOS_BASE + 0x0f
BIOS_PUNCH		= BIOS_BASE + 0x12
BIOS_READER		= BIOS_BASE + 0x15
BIOS_HOME		= BIOS_BASE + 0x18
BIOS_SELDSK		= BIOS_BASE + 0x1b
BIOS_SETTRK		= BIOS_BASE + 0x1e
BIOS_SETSEC		= BIOS_BASE + 0x21
BIOS_SETDMA		= BIOS_BASE + 0x24
BIOS_READ		= BIOS_BASE + 0x27
BIOS_WRITE		= BIOS_BASE + 0x2a
BIOS_LISTST		= BIOS_BASE + 0x2d
BIOS_SECTRAN		= BIOS_BASE + 0x30

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
