; Serial console fallback for the Zephyr-80 CP/M BIOS.
;
; A second console that lives alongside the selected backend rather than
; replacing it, so that a dark V9958 does not leave the machine unreachable.
; SIO0/B is the port: sio_core_init() already configures it as async 8N1 with
; RX and TX enabled in every build, so nothing here touches SIO setup.
;
; ---------------------------------------------------------------------------
; How it behaves
; ---------------------------------------------------------------------------
;
; OUTPUT is teed.  Every CONOUT goes to the selected backend first and then, if
; the tee is enabled, to the serial port.  The screen never becomes secondary.
;
; INPUT is switched, not merged.  Serial bytes are watched for three ESCs; the
; third toggles input between the USB/HID keyboard and the serial port, and
; arms the tee.  The same gesture hands control back, so taking over does not
; strand the keyboard until a reboot.
;
; Switching rather than merging is deliberate.  A merge would need CONIN to
; poll two blocking sources, and it would let a connected-but-idle terminal --
; or noise on a cable someone just plugged in -- type into a running program.
; Takeover is a gesture the operator makes on purpose.
;
; ---------------------------------------------------------------------------
; Why the tee defaults OFF
; ---------------------------------------------------------------------------
;
; sio_send_byte's console path waits for SIO_CONSOLE_TX_READY, which is
; TX-buffer-empty AND /CTS.  With no terminal attached /CTS never asserts, so
; every character would burn the full SIO_CONSOLE_TIMEOUT of FFFFh loop
; iterations -- on the order of a second each.  The boot banner alone would
; take about a minute.
;
; Two things prevent that.  The tee is off until something arms it, and
; sercon_tx checks /CTS itself before calling the helper: an absent terminal
; costs three instructions per character instead of a timeout.  The CTS test is
; not a guess about the wiring -- sio_core.asm already folds /CTS into its own
; ready mask, so this port's design already treats it as meaningful.
;
; ---------------------------------------------------------------------------
; Input pacing
; ---------------------------------------------------------------------------
;
; IOCBULK masks interrupts for a whole transfer -- roughly 3 ms for a 512-byte
; record -- during which this sink cannot run and the SIO's 3-byte FIFO is the
; only buffer.  At 115200 that is about 35 character times.  Typing survives
; that easily; pasting does not, and the mitigation is to pace the terminal
; rather than to add RTS watermark logic here.  That is why the ring is eight
; bytes and there is no flow control: it covers ISR latency, not a burst.
; ---------------------------------------------------------------------------

	.globl sercon_init,sercon_install,sercon_console_driver
	.globl SERCON_CODE_START,SERCON_CODE_END
	.globl SERCON_BANK7_CODE_START,SERCON_BANK7_CODE_END
	.globl console_backend_driver,console_set_driver
	.globl sio_register_rx_sink,sio_send_byte

	.area CODE (ABS)
	.org CBIOS_SERCON_CODE_BASE

SERCON_CODE_START:

; ---------------------------------------------------------------------------
; Common memory: the registered RX sink only
; ---------------------------------------------------------------------------
; This is the half an interrupt reaches, so its address must be valid whatever
; the latch holds.  Everything else in this driver is polled through the console
; facade's driver table and lives in bank 7 below.

; SIO0/B RX sink, called from the interrupt frame.
;
; In: A = channel id, C = received byte.  May clobber AF/BC/DE/HL but not
; IX/IY, per the sio_core sink contract.  Returns quickly; no BDOS, no blocking,
; no rendering.
sercon_rx_sink:
	ld a,c
	cp #SERCON_ESC
	jr z,sercon_rx_esc

	; Any other byte breaks a partial match.
	xor a
	ld (SERCON_ESC_COUNT),a
	jr sercon_rx_store

sercon_rx_esc:
	ld hl,#SERCON_ESC_COUNT
	inc (hl)
	ld a,(hl)
	cp #SERCON_ESC_TRIGGER
	jr c,sercon_rx_store

	; Third ESC: toggle input ownership and arm the tee.  Arming on takeover
	; means the rescue gesture works from a dark screen in one step.
	ld (hl),#0x00
	ld a,(SERCON_FLAGS)
	xor #SERCON_FLAG_INPUT
	or #SERCON_FLAG_TEE
	ld (SERCON_FLAGS),a

	; Drop the two ESCs already queued: the sequence is a command, not input.
	xor a
	ld (SERCON_RX_HEAD),a
	ld (SERCON_RX_TAIL),a
	ld (SERCON_RX_COUNT),a
	ret

sercon_rx_store:
	; Only keep bytes when serial owns input; otherwise a terminal sitting at
	; a prompt would type into whatever the machine is running.
	ld a,(SERCON_FLAGS)
	and #SERCON_FLAG_INPUT
	ret z

	ld a,(SERCON_RX_COUNT)
	cp #SERCON_RX_BUFFER_SIZE
	ret nc				; full: drop, the terminal is meant to pace
	inc a
	ld (SERCON_RX_COUNT),a

	ld hl,#SERCON_RX_TAIL
	ld e,(hl)
	ld a,e
	inc a
	and #(SERCON_RX_BUFFER_SIZE - 1)
	ld (hl),a
	ld d,#0x00
	ld hl,#sercon_rx_buffer
	add hl,de
	ld (hl),c
	ret

sercon_rx_buffer:
	.ds SERCON_RX_BUFFER_SIZE

SERCON_CODE_END:

	.ifgt (SERCON_CODE_END - SERCON_CODE_START) - (CBIOS_SERCON_CODE_LIMIT - CBIOS_SERCON_CODE_BASE)
	.error 1			; serial console runs into the staging buffer
	.endif
