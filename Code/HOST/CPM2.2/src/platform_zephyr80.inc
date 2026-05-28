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
SIO1A_DATA                  = 0x24
SIO1A_CTRL                  = 0x25
SIO1B_DATA                  = 0x26
SIO1B_CTRL                  = 0x27

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
CTC_RESET_DISABLE           = 0x03
RR0_RX_AVAILABLE            = 0x01
RR0_TX_EMPTY                = 0x04
SIO_WR0_RESET_HIGHEST_IUS   = 0x38
SIO_WR1_RX_INT_ALL          = 0x10
SIO_WR1_TX_INT_ENABLE       = 0x02
SIO_WR9_MIE                 = 0x08

; --- Dependent Aliases & Composites ---
COPY_LATCH0                 = SHADOW_BIT
RAM_ONLY_BANK0              = ROMDIS_BIT
SIO_WR1_RX_TX_INT           = SIO_WR1_RX_INT_ALL | SIO_WR1_TX_INT_ENABLE
