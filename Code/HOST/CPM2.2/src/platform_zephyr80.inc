; Zephyr-80 platform constants for the local CP/M 2.2 runtime.
;
; This file defines hardware ports and bit fields only. Service behavior lives
; in the CBIOS/runtime modules that include these constants.

SIOB_DATA		= 0x22
SIOB_CTRL		= 0x23

BANK_PORT		= 0x00

CTC0_CTRL		= 0x40
CTC1_CTRL		= 0x41
CTC2_CTRL		= 0x42
CTC3_CTRL		= 0x43

RR0_RX_AVAILABLE	= 0x01
RR0_TX_EMPTY		= 0x04
CTC_RESET_DISABLE	= 0x03

RAM_BANK_MASK		= 0x07
SHADOW_BIT		= 0x08
ROMDIS_BIT		= 0x10
ROM_PAGE_SHIFT		= 5

ROM_VISIBLE_BANK0	= 0x00
COPY_LATCH0		= SHADOW_BIT
RAM_ONLY_BANK0		= ROMDIS_BIT

HIGH_COPY_START		= 0xc000
HIGH_COPY_LEN		= 0x4000
PAGE_COPY_START		= 0x0000
PAGE_COPY_LEN		= 0xc000
SHADOW_COPY_BANK_VAR	= 0xfffe

; COPY_LATCH(N) is computed as (N << ROM_PAGE_SHIFT) | SHADOW_BIT | N.
