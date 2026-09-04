; ------------------------------------------------------------------------------
; Zephyr-80 Platform Constants (CP/M 2.2 Runtime)
; ------------------------------------------------------------------------------
; Physical port mappings and hardware bit fields. 
; Service behavior resides in the CBIOS modules.
; ------------------------------------------------------------------------------

; --- Physical I/O Ports ---
BANK_PORT                   = 0x00

SIOA_DATA                   = 0x20
SIOA_CTRL                   = 0x21
SIOB_DATA                   = 0x22
SIOB_CTRL                   = 0x23
SIO1A_DATA                  = 0x30
SIO1A_CTRL                  = 0x31
SIO1B_DATA                  = 0x32
SIO1B_CTRL                  = 0x33

; LunchCrema V9958 direct-hardware interface. MODE0/MODE1 are driven by
; CPU A0/A1; A2 selects the card configuration latch.
V9958_DATA_PORT             = 0xa0
V9958_COMMAND_PORT          = 0xa1
V9958_PALETTE_PORT          = 0xa2
V9958_INDIRECT_PORT         = 0xa3
V9958_CONFIG_PORT           = 0xa4

; The configuration latch captures both bits together. D0 selects the VDP
; interrupt route and must be preserved; D1 is physical /WS_EN.
V9958_CONFIG_INT_ROUTE      = 0x01
V9958_CONFIG_PORCH_OFF      = 0x02

CTC0_CTRL                   = 0x40
CTC1_CTRL                   = 0x41
CTC2_CTRL                   = 0x42
CTC3_CTRL                   = 0x43

; --- Memory & Bank Configuration ---
MEM                         = 56
RAM_BANK_MASK               = 0x07
ROM_PAGE_SHIFT              = 5
ROM_VISIBLE_BANK0           = 0x00
ROMDIS_BIT                  = 0x10
SHADOW_BIT                  = 0x08
SHADOW_COPY_BANK_VAR        = 0xfffe

HIGH_COPY_START             = 0xc000
HIGH_COPY_LEN               = 0x4000
PAGE_COPY_START             = 0x0000
PAGE_COPY_LEN               = 0xc000

; --- SIO & CTC Commands / Bitmasks ---
;
; Z80 SIO WR1 receive interrupt mode bits are D4:D3. These bit values are
; intentionally named with the full vector/parity behavior because the console
; IM2 setup depends on a stable vector:
;
;   WR1 D4:D3 = 00 -> RX interrupts disabled
;   WR1 D4:D3 = 01 -> interrupt on first received character / special condition
;   WR1 D4:D3 = 10 -> interrupt on all received characters, parity affects vector
;   WR1 D4:D3 = 11 -> interrupt on all received characters, parity does not
;                     affect vector
;
; The SIO0/B Virtual Drip console path wants all received characters to raise an
; RX interrupt, with parity status not modifying the vector. That keeps WR2 as
; the exact IM2 table selector for the SIO core ISR.
CTC_RESET_DISABLE           = 0x03
RR0_RX_AVAILABLE            = 0x01
RR0_TX_EMPTY                = 0x04
SIO_WR0_RESET_HIGHEST_IUS   = 0x38
SIO_WR1_RX_INT_DISABLED              = 0x00
SIO_WR1_RX_INT_FIRST_CHAR            = 0x08
SIO_WR1_RX_INT_ALL_PARITY_VECTOR     = 0x10
SIO_WR1_RX_INT_ALL_NO_PARITY_VECTOR  = 0x18
SIO_WR1_RX_INT_ALL          = SIO_WR1_RX_INT_ALL_NO_PARITY_VECTOR
SIO_WR1_TX_INT_ENABLE       = 0x02
SIO_WR9_MIE                 = 0x08

; --- Dependent Aliases & Composites ---
COPY_LATCH0                 = SHADOW_BIT
RAM_ONLY_BANK0              = ROMDIS_BIT
SIO_WR1_RX_TX_INT           = SIO_WR1_RX_INT_ALL | SIO_WR1_TX_INT_ENABLE
