; VDrip transport: the bank-7 half.
; The common half -- what an interrupt reaches -- is in common/vdrip.asm.
; Split so that every source file belongs to exactly one memory class, which is
; what lets the build check a file's directory against the addresses it emits.


; Assembled as its own translation unit.  Areas are namespaced to it: asxxxx
; concatenates same-named areas across objects, which makes a following .org
; relative rather than absolute (tools/check_org_placement.py).
	.include "config.inc"
	.include "layout/platform.inc"
	.include "layout/memory.inc"
	.include "drivers/transport/vdrip_protocol.inc"

	.globl vdrip_transport_wait_reply
	.globl vdrip_transport_wait_ready
	.globl vdrip_transport_set_raw_callback
	.globl vdrip_transport_set_idle_mode
	.globl vdrip_transport_register_sink
	.globl vdrip_transport_end_storage
	.globl vdrip_transport_begin_storage
	.globl vdrip_send_packet1
	.globl vdrip_send_packet0
	.globl vdrip_send_packet
	.globl vdrip_send_frame
	.globl console_backend_send_frame
	.globl VDRIP_TRANSPORT_BANK7_CODE_START
	.globl VDRIP_TRANSPORT_BANK7_CODE_END
	.globl SIO0B_LAST_RX_ERROR
	.globl irq_restore
	.globl irq_save_disable
	.globl sio_register_rx_sink
	.globl sio_rx_kick
	.globl vdrip_idle_mode
	.globl vdrip_pending_seq
	.globl vdrip_pending_type
	.globl vdrip_proxy_online
	.globl vdrip_raw_callback
	.globl vdrip_reply_error
	.globl vdrip_reply_ready
	.globl vdrip_rx_mode
	.globl vdrip_rx_sink
	.globl vdrip_rx_state
	.globl vdrip_tx_len
	.globl vdrip_tx_payload0
	.globl vdrip_tx_ptr
	.globl vdrip_tx_type
	.globl vdrip_kbd_drain
	.globl vdrip_kbd_head,vdrip_kbd_tail,vdrip_kbd_count,vdrip_kbd_ring
	.globl vdrip_call_raw_callback
	.area VDXPT_CODE (ABS)

; ---------------------------------------------------------------------------
; Bank 7: the foreground transport
; ---------------------------------------------------------------------------
; Registration, idle mode, the READY handshake, storage begin/end, reply wait,
; packet and frame transmission, and putc.  All of it is called from the console
; driver, the storage backend or boot -- never from an interrupt -- so none of
; it needs a common address.

	.area VDXPT_CODE (ABS)
	.org CBIOS_VDRIP_TRANSPORT_BANK7_CODE_BASE

VDRIP_TRANSPORT_BANK7_CODE_START:

; Input: HL = raw console byte callback. Callback input is A = received byte.
vdrip_transport_set_raw_callback:
	ld (vdrip_raw_callback),hl
	ret

; Register the common receive sink with SIO0/B.
vdrip_transport_register_sink:
	call irq_save_disable
	push af
	ld a,#SIO_CH_CONSOLE
	ld hl,#vdrip_rx_sink
	call sio_register_rx_sink
	pop af
	jp irq_restore

; Input: A = idle receive mode (RAW or PACKET).
vdrip_transport_set_idle_mode:
	ld (vdrip_idle_mode),a
	ld (vdrip_rx_mode),a
	ret

;
; Waits for packetized PROXY_READY when not already online -- indefinitely if
; the link is merely quiet, but NOT if it has demonstrably lost data.
;
; The escape below is the difference between a disk error and a dead machine.
; vdrip_transport_wait_reply already bails on SIO0B_LAST_RX_ERROR by clearing
; vdrip_proxy_online and returning BIOS_ERR.  This loop then ran with
; proxy_online clear, waiting for a PROXY_READY the proxy only ever sends on its
; own initiative -- and it is reached from vdrip_console_init, which runs on WARM
; boot as well as cold.  So one lost byte on this link armed a permanent hang at
; the next warm boot: no console, no prompt, reset required.
;
; The lost byte is not hypothetical.  This link is SIO0, shared with the console;
; the IO Controller lives on SIO1 and masks interrupts for the whole of a bulk
; transfer, because the PIC is clock master and never waits mid-stream.  For
; those milliseconds the RX ISR cannot run and software RTS cannot be dropped,
; so SIO0's three-byte FIFO can overrun.  The two SIOs share no wires and couple
; only through the interrupt mask, which is why this needs BOTH drives to
; reproduce and neither one alone.
vdrip_transport_wait_ready:
	ld a,(vdrip_proxy_online)
	or a
	jr nz,vdrip_ready_done
	xor a
	ld (vdrip_rx_state),a
	ld a,#VDRIP_MODE_READY
	ld (vdrip_rx_mode),a
