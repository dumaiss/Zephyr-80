; Zephyr-80 platform constants for the CP/M CBIOS scaffold.
;
; Banking routines are intentionally not implemented here yet. These constants
; document the hardware interface future CBIOS code will use.

SIOB_DATA	= 0x22
SIOB_CTRL	= 0x23
BANK_PORT	= 0x00

RR0_RX_AVAILABLE	= 0x01
RR0_TX_EMPTY		= 0x04

RAM_BANK_MASK	= 0x07
SHADOW_BIT	= 0x08
ROMDIS_BIT	= 0x10
ROM_PAGE_SHIFT	= 5

COPY_LATCH0		= SHADOW_BIT
RAM_ONLY_BANK0		= ROMDIS_BIT

HIGH_COPY_START		= 0xe000
HIGH_COPY_LEN		= 0x2000
PAGE_COPY_START		= 0x0000
PAGE_COPY_LEN		= 0xe000
SHADOW_COPY_BANK_VAR	= 0xfffe

; COPY_LATCH(N) is computed as (N << ROM_PAGE_SHIFT) | SHADOW_BIT | N.
; The boot copy routine uses this layout directly while copying ROM pages.
