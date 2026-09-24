; Console backend video operations.
;
; This is the vocabulary a display backend implements. It is deliberately
; device-oriented: a backend is asked to write a control register, write a data
; byte, upload a block, set a palette entry, present a frame or reset the
; display. Nothing here names a transport.
;
; The byte values are historical. They are the Virtual Drip packet numbers,
; because VIDEO_SEND was written when the only display was across a Virtual Drip
; serial link, and BDOS function 215 is a published interface whose argument is
; that byte -- programs such as HelloWorld's mandelbrot and smiley demos are
; compiled against it. The numbering therefore cannot change without breaking
; them, and it is frozen.
;
; What the numbering must NOT do is oblige a new backend to think in packets.
; A driver for a directly attached video chip implements VIDEO_OP_CTRL_WRITE; it
; does not implement "Virtual Drip packet type 01h". The values are an ABI
; detail of this header, not part of the contract a driver signs.
;
; Backends need not implement every operation. One that cannot perform an
; operation returns BIOS_ERR, which is what a caller already expects: the V9958
; backend rejects anything outside the set below, while the Virtual Drip backend
; is transparent and forwards whatever byte it is given.
;
; Adding an operation: append a value that does not collide with the Virtual
; Drip packet numbering in drivers/transport/vdrip_protocol.inc, because
; VIDEO_SEND's argument space is shared with it for as long as function 215
; takes that byte.

VIDEO_OP_CTRL_WRITE		= 0x01	; write one byte to the control/register port
VIDEO_OP_DATA_WRITE		= 0x02	; write one byte to the data port
VIDEO_OP_RESET			= 0x06	; reinitialize the display and text console
VIDEO_OP_PRESENT		= 0x08	; frame mark: make prior writes visible
VIDEO_OP_DATA_BLOCK		= 0x0b	; upload a block; the only op without the
					; single-frame payload cap
VIDEO_OP_PALETTE_WRITE		= 0x13	; write one palette entry
VIDEO_OP_INDIRECT_WRITE		= 0x14	; indirect register write

; Payload ceiling for every operation except VIDEO_OP_DATA_BLOCK.
;
; Also historical: it is the Virtual Drip single-frame payload size, and it
; applies even when the backend is a chip on the same board with no frames
; anywhere. A backend that could accept more still may not, because the limit is
; enforced in VIDEO_SEND above the contract. Making the ceiling something a
; backend declares is worthwhile and is a behaviour change, so it is not done
; here; see docs/entity-placement-gap-analysis.md section 8.5.
VIDEO_SINGLE_PAYLOAD_MAX	= 0x10