vdrip_ready_wait:
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	ld a,(vdrip_proxy_online)
	or a
	jr nz,vdrip_ready_done

	; Quiet is not the same as broken.  A recorded receive error means the
	; bytes that would have carried PROXY_READY are already gone, so this wait
	; can now only end by never ending; report it and let CP/M raise a disk
	; error.  With no error, keep waiting -- that is the "proxy has not started
	; yet" case this loop exists to serve.
	ld a,(SIO0B_LAST_RX_ERROR)
	or a
	jr z,vdrip_ready_wait
	ld a,#BIOS_ERR
	ret
vdrip_ready_done:
	ld a,(vdrip_idle_mode)
	ld (vdrip_rx_mode),a
	xor a
	ret

; Begin one storage reply wait.
; Input: A = expected reply type, C = pending sequence.
vdrip_transport_begin_storage:
	ld (vdrip_pending_type),a
	ld a,c
	ld (vdrip_pending_seq),a
	xor a
	; RX diagnostics describe the previous receive history. Do not let a
	; stale error abort a new transaction before its reply is pumped.
	ld (SIO0B_LAST_RX_ERROR),a
	ld (vdrip_reply_ready),a
	ld (vdrip_reply_error),a
	ld (vdrip_rx_state),a
	ld a,#VDRIP_MODE_STORAGE
	ld (vdrip_rx_mode),a
	ret

vdrip_transport_end_storage:
	xor a
	ld (vdrip_rx_state),a
	ld a,(vdrip_idle_mode)
	ld (vdrip_rx_mode),a
	ret

; Wait indefinitely for explicit success/failure.
; Output: A = BIOS_OK or BIOS_ERR.
vdrip_transport_wait_reply:
	ld a,(vdrip_reply_error)
	or a
	jr nz,vdrip_wait_error
	ld a,(vdrip_reply_ready)
	or a
	jr nz,vdrip_wait_ok
	ld a,(SIO0B_LAST_RX_ERROR)
	or a
	jr nz,vdrip_wait_transport_error
	ld a,#SIO_CH_CONSOLE
	call sio_rx_kick
	jr vdrip_transport_wait_reply
vdrip_wait_transport_error:
	xor a
	ld (vdrip_proxy_online),a
	inc a
	ld (vdrip_reply_error),a
vdrip_wait_error:
	ld a,#BIOS_ERR
	ret
vdrip_wait_ok:
	xor a
	ret

; Compatibility sender: A=type, B=8-bit payload length, HL=payload.
vdrip_send_packet:
	ld c,b
	ld b,#0x00
	jp vdrip_send_frame

vdrip_send_packet0:
	ld bc,#0x0000
	ld hl,#vdrip_tx_payload0
	jp vdrip_send_frame

; Input: A=type, E=one payload byte.
vdrip_send_packet1:
	push af
	ld a,e
	ld (vdrip_tx_payload0),a
	pop af
	ld bc,#0x0001
	ld hl,#vdrip_tx_payload0
	jp vdrip_send_frame

; Send one current-format frame.
; Input: A=type, BC=payload length (0..1024), HL=payload pointer.
; Output: A=BIOS_OK or transport error. Preserves BC, DE, HL.
console_backend_send_frame:
vdrip_send_frame:
	ld (vdrip_tx_type),a
	ld (vdrip_tx_len),bc
	ld (vdrip_tx_ptr),hl
	push bc
	push de
	push hl

	ld a,b
	cp #0x04
	jr c,vdrip_send_len_ok
	jp nz,vdrip_send_bad_len
	ld a,c
	or a
	jp nz,vdrip_send_bad_len
