; Common CBIOS scaffold definitions.
;
; These addresses are provisional. The final CP/M layout will change when CCP,
; BDOS, storage, and monitor handoff are integrated.

BIOS_JUMP_ENTRY_SIZE	= 0x03

BIOS_OK		= 0x00
BIOS_ERR	= 0x01

CONST_NO_CHAR	= 0x00
CONST_HAS_CHAR	= 0xff

CR		= 0x0d
LF		= 0x0a
CTRL_Z		= 0x1a

CBIOS_BASE		= 0xe000
CBIOS_JUMP_TABLE	= CBIOS_BASE
CBIOS_WORK_AREA		= 0xff00
CBIOS_STACK_TOP		= 0xfff0

PAGE_ZERO_WBOOT		= 0x0000
BDOS_ENTRY		= 0x0005
PAGE_ZERO_BDOS		= BDOS_ENTRY
DEFAULT_DMA		= 0x0080