vdrip_send_len_ok:
	ld a,#PACKET_SYNC0
	call vdrip_transport_putc
	jp nz,vdrip_send_done
	ld a,#PACKET_SYNC1
	call vdrip_transport_putc
	jp nz,vdrip_send_done

	ld hl,(vdrip_tx_len)
	inc hl
	ld a,l
	call vdrip_transport_putc
	jp nz,vdrip_send_done
	ld a,h
	call vdrip_transport_putc
	jp nz,vdrip_send_done
	ld a,(vdrip_tx_type)
	call vdrip_transport_putc
	jp nz,vdrip_send_done

	ld bc,(vdrip_tx_len)
	ld hl,(vdrip_tx_ptr)
	; Defensive re-guard. The payload length is reloaded from RAM-resident
	; transport state, so a corrupted vdrip_tx_len must NEVER be able to walk
	; memory into the SIO (a runaway here would stream RAM to the console).
	; A valid payload is <=1024 bytes (B<=4); reject anything larger and send
	; no payload rather than dump memory.
	ld a,b
	cp #0x05
	jr nc,vdrip_send_ok
vdrip_send_payload:
	ld a,b
	or c
	jr z,vdrip_send_ok
	ld a,(hl)
	call vdrip_transport_putc
	jp nz,vdrip_send_done
	inc hl
	dec bc
	jr vdrip_send_payload
vdrip_send_ok:
	xor a
	jr vdrip_send_done
vdrip_send_bad_len:
	ld a,#BIOS_ERR
vdrip_send_done:
	pop hl
	pop de
	pop bc
	ret

; Virtual Drip uses RTS/CTS hardware flow control.
;
; WR3 Auto Enables is enabled (sio_core_init):
;   - /CTS gates transmission automatically.
;   - /DCD gates reception and is tied active-low (permanently asserted), so
;     the receiver stays enabled.
;
; This routine therefore waits only for room in the SIO transmit buffer.
; The SIO holds queued data until /CTS is asserted by the remote endpoint;
; without that gate, bulk storage transfers overrun the host's serial RX
; buffer and the corrupted frames surface to CP/M as "Bad Sector" errors.
;
; Input: A = byte
; Output: A = BIOS_OK
; Preserves BC.

vdrip_transport_putc:
        push bc
        ld c,a

        xor a
        out (SIOB_CTRL),a       ; select RR0

vdrip_putc_wait_tx:
        in a,(SIOB_CTRL)
        and #RR0_TX_EMPTY
        jr z,vdrip_putc_wait_tx

        ld a,c
        out (SIOB_DATA),a

        pop bc
        xor a
        ret

VDRIP_TRANSPORT_BANK7_CODE_END:

	.ifgt (VDRIP_TRANSPORT_BANK7_CODE_END - VDRIP_TRANSPORT_BANK7_CODE_START) - (CBIOS_VDRIP_TRANSPORT_BANK7_CODE_LIMIT - CBIOS_VDRIP_TRANSPORT_BANK7_CODE_BASE)
	.error 1			; VDrip foreground transport overflows its bank-7 region
	.endif

; Drain the console receive ring, which the interrupt half fills.
;
; Foreground only, and in bank 7 deliberately: it calls the registered callback,
; which is the console driver's textq producer and lives here in bank 7.  Only
; the enqueue side has to be in common, because only that side runs in the
; interrupt frame.
; the registered callback, which is in bank 7, so it must run in mode 11 -- which
; is where the console facade calls it from.
;
; Clobbers AF, BC, DE, HL.  Not ISR-safe by design.
vdrip_kbd_drain:
	ld a,(vdrip_kbd_count)
	or a
	ret z
	ld hl,#vdrip_kbd_tail
	ld e,(hl)
	inc (hl)
	ld a,(hl)
	and #VDRIP_KBD_MASK
	ld (hl),a
	ld d,#0x00
	ld hl,#vdrip_kbd_ring
	add hl,de
	ld c,(hl)
	ld hl,#vdrip_kbd_count
	dec (hl)
	ld a,c
	call vdrip_call_raw_callback
	jr vdrip_kbd_drain
