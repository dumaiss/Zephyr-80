; Zephyr-80 BIOS IOC common-packet helpers.
;
; These routines provide polled packet I/O for the Command lane (SIO1/B) and
; the Bulk lane (SIO1/A).  Both use the same wire envelope and persistent
; External Sync; only admission timing and maximum DATA length differ.
;
; Command channel = SIO1/B
;   DATA port = SIO_COMMAND_DATA_PORT = 32h
;   CTRL port = SIO_COMMAND_CTRL_PORT = 33h
;
; SIO1/A channel-A outputs failed hardware probing; the PIC bit-bang bring-up
; uses channel B.
;
; Hardware model:
;   The MCU is the synchronous clock master.  TXC/RXC for SIO1/B are supplied
;   by the MCU.  The MCU clocks only during active transactions.  Clocking alone
;   does not trigger a useful Z80 SIO interrupt; the MCU must deliver a complete
;   External Sync byte window.  No WAIT/READY; no INIR/OTIR; polled byte I/O only.
;   No SIO1/B interrupts in Phase 1.
;
; Wire framing, both lanes and directions:
;   A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
; The MCU drives /SYNC and the clocks.  IOCALL maps this to the existing
; 32-byte command mailbox; IOCBULK/IOCBULKW expose DATA only to their callers.
;
; Placement:
;   command helpers at F000h; overflow bulk-write helpers at ED00h.

	.globl sio_command_rts_assert,sio_command_rts_release
	.globl sio_command_put_byte,sio_command_get_byte
	.globl sio_command_wait_ready
	.globl ioc_command_send_frame,ioc_command_recv_frame
	.globl ioc_link_init_once,ioc_rx_synced,ioc_link_ready
	.globl ioc_bulk_synced
	.globl ioc_link_bringup
	.globl IOC_DIAG_STATUS,IOC_DIAG_LANE,IOC_DIAG_RR0,IOC_DIAG_RR1
	.globl IOC_DIAG_SYNCED,IOC_DIAG_READY,IOC_DIAG_BULK_SYNCED,IOC_DIAG_SEQ
	.globl IOC_DIAG_BULK_REASON,IOC_DIAG_BULK_TYPE,IOC_DIAG_BULK_SEQ
	.globl IOC_DIAG_BULK_STATUS
	.globl IOCALL,MOVE_BUFFER
	.globl IOCBULK,IOCBULKW
	.globl ioc_crc_block,ioc_frame_stamp,ioc_packet_crc_mailbox
	.globl ioc_bulk_tx_type,ioc_bulk_tx_seq,ioc_bulk_rx_type,ioc_bulk_rx_seq
	.globl IOC_CMD_CODE_START,IOC_CMD_CODE_END
	.globl IOC_BULK_CODE_START,IOC_BULK_CODE_END

	.area CODE (ABS)
	.org CBIOS_IOC_COMMAND_CODE_BASE

IOC_CMD_CODE_START:

; ---------------------------------------------------------------------------
; sio_command_rts_assert
; Assert RTS on SIO1/B (Command channel) to signal the MCU to start clocking.
; Writes WR5 = 0x6A (TX enabled + RTS on) -> /RTSB goes LOW.  The MCU detects
; this high->low edge on the channel-B RTS input.  sio_command_init / a prior
; rts_release leave TX disabled and /RTSB HIGH, so this write produces a clean
; falling edge.
; In:  nothing
; Out: A = 0
; Clobbers: AF
; ---------------------------------------------------------------------------
sio_command_rts_assert:
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_ON
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_rts_release
; Release RTS on SIO1/B (Command channel) after the transaction completes.
;
; Writes WR5 = 0x00 (TX DISABLED + RTS off), NOT 0x68.  In External Sync mode an
; enabled transmitter never empties (it streams sync/fill idle), so the SIO's
; delayed /RTS-deassert never fires and clearing the RTS bit alone leaves /RTSB
; latched LOW.  Disabling TX satisfies the transmit-empty condition so /RTSB
; returns HIGH — restoring the idle state and letting the next transaction's
; rts_assert generate a fresh falling edge for the MCU.
; In:  nothing
; Out: A = 0
; Clobbers: AF
; ---------------------------------------------------------------------------
sio_command_rts_release:
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_IDLE
	out (SIO_COMMAND_CTRL_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_wait_ready
; Wait for the MCU to advertise COMMAND_READY on /DCDB (RR0 bit 3).
;
; The MCU holds this asserted only while it is in command-idle.  It drops it on
; accepting a request and does not raise it again until everything that request
; triggered has finished -- including the bulk phase and any SD card write.  So
; this is the backpressure that keeps the host from issuing a command the MCU
; cannot yet see.
;
; Each poll first issues WR0 = Reset External/Status Interrupts.  The SIO latches
; RR0's modem-status bits on change, so without that a stale latch could report
; a level the pin no longer carries and this would either spin or, worse, let a
; request through early.
;
; In:  nothing
; Out: A = IOC_XPORT_OK, or IOC_XPORT_NOT_READY on timeout
; Clobbers: AF, DE
; ---------------------------------------------------------------------------
sio_command_wait_ready:
	push bc
	ld b,#SIO_COMMAND_READY_OUTER
SIO_CMD_RDY_OUTER:
	ld de,#SIO_COMMAND_READY_TIMEOUT
SIO_CMD_RDY_WAIT:
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_COMMAND_CTRL_PORT),a
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_RR0_DCD
	jr nz,SIO_CMD_RDY_OK
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_RDY_WAIT
	djnz SIO_CMD_RDY_OUTER
	pop bc
	ld a,#IOC_XPORT_NOT_READY
	ret
SIO_CMD_RDY_OK:
	pop bc
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_put_byte
; Send one byte on SIO1/B (Command channel) with polling.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 2 (TX buffer empty) before writing.
; In:  C = byte to send
; Out: A = IOC_XPORT_OK (0) on success, IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, DE
; ISR-safe: No.  Blocking poll.
;
; DEBUG BRING-UP: the wait is a very long 24-bit countdown (inner DE =
; SIO_COMMAND_TIMEOUT, repeated SIO_COMMAND_TIMEOUT_OUTER times in B) so the PIC
; side can be single-stepped without the Z80 bailing out, yet it still returns
; IOC_XPORT_TIMEOUT instead of hanging forever.  B is saved/restored so the
; caller's frame counter survives.  For production, set OUTER = 1 (or restore the
; original single-DE wait).
; ---------------------------------------------------------------------------
sio_command_put_byte:
	push bc				; preserve caller B (frame counter) and C (data byte)
	ld b,#SIO_COMMAND_TIMEOUT_OUTER
SIO_CMD_PUT_OUTER:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_PUT_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_TX_READY
	jr nz,SIO_CMD_PUT_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_PUT_WAIT
	djnz SIO_CMD_PUT_OUTER
	pop bc				; restore caller B/C
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_PUT_READY:
	pop bc				; restore caller B; recover data byte in C
	ld a,c
	out (SIO_COMMAND_DATA_PORT),a
	xor a
	ret

; ---------------------------------------------------------------------------
; sio_command_get_byte
; Receive one byte from SIO1/B (Command channel) with polling.
; The MCU clocks only during an active transaction (after RTS assertion).
; Polling checks RR0 bit 0 (RX character available) before reading.
; In:  nothing
; Out: A = IOC_XPORT_OK (0), C = received byte
;   or A = IOC_XPORT_TIMEOUT on timeout
; Clobbers: AF, C, DE
; ISR-safe: No.  Blocking poll.
;
; DEBUG BRING-UP: same very long 24-bit countdown as sio_command_put_byte
; (inner DE = SIO_COMMAND_TIMEOUT, outer B = SIO_COMMAND_TIMEOUT_OUTER) so the
; PIC side can be single-stepped, then returns IOC_XPORT_TIMEOUT rather than
; hanging.  B is saved/restored.  For production, set OUTER = 1.
; TODO: During bring-up, inspect RR1 overrun/parity/status if byte receive
;       errors appear.  No SIO hardware CRC/FCS is used in External Sync mode.
; ---------------------------------------------------------------------------
sio_command_get_byte:
	push bc				; preserve caller B (frame counter)
	ld b,#SIO_COMMAND_TIMEOUT_OUTER
SIO_CMD_GET_OUTER:
	ld de,#SIO_COMMAND_TIMEOUT
SIO_CMD_GET_WAIT:
	in a,(SIO_COMMAND_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,SIO_CMD_GET_READY
	dec de
	ld a,d
	or e
	jr nz,SIO_CMD_GET_WAIT
	djnz SIO_CMD_GET_OUTER
	pop bc				; restore caller B/C
	ld a,#IOC_XPORT_TIMEOUT
	ret
SIO_CMD_GET_READY:
	in a,(SIO_COMMAND_DATA_PORT)	; read byte into A before restoring BC
	pop bc				; restore caller B; C recovered then overwritten
	ld c,a				; return received byte in C
	xor a
	ret

; ---------------------------------------------------------------------------
; ioc_crc_block
; CRC-16-CCITT over an arbitrary run.  ioc_crc_continue is the seeded entry
; used to cover the packet header and DATA as one logical run.
;
; The counter is 16-bit because the bulk lane needs it, which costs ~13 T-states
; per byte over the djnz form (dec bc sets no flags).  For a 512-byte sector
; that is ~0.7 ms -- worth paying to avoid a second copy of the table and the
; nibble helper, which together are larger than the whole saving.
;
; In:  HL = buffer, BC = byte count (must be non-zero)
; Out: DE = CRC
; Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
ioc_crc_block:
	ld de,#0			; crc = 0
ioc_crc_continue:
	ld a,b
	or c
	ret z
IOC_CRC_BYTE:
	ld a,(hl)
	push bc
	; high nibble: index = ((crc >> 12) ^ (data >> 4)) & 0x0F
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	ld c,a
	ld a,d
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	xor c
	call IOC_CRC_NIBBLE
	; low nibble
	ld a,(hl)
	and #0x0f
	ld c,a
	ld a,d
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	xor c
	call IOC_CRC_NIBBLE
	pop bc
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,IOC_CRC_BYTE
	ret

; crc = (crc << 4) ^ table[A].  A = 4-bit index.
; Clobbers: AF, BC
IOC_CRC_NIBBLE:
	add a,a				; table entries are 16-bit
	ld c,a
	ld b,#0
	push hl
	ld hl,#ioc_crc_table
	add hl,bc
	ld c,(hl)
	inc hl
	ld b,(hl)			; BC = table entry
	pop hl
	; crc <<= 4
	ex de,hl
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,hl
	ex de,hl
	; crc ^= BC
	ld a,d
	xor b
	ld d,a
	ld a,e
	xor c
	ld e,a
	ret

ioc_crc_table:
	.dw 0x0000, 0x1021, 0x2042, 0x3063
	.dw 0x4084, 0x50a5, 0x60c6, 0x70e7
	.dw 0x8108, 0x9129, 0xa14a, 0xb16b
	.dw 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef

; Stamp only the rolling sequence into the compatibility mailbox.  CRC belongs
; to the packet on the wire and is prepared by ioc_packet_crc_mailbox.
ioc_frame_stamp:
	; Next sequence.  Rolls modulo 256; 0 is not special.
	ld a,(ioc_seq)
	inc a
	ld (ioc_seq),a

	push hl
	inc hl				; IOC_OFF_SEQ = 1
	ld (hl),a
	pop hl

	ld a,(ioc_seq)
	ret

; ---------------------------------------------------------------------------
; Map a compatibility mailbox to the common packet header and calculate the
; exact wire CRC: LEN_LO LEN_HI TYPE SEQ STATUS DATA.
;
; In:  HL = mailbox.  Out: A = IOC_XPORT_OK or IOC_XPORT_BAD_FRAME.
; Preserves HL.  Stores header, DATA pointer/length and CRC in packet scratch.
; ---------------------------------------------------------------------------
ioc_packet_crc_mailbox:
	ld (ioc_packet_frame_ptr),hl
	ld bc,#IOC_OFF_LEN
	add hl,bc
	ld a,(hl)
	cp #(IOC_COMMAND_MAX_DATA + 1)
	jr nc,IOC_PACKET_MAILBOX_BAD
	ld (ioc_packet_data_len),a
	add a,#IOC_PACKET_FIXED_LEN
	ld (ioc_packet_header),a	; LEN low
	xor a
	ld (ioc_packet_header + 1),a	; LEN high

	ld hl,(ioc_packet_frame_ptr)
	ld a,(hl)
	ld (ioc_packet_header + 2),a	; TYPE
	inc hl
	ld a,(hl)
	ld (ioc_packet_header + 3),a	; SEQ
	inc hl
	ld a,(hl)
	ld (ioc_packet_header + 4),a	; STATUS
	inc hl				; mailbox LEN
	inc hl				; DATA
	ld (ioc_packet_data_ptr),hl

	ld hl,#ioc_packet_header
	ld bc,#5
	call ioc_crc_block
	ld a,(ioc_packet_data_len)
	or a
	jr z,IOC_PACKET_MAILBOX_CRC_DONE
	ld c,a
	ld b,#0
	ld hl,(ioc_packet_data_ptr)
	call ioc_crc_continue
IOC_PACKET_MAILBOX_CRC_DONE:
	ld (ioc_packet_crc),de
	ld hl,(ioc_packet_frame_ptr)
	xor a
	ret
IOC_PACKET_MAILBOX_BAD:
	ld hl,(ioc_packet_frame_ptr)
	ld a,#IOC_XPORT_BAD_FRAME
	ret

; Rolling transaction sequence.  Lives in the code region, which is RAM at
; runtime after the shadow copy.
ioc_seq:
	.db 0

; Common packet scratch.  The command and bulk paths are mutually exclusive.
ioc_packet_header:	.ds 5	; LEN_LO LEN_HI TYPE SEQ STATUS
ioc_packet_frame_ptr:	.dw 0
ioc_packet_data_ptr:	.dw 0
ioc_packet_data_len:	.db 0
ioc_packet_crc:		.dw 0
ioc_packet_wire_crc:	.dw 0

; Metadata joining a READY command exchange to its following bulk data phase.
; IOCALL records both directions; IOCBULK/IOCBULKW require the common packet to
; agree, preventing a delayed data phase from being accepted by a newer command.
ioc_bulk_tx_type:	.db 0
ioc_bulk_tx_seq:		.db 0
ioc_bulk_rx_type:	.db 0
ioc_bulk_rx_seq:		.db 0

; ---------------------------------------------------------------------------
; ioc_command_send_frame
; Map one BIOS-facing compatibility mailbox to the common wire packet:
;   A5 5A LEN_LO LEN_HI TYPE SEQ STATUS DATA... CRC_HI CRC_LO
;
; Z80 SIO synchronous-transmit requirement: after the first data byte is loaded
; the Tx Underrun/EOM latch must be reset (WR0 = 0xC0) so the transmitter leaves
; its idle/mark state and shifts the buffered data.  Without this the first byte
; is never consumed, TBE never re-asserts, and the send times out.
; In:  HL = pointer to 32-byte compatibility mailbox in caller RAM
; Out: A = IOC_XPORT_OK, IOC_XPORT_BAD_FRAME or IOC_XPORT_TIMEOUT
; Clobbers: AF, B, C, DE, HL
; ---------------------------------------------------------------------------
ioc_command_send_frame:
	; Build the exact wire header and CRC before entering the timing-critical
	; section.  This also rejects a mailbox length above the command limit.
	call ioc_packet_crc_mailbox
	or a
	ret nz

	; Interrupts OFF for the frame transfer.
	;
	; The MCU is clock master and does not wait, so a stall inside this loop
	; is lost data rather than latency.  The masked interval is bounded and
	; short: 35 bytes at the command pacing, ~1.1 ms.
	;
	; Deliberately NOT around the whole IOCALL.  The MCU performs card I/O
	; inside a transaction, so masking across the reply would blackout for up
	; to a second.  Masking the transfers and leaving the WAIT interruptible
	; is the contract; see the response scan below.
	;
	; Assumes the caller had interrupts enabled, which every current caller
	; does.  Preserving the entry state properly needs ld a,i with the Z80
	; erratum retry, and is required before this ships.
	di

	; PRELOAD, THEN GRANT.  The preamble goes into the transmitter and the
	; underrun latch is cleared BEFORE RTS is asserted, so the very first clock
	; edge the MCU generates shifts out the preamble itself.
	;
	; The old order asserted RTS first and loaded the byte afterwards.  The MCU
	; starts clocking the moment it sees RTS, so the SIO had nothing to send
	; and emitted WR7 underrun fill until the byte arrived -- a variable number
	; of bytes, which is what made the frame start at an unpredictable offset
	; and forced the MCU into a 48-byte capture window and a 128-offset search.
	;
	; Nothing shifts without clocks and the MCU is clock master, so preloading
	; before RTS is safe by construction: the byte simply waits in the
	; transmitter until the first edge arrives.  This is section 14 of the
	; transport design, "the Z80 prepares and preloads the transmitter before
	; asserting /RTSB".
	; Enable the transmitter, RTS still off.
	;
	; sio_command_rts_release ends every transaction with WR5 = 00h, which
	; DISABLES the transmitter.  That used to be undone by sio_command_init at
	; the head of each IOCALL; now that init runs once, nothing restores it, and
	; the preload below would poll forever for a Transmit Buffer Empty that a
	; disabled transmitter never reports.  The first transaction after boot
	; worked and every one after it timed out in the send phase.
	;
	; WR5 rather than a channel reset: this re-arms the transmitter without
	; touching the receiver, so character synchronisation survives.
	ld a,#0x05
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR5_CMD_TX_RTS_OFF
	out (SIO_COMMAND_CTRL_PORT),a

	ld c,#IOC_PACKET_SYNC0
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
IOC_CMD_SEND_EOM:
	ld a,#0xc0			; WR0: Reset Tx Underrun/EOM latch
	out (SIO_COMMAND_CTRL_PORT),a

	; Only now hand the MCU its credit to start clocking.
	call sio_command_rts_assert

	; Marker byte two, then the five-byte common header.
	ld c,#IOC_PACKET_SYNC1
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
	ld hl,#ioc_packet_header
	ld b,#5
IOC_CMD_SEND_HEADER:
	ld c,(hl)
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
	inc hl
	djnz IOC_CMD_SEND_HEADER

	; Variable DATA body from mailbox bytes 4 onward.
	ld a,(ioc_packet_data_len)
	or a
	jr z,IOC_CMD_SEND_CRC
	ld b,a
	ld hl,(ioc_packet_data_ptr)
IOC_CMD_SEND_DATA:
	ld c,(hl)
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
	inc hl
	djnz IOC_CMD_SEND_DATA

IOC_CMD_SEND_CRC:
	ld a,(ioc_packet_crc + 1)	; CRC high first
	ld c,a
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
	ld a,(ioc_packet_crc)
	ld c,a
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR

	; Trailing filler, and it is NOT optional.
	;
	; sio_command_put_byte polls for transmit-buffer-empty and then writes,
	; so when the loop above finishes the last frame byte is still sitting in
	; the buffer or the shift register -- not on the wire.  The caller drops
	; RTS immediately after this returns, and sio_command_rts_release
	; DISABLES the transmitter to make /RTSB actually rise (in External Sync
	; mode an enabled transmitter never satisfies transmit-empty, so clearing
	; the RTS bit alone leaves the line latched low).  Disabling TX with a
	; byte still in flight truncates it, the MCU captures a short frame, and
	; find_frame_start rejects it.
	;
	; Each put_byte waits for the previous byte to leave the buffer, so after
	; two fillers byte 31 is guaranteed clear of the shift register.  The
	; MCU's capture window is 48 bytes against a 33-byte frame, so the filler
	; lands in slack it already tolerates, and truncating filler costs
	; nothing.
	ld b,#IOC_SEND_TRAILER_BYTES
IOC_CMD_SEND_TRAILER:
	ld c,#IOC_SEND_TRAILER_FILL
	call sio_command_put_byte
	or a
	jp nz,IOC_CMD_SEND_ERROR
IOC_CMD_SEND_TRAIL_NEXT:
	djnz IOC_CMD_SEND_TRAILER

	; Deliberately returns with interrupts STILL MASKED on success.
	;
	; The MCU begins its reply only EXTSYNC_REPLY_GUARD_US (200 us) after the
	; request window, and the host must have its receiver armed and hunting by
	; then.  Re-enabling here let a pending interrupt -- one is always pending,
	; the send masks for ~1.1 ms -- run before the arm, and with console
	; interrupts stacking on top the receiver could be armed part-way through
	; the reply.  It then synced on a later edge, saw no A5/5A marker, and timed out:
	; RR0 showed hunt CLEAR with no byte available.
	;
	; ioc_command_recv_frame arms the receiver and re-enables interrupts before
	; its scan.  Error exits above re-enable normally; only this path stays
	; masked, and only until the arm.
	xor a
	ret

IOC_CMD_SEND_ERROR:
	ei
	ret

; ---------------------------------------------------------------------------
; ioc_command_recv_frame
; Locate, receive and validate one common packet from SIO1/B, then map it into
; the caller's 32-byte compatibility mailbox.
; In:  DE = pointer to 32-byte RX frame buffer in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
;      compatibility mailbox written to buffer at DE on success.
; Clobbers: AF, B, C, DE, HL
;
; DE IS CLOBBERED -- this said "AF, B, C, HL" for a long time and it was wrong.
; sio_command_get_byte uses DE as its 16-bit timeout counter, and this routine
; calls it once per byte, so the caller's RX pointer does not survive.  Trusting
; the old comment cost a debugging session: IOCALL recovered the pointer from DE
; after the call and CRC-checked whatever it happened to address.
; ---------------------------------------------------------------------------
; Entered with interrupts MASKED by a successful ioc_command_send_frame, so the
; receiver can be armed before the MCU's 200 us reply guard expires.  Interrupts
; are re-enabled once the arm is done and before the scan, which is the WAIT and
; may span the MCU's card I/O.
ioc_command_recv_frame:
	ld (ioc_packet_frame_ptr),de
	; The receiver stays enabled from one transaction to the next, so it fills
	; with the MCU's full-duplex idle bytes while we transmit and overruns.
	; That is harmless: the SIO manual lists exactly three things that end
	; character assembly -- chip reset, receiver disabled, and Enter Hunt Phase
	; -- and overrun is not among them.  Alignment survives; only the data is
	; lost, and the data was idle.  Clearing the error latch is all that is
	; required.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_COMMAND_CTRL_PORT),a

	; Enter Hunt ONLY until the boundary has been established once.
	;
	; WR3 = D1h sets bit 4, Enter Hunt Phase, which throws character sync away.
	; Doing that every transaction is what forced the MCU to re-establish the
	; boundary on every reply, and that in turn is what made the hand-clocked
	; sync byte necessary.  Once the MCU has supplied the falling /SYNC edge,
	; C1h keeps the receiver enabled and leaves the boundary alone.
	ld a,#0x03
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,(ioc_rx_synced)
	or a
	ld a,#SIO_WR3_CMD_RX_NO_HUNT
	jr nz,IOC_CMD_RECV_WR3
	ld a,#SIO_WR3_CMD_RX		; D1h: hunt, first time only
IOC_CMD_RECV_WR3:
	out (SIO_COMMAND_CTRL_PORT),a

	; FLUSH the receive FIFO before listening for the reply.
	;
	; The receiver now stays enabled between transactions -- disabling it is one
	; of the three things that destroy character synchronisation -- so it spends
	; our whole request transmit assembling the MCU's full-duplex idle bytes and
	; fills its three-byte FIFO.  Error Reset above clears the error LATCH but
	; leaves those bytes in place, so the scan below would start on stale data
	; and the reply's marker would be lost to the overrun that follows.  That is
	; exactly what RR1 bit 5 reported.
	;
	; Safe to do here: the MCU waits EXTSYNC_REPLY_GUARD_US before it clocks the
	; reply, which is an order of magnitude longer than this loop.
	; BOUNDED to the FIFO depth.  The first version looped until the FIFO read
	; empty, which is wrong in both directions: while the MCU is still clocking
	; its receive window the FIFO empties between every byte, so it exited
	; early; and if the reply had begun it would have kept reading and eaten the
	; marker -- a timeout with a perfectly clean RR1, which is what was seen.
	;
	; Only the bytes already sitting there need removing, and there can never be
	; more than three.  Anything that arrives afterwards is harmless: the scan
	; below skips non-marker bytes, and it consumes at ~15 us against the MCU's
	; 16 us pacing, so it keeps ahead and cannot overrun.
	ld b,#(IOC_RX_FIFO_DEPTH + 1)
IOC_CMD_RECV_DRAIN:
	xor a
	out (SIO_COMMAND_CTRL_PORT),a
	in a,(SIO_COMMAND_CTRL_PORT)
	and #RR0_RX_AVAILABLE
	jr z,IOC_CMD_RECV_DRAINED
	in a,(SIO_COMMAND_DATA_PORT)
	djnz IOC_CMD_RECV_DRAIN
IOC_CMD_RECV_DRAINED:

	; Clear the latch again: draining a FIFO that had overrun leaves the error
	; bit set, and a stale latch would confuse the next failure's diagnostics.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_COMMAND_CTRL_PORT),a

	; Receiver is armed and hunting; the reply can no longer be missed.
	; Everything from here to the preamble match is the WAIT, so unmask.
	ei

	push de
	pop hl				; HL = RX buffer pointer

	; Search the bounded reply window for the full A5 5A marker.  The previous
	; transaction's trailing FF can become FIFO-visible only when this reply's
	; first clocks arrive, so marker search -- not byte zero -- defines framing.
	ld b,#SIO_COMMAND_REPLY_SCAN_LIMIT
IOC_CMD_RECV_SYNC0:
	call sio_command_get_byte	; clobbers AF,C; preserves B,DE,HL
	or a
	jp nz,IOC_CMD_RECV_SYNC_TIMEOUT
	ld a,c
	cp #IOC_PACKET_SYNC0
	jr z,IOC_CMD_RECV_SYNC1
	djnz IOC_CMD_RECV_SYNC0
	jr IOC_CMD_RECV_BAD_FRAME_READY

IOC_CMD_RECV_SYNC1:
	call sio_command_get_byte
	or a
	jp nz,IOC_CMD_RECV_SYNC_TIMEOUT
	ld a,c
	cp #IOC_PACKET_SYNC1
	jr z,IOC_CMD_RECV_PACKET
	cp #IOC_PACKET_SYNC0		; overlapping A5 A5 5A
	jr z,IOC_CMD_RECV_SYNC1
	djnz IOC_CMD_RECV_SYNC0
IOC_CMD_RECV_BAD_FRAME_READY:
	; Same status and same record as a masked header rejection.  What separates
	; "the preamble never arrived" from "the header arrived and was bad" is RR0
	; bit 4 in the record: the receiver is still hunting only in the first case.
	; That is why this no longer needs a scan-budget field to be diagnosable.
	jp IOC_CMD_RECV_BAD_FRAME_MASKED

; The marker scan above runs with interrupts ENABLED: it is the WAIT for the
; MCU's reply, and that wait spans any card I/O the command triggered -- up to a
; second.  Masking it would be the multi-millisecond blackout the design
; explicitly rules out.
;
; From here the bytes are streaming and the MCU will not pause, so the body is
; masked.  The longest command packet body is 33 bytes, about 1 ms.
IOC_CMD_RECV_PACKET:
	di
	ld hl,#ioc_packet_header
	ld b,#5				; LEN_LO LEN_HI TYPE SEQ STATUS
IOC_CMD_RECV_HEADER:
	call sio_command_get_byte
	or a
	jp nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld (hl),c
	inc hl
	djnz IOC_CMD_RECV_HEADER

	; Command mailboxes can carry at most 26 DATA bytes.  The high length byte
	; must be zero, and LEN includes the three metadata bytes.
	ld a,(ioc_packet_header + 1)
	or a
	jr nz,IOC_CMD_RECV_BAD_FRAME_MASKED
	ld a,(ioc_packet_header)
	cp #IOC_PACKET_FIXED_LEN
	jr c,IOC_CMD_RECV_BAD_FRAME_MASKED
	cp #(IOC_PACKET_FIXED_LEN + IOC_COMMAND_MAX_DATA + 1)
	jr nc,IOC_CMD_RECV_BAD_FRAME_MASKED
	sub #IOC_PACKET_FIXED_LEN
	ld (ioc_packet_data_len),a

	; Map fixed metadata into the compatibility mailbox.
	ld hl,(ioc_packet_frame_ptr)
	ld a,(ioc_packet_header + 2)
	ld (hl),a
	inc hl
	ld a,(ioc_packet_header + 3)
	ld (hl),a
	inc hl
	ld a,(ioc_packet_header + 4)
	ld (hl),a
	inc hl
	ld a,(ioc_packet_data_len)
	ld (hl),a
	inc hl

	; Receive only the declared DATA bytes.
	or a
	jr z,IOC_CMD_RECV_CRC
	ld b,a
IOC_CMD_RECV_DATA:
	call sio_command_get_byte
	or a
	jr nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld (hl),c
	inc hl
	djnz IOC_CMD_RECV_DATA

IOC_CMD_RECV_CRC:
	call sio_command_get_byte
	or a
	jr nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld a,c
	ld (ioc_packet_wire_crc + 1),a	; high
	call sio_command_get_byte
	or a
	jr nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld a,c
	ld (ioc_packet_wire_crc),a	; low

	; Preserve the old fixed-mailbox contract by clearing bytes the variable
	; packet did not carry, including the former CRC slots 30 and 31.
	ld a,(ioc_packet_data_len)
	ld c,a
	ld a,#(IOC_FRAME_SIZE - IOC_OFF_PAYLOAD)
	sub c
	jr z,IOC_CMD_RECV_VERIFY
	ld b,a
	xor a
IOC_CMD_RECV_CLEAR_TAIL:
	ld (hl),a
	inc hl
	djnz IOC_CMD_RECV_CLEAR_TAIL

IOC_CMD_RECV_VERIFY:
	ld hl,(ioc_packet_frame_ptr)
	call ioc_packet_crc_mailbox
	or a
	jr nz,IOC_CMD_RECV_BAD_FRAME_MASKED
	ld de,(ioc_packet_crc)
	ld hl,(ioc_packet_wire_crc)
	ld a,l
	cp e
	jr nz,IOC_CMD_RECV_BAD_CRC
	ld a,h
	cp d
	jr nz,IOC_CMD_RECV_BAD_CRC

	; CRC verification is the proof that the persistent character boundary is
	; established.  Never issue Enter Hunt again until explicit link recovery.
	ld a,#1
	ld (ioc_rx_synced),a
	ei
	xor a
	ret

; Every command-lane failure exit funnels through one tail so the record is
; written on all of them, not just on marker timeout.  A STATUS field that is
; only filled in on one of four paths is worse than none: it reads as current
; whichever failure actually happened.
;
; The exits carry only their status code and fall into the shared tail, which
; costs exactly what the four separate ei/ld/ret exits cost before.  Slot 4 ends
; at F41Ah and sd_storage_probe starts at F41Bh, so this section cannot grow by
; even one byte.
;
; ei is in the shared tail rather than at each exit.  The marker-scan path
; reaches here with interrupts already enabled -- it is the WAIT -- and a
; redundant ei is a no-op, so one instruction serves both entry conditions.
IOC_CMD_RECV_BAD_CRC:
	ld a,#IOC_XPORT_BAD_CRC
	jr IOC_CMD_RECV_FAIL

IOC_CMD_RECV_BAD_FRAME_MASKED:
	ld a,#IOC_XPORT_BAD_FRAME
	jr IOC_CMD_RECV_FAIL

IOC_CMD_RECV_SYNC_TIMEOUT:
	ld a,#IOC_XPORT_TIMEOUT_REPLY_MARKER
	jr IOC_CMD_RECV_FAIL

IOC_CMD_RECV_BODY_TIMEOUT:
	ld a,#IOC_XPORT_TIMEOUT_REPLY_BODY

; ioc_diag_capture returns with A still holding the status, so the tail is a
; jump rather than a call and return.  Capture lives with the Bulk transport in
; slot 3, which is where deleting the old traces made room for it.
IOC_CMD_RECV_FAIL:
	ei
	jp ioc_diag_capture

; ---------------------------------------------------------------------------
; IOCBULK
; Receive a bulk payload on SIO1/A (Bulk channel).
;
; The command lane stays authoritative: the caller issues a command through
; IOCALL, the MCU replies READY with a transfer id and length, and only then
; does the caller invoke IOCBULK to move the bytes.  This routine is the dumb
; byte pipe half of that — it knows nothing about transfer ids or what the
; payload means, and the caller must still collect DONE on the command lane to
; learn whether the transfer was good.
;
; The handshake is owned ENTIRELY here.  The caller must not touch SIO1/A
; registers before or after: this routine arms the receiver, asserts RTS,
; drains the stream, releases RTS and confirms the MCU dropped /CTSA.  The MCU
; waits for RTS before clocking a single edge, so arming inside this call is
; race-free and needs no guard delay on either side.
;
; No IOCALL may be issued while this is running — both lanes share the MCU's
; single SPI2 engine.
;
; In:  HL = destination buffer
;      DE = byte count, 1..IOC_BULK_MAX_LEN
; Out: A = IOC_XPORT_OK        all bytes received, /CTSA seen deasserted
;        = IOC_XPORT_BAD_FRAME length was zero or above IOC_BULK_MAX_LEN
;        = IOC_XPORT_TIMEOUT   stream stalled; RTS released
;        = IOC_XPORT_HW_ERROR  bytes arrived but /CTSA never deasserted
; Clobbers: AF, BC, DE, HL
; ISR-safe: No.  Blocking poll.
;
; Receive loop cost is 56 T-states per byte (5.6 us at 10 MHz), against 151 T
; for the command lane's sio_command_get_byte.  The difference is all structural:
; INI performs the port read, the store, HL++ and B-- in one 16 T instruction,
; and there is no per-byte call/ret or timeout reload.  The MCU paces the bulk
; lane at 6 us/byte on the strength of this number — do not reintroduce
; per-byte call overhead here without repacing the MCU side.
;
; INI forces the register budget: B is the counter, C the port, HL the
; destination.  That leaves DE for the stall budget, which is therefore a
; whole-transfer budget rather than a per-byte one — cheaper, and better
; behaved.  B counts one 256-byte block at a time (B = 0 means 256), so a
; transfer is an optional remainder followed by whole blocks; the count of
; remaining blocks lives on the stack because no register is free to hold it.
; ---------------------------------------------------------------------------
	; Length check against IOC_BULK_MAX_LEN, compared as a full 16-bit value.
	;
	; An earlier version rejected anything with a non-zero low byte once the
	; high byte matched, which was only correct while the limit was exactly
	; 512.  Raising it to 514 for the CRC trailer made that logic reject every
	; single 514-byte transfer -- the low byte of the limit is no longer zero.
IOCBULK:
	ld (ioc_bulk_ptr),hl		; kept for the CRC pass after the transfer
	ld (ioc_bulk_len),de
	ld a,d
	cp #(IOC_BULK_MAX_LEN >> 8)
	jr c,IOCBULK_LEN_OK		; high byte below the limit's: in range
	jp nz,IOCBULK_BAD_LEN		; high byte above the limit's: too long
	ld a,#(IOC_BULK_MAX_LEN & 0xff)
	cp e
	jp c,IOCBULK_BAD_LEN		; same high byte, low byte over: too long
	jr IOCBULK_ARM
IOCBULK_LEN_OK:
	ld a,d
	or e
	jp z,IOCBULK_BAD_LEN		; zero length is a caller bug

	; Arm the receiver: clear any stale error latch, then keep RX enabled.
	; Auto Enables is deliberately off: /DCDA is software admission, never a
	; hardware action that disables the receiver and destroys character sync.
IOCBULK_ARM:

	; Interrupts OFF for the whole transfer.
	;
	; The MCU is clock master and NEVER waits mid-transfer -- it emits a byte
	; every 6 us whatever the Z80 is doing.  So an ISR landing inside this loop
	; is not merely latency: the MCU keeps delivering, the SIO's 3-byte receive
	; FIFO covers about 18 us, and past that bytes are simply lost.
	;
	; This is the structural difference from designs where the Z80 bit-bangs
	; the clock itself.  There, an interrupt stretches the transfer and nothing
	; is lost; here there is a producer that cannot be paused.
	;
	; Pacing cannot fix that -- it only buys a larger ISR you happen to
	; survive, and leaves correctness depending on ISR duration forever.  A
	; critical section removes the dependency.
	;
	; Cost is ~3.1 ms for a 512-byte read.  CP/M has no real-time expectation
	; and the console SIO buffers, so that is acceptable.  A periodic tick will
	; COALESCE across it, which matters if the tick is used for accounting
	; rather than just scheduling.
	;
	; Assumes the caller had interrupts enabled, which every current caller
	; does.  The fix that removes even this assumption is burst transfer: the
	; MCU stops the clock every N bytes so the host can service interrupts in
	; the gaps, bounding the blackout to ~192 us for 32-byte bursts.
	di

	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_BULK_CTRL_PORT),a
	ld a,#0x03
	out (SIO_BULK_CTRL_PORT),a
	ld a,(ioc_bulk_synced)
	or a
	ld a,#SIO_WR3_BULK_RX_NO_HUNT
	jr nz,IOCBULK_WR3
	ld a,#SIO_WR3_BULK_RX_HUNT	; first transfer only
IOCBULK_WR3:
	out (SIO_BULK_CTRL_PORT),a

	; Drain anything the previous transfer left in the receive FIFO.
	;
	; NOT optional.  A caller that reads fewer bytes than the MCU clocked
	; leaves the remainder sitting in the SIO's 3-byte FIFO, and they surface
	; at the HEAD of the next transfer -- shifting the whole payload by whole
	; bytes.  It is self-sustaining, because each transfer then leaves the same
	; count behind, and it survives a reflash: only a machine reset clears it.
	;
	; Observed exactly that when a program built before the CRC trailer asked
	; for 512 bytes of a 514-byte stream.  Every later transfer came back with
	; the previous transfer's CRC bytes prepended, and every CRC check failed.
	;
	; Enabling RX in hunt does not empty the FIFO; only reading it does.
	;
	; BOUNDED to the FIFO depth, for the same reason the command lane's drain
	; is.  Unbounded, it reads until the FIFO happens to be empty -- and since
	; the receiver now stays enabled through our own transmit, that races the
	; MCU's reply and swallows its first byte.  Measured: rd_buf came back as
	; ff 01 02 03 04 05 06 07 -- a perfect ramp with byte 0 missing and fill in
	; its place, which is a consumed byte, not a misaligned one.
	;
	; There can never be more than three stale bytes to remove.  Anything
	; arriving after that is the transfer itself and belongs to the caller.
	ld b,#(IOC_RX_FIFO_DEPTH + 1)
IOCBULK_DRAIN:
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RX_READY
	jr z,IOCBULK_DRAINED_FIFO
	in a,(SIO_BULK_DATA_PORT)
	djnz IOCBULK_DRAIN
IOCBULK_DRAINED_FIFO:

	; Tell the MCU we are in the read loop.  It is blocked waiting on this.
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_ON
	out (SIO_BULK_CTRL_PORT),a

	; RX admission.  With Auto Enables off, /DCDA no longer gates the receiver,
	; so wait for its asserted LEVEL in software before entering the byte loop.
	; The PIC asserts /DCDA, waits 100 us, and only then opens SIO1/A's clock
	; gate.  Its 1 ms RTS polling therefore adds latency but cannot race us: no
	; receive clock exists until after this poll succeeds.
	; BC is free here, so use it for the timeout and preserve DE = payload
	; length for the transfer loop that follows.
	ld bc,#0
IOCBULK_DCD_WAIT:
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_BULK_CTRL_PORT),a
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RR0_DCD
	jr nz,IOCBULK_ADMITTED
	dec bc
	ld a,b
	or c
	jr nz,IOCBULK_DCD_WAIT
	jp IOCBULK_TIMEOUT
IOCBULK_ADMITTED:
	; Locate the complete common marker.  A trailing FF from the preceding
	; transaction can remain in the SIO receive pipeline until these clocks
	; promote it into the FIFO, so the first visible byte is not a frame start.
	ld b,#IOC_BULK_PACKET_SCAN_LIMIT
IOCBULK_SYNC0:
	call IOCBULK_GET
	jp c,IOCBULK_TIMEOUT
	cp #IOC_PACKET_SYNC0
	jr z,IOCBULK_SYNC1
	djnz IOCBULK_SYNC0
	jp IOC_BULK_REJECT_MARKER
IOCBULK_SYNC1:
	call IOCBULK_GET
	jp c,IOCBULK_TIMEOUT
	cp #IOC_PACKET_SYNC1
	jr z,IOCBULK_HEADER
	cp #IOC_PACKET_SYNC0
	jr z,IOCBULK_SYNC1		; overlapping A5 A5 5A
	djnz IOCBULK_SYNC0
	jp IOC_BULK_REJECT_MARKER

IOCBULK_HEADER:
	; The MCU is already streaming at the 6 us payload rate.  Calling the
	; general byte helper five times costs more than one wire byte per byte,
	; and validating the header here used to pause for long enough to overflow
	; the three-byte SIO FIFO before the payload loop began.  Capture all five
	; bytes with the same INI-shaped loop as the payload and validate them only
	; after the complete stream is safely in RAM.
	call IOCBULK_GET_HEADER
	jp c,IOCBULK_TIMEOUT

	; IOCBULK_GET used DE as its timeout, so reload the caller's payload shape.
	ld hl,(ioc_bulk_ptr)
	ld de,(ioc_bulk_len)

	ld a,d				; whole 256-byte blocks
	ld b,e				; remainder byte count
	push af				; no register left to hold the block count
	ld c,#SIO_BULK_DATA_PORT
	ld de,#0			; whole-transfer stall budget
	ld a,b
	or a
	jr nz,IOCBULK_POLL		; take the remainder first

IOCBULK_CHUNK:
	pop af
	or a
	jr z,IOCBULK_TRAILER		; popped and not re-pushed: stack balanced
	dec a
	push af
	ld b,#0				; B = 0 means 256 bytes to INI

IOCBULK_POLL:
	in a,(SIO_BULK_CTRL_PORT)	; 11
	and #SIO_RX_READY		;  7
	jr nz,IOCBULK_GOT		; 12
	dec de				;  6
	ld a,d				;  4
	or e				;  4
	jr nz,IOCBULK_POLL		; 12
	pop af				; drop the block count before leaving
	jp IOCBULK_TIMEOUT
IOCBULK_GOT:
	ini				; 16  (HL) <- in(C), HL++, B--
	jp nz,IOCBULK_POLL		; 10
	jr IOCBULK_CHUNK

	; Payload received.  The CRC trailer follows it on the wire but does NOT
	; go into the caller's buffer -- callers pass a payload-sized buffer and
	; never see integrity.  Most significant byte first, matching the MCU.
	;
	; The payload loop above MUST land here and not on IOCBULK_DRAINED.  It
	; jumped straight past this block once, leaving ioc_bulk_crc holding
	; whatever was there before -- and what was there before is IOCBULKW's
	; precomputed CRC of the last payload it SENT, because both routines share
	; the variable.
	;
	; That is why the fault hid for so long.  The soak writes a block and then
	; reads the same block back, so the leftover CRC was exactly the CRC of the
	; data being verified and the check passed 3200 times running.  It only
	; failed once a test read a DIFFERENT record than it last wrote.  A check
	; that compares against stale state is worse than no check: it reports
	; success and suppresses the reason to look.
IOCBULK_TRAILER:
	call IOCBULK_GET
	jp c,IOCBULK_TIMEOUT
	ld (ioc_bulk_crc + 1),a		; high
	call IOCBULK_GET
	jp c,IOCBULK_TIMEOUT
	ld (ioc_bulk_crc),a		; low

	; All bytes in.  Release RTS, then confirm the MCU ended the bulk phase.
	; /CTSA is asserted for the duration of the transfer, so it should already
	; be gone; checking it costs nothing and catches an MCU that died mid
	; transfer having sent the right number of bytes.  The authoritative status
	; still comes from DONE on the command lane.
IOCBULK_DRAINED:
	call IOCBULK_RTS_OFF
	ld de,#0
IOCBULK_CTS_WAIT:
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_BULK_CTRL_PORT),a
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RR0_CTS
	jr z,IOCBULK_OK
	dec de
	ld a,d
	or e
	jr nz,IOCBULK_CTS_WAIT
	ei
	ld a,#IOC_XPORT_HW_ERROR
	ret
IOCBULK_OK:
	ei

	; Bind the packet to the READY reply that authorized this phase.  This is
	; deliberately after reception: the MCU does not stop after the header, so
	; parsing it in the middle of the wire stream overruns the receive FIFO.
	; No untrusted length is used to receive data -- the command-authoritative
	; length supplied by the caller controlled the byte loop above.
	ld hl,(ioc_bulk_len)
	ld de,#IOC_PACKET_FIXED_LEN
	add hl,de
	ld a,(ioc_packet_header)
	cp l
	jp nz,IOC_BULK_REJECT_LENGTH
	ld a,(ioc_packet_header + 1)
	cp h
	jp nz,IOC_BULK_REJECT_LENGTH
	ld a,(ioc_bulk_rx_type)
	ld c,a
	ld a,(ioc_packet_header + 2)
	cp c
	jp nz,IOC_BULK_REJECT_TYPE
	ld a,(ioc_bulk_rx_seq)
	ld c,a
	ld a,(ioc_packet_header + 3)
	cp c
	jp nz,IOC_BULK_REJECT_SEQ
	ld a,(ioc_packet_header + 4)
	or a
	jp nz,IOC_BULK_REJECT_STATUS

	; Only now check integrity: the lane is already released, so a bad CRC
	; costs one transfer rather than leaving the handshake half-done.
	ld hl,#ioc_packet_header
	ld bc,#5
	call ioc_crc_block
	ld hl,(ioc_bulk_ptr)
	ld bc,(ioc_bulk_len)
	call ioc_crc_continue		; DE = CRC(header + payload)
	ld hl,(ioc_bulk_crc)		; HL = received (L = low, H = high)
	ld a,l
	cp e
	jr nz,IOCBULK_CRC_FAIL
	ld a,h
	cp d
	jr nz,IOCBULK_CRC_FAIL

	; A CRC-verified transfer is the only evidence the bulk lane's character
	; boundary was established.  From here the receiver is left alone: no more
	; Enter Hunt on this lane.
	ld a,#1
	ld (ioc_bulk_synced),a
	xor a
	ret
IOCBULK_CRC_FAIL:
	jp IOC_BULK_REJECT_CRC

; Bulk transfer scratch.  In the code region, which is RAM after the shadow copy.
ioc_bulk_ptr:
	.dw 0
ioc_bulk_len:
	.dw 0
ioc_bulk_crc:
	.dw 0

IOCBULK_TIMEOUT:
	call IOCBULK_RTS_OFF
	ei
	ld a,#IOC_XPORT_TIMEOUT
	ret

IOCBULK_BAD_PACKET:
	call IOCBULK_RTS_OFF
	ld a,#IOC_XPORT_BAD_FRAME
	call ioc_bulk_diag_capture	; reads both SIO pointers; still masked
	ei
	ret

	; Rejected before RTS was asserted, so there is no handshake to unwind.
IOCBULK_BAD_LEN:
	jp IOC_BULK_REJECT_INPUT

IOCBULK_RTS_OFF:
	; In External Sync an enabled transmitter streams fill on underrun and may
	; never reach the empty state required for delayed RTS deassertion.  Disable
	; TX, exactly as on the Command lane, to guarantee /RTSA returns high.  WR5
	; does not touch the receiver or its character boundary.
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_IDLE
	out (SIO_BULK_CTRL_PORT),a
	ret

; ---------------------------------------------------------------------------
; IOCBULKW
; Transmit a bulk payload on SIO1/A (Bulk channel).
;
; Mirror of IOCBULK.  Owns the entire handshake: arms channel A for transmit,
; asserts RTS, sends the alignment preamble, streams the payload, releases RTS
; and confirms the MCU dropped /CTSA.  The caller touches no SIO register.
;
; The packet envelope is transport, not payload: the MCU cannot know which
; clock edge the host transmitter started on, so it searches for A5 5A at
; arbitrary bit phase and validates LEN/TYPE/SEQ/STATUS/CRC.  Callers pass DATA
; only.
;
; In:  HL = source buffer
;      DE = byte count, 1..IOC_BULK_MAX_LEN
; Out: A = IOC_XPORT_OK        all bytes sent, /CTSA seen deasserted
;        = IOC_XPORT_BAD_FRAME length zero or above IOC_BULK_MAX_LEN
;        = IOC_XPORT_TIMEOUT   transmitter stalled; RTS released
;        = IOC_XPORT_HW_ERROR  sent, but the transmitter under-ran or /CTSA
;                              never released -- the MCU received fill, not data
; Clobbers: AF, BC, DE, HL
; ISR-safe: No.  Masks interrupts for the transfer.
;
; Why this is not the read loop with the direction flipped:
;
;   - the Tx Underrun/EOM latch must be reset AFTER the first byte is in the
;     buffer.  Reset while empty and the transmitter under-runs immediately,
;     never consumes what is loaded next, and TBE stops re-asserting.
;   - a stalled transmitter streams WR7 fill (00h on this channel), which the
;     MCU receives as a well-formed block of zeros and would commit as data.
;     RR1 bit 6 is checked afterwards precisely to catch that.
;   - OUTI, not OTIR: OTIR has no timeout, so a stalled MCU would hang the
;     machine with no way back to CP/M.
; ---------------------------------------------------------------------------
IOC_CMD_CODE_END:

	.area CODE (ABS)
	.org CBIOS_IOC_BULK_CODE_BASE
IOC_BULK_CODE_START:

IOCBULKW:
	ld a,d
	cp #(IOC_BULK_MAX_LEN >> 8)
	jr c,IOCBULKW_LEN_OK
	jp nz,IOCBULKW_BAD_LEN
	ld a,#(IOC_BULK_MAX_LEN & 0xff)
	cp e
	jp c,IOCBULKW_BAD_LEN
	jr IOCBULKW_ARM
IOCBULKW_LEN_OK:
	ld a,d
	or e
	jp z,IOCBULKW_BAD_LEN

IOCBULKW_ARM:
	; Build the common header and CRC it with the payload BEFORE touching the
	; lane.  The OUTI loop has to keep
	; pace with the MCU's clock and cannot afford ~0.7 ms of arithmetic
	; inside it, and ioc_crc_block clobbers HL/BC/DE so the caller's
	; arguments have to be reloaded afterwards.
	ld (ioc_bulk_ptr),hl
	ld (ioc_bulk_len),de
	ld hl,#IOC_PACKET_FIXED_LEN
	add hl,de
	ld (ioc_packet_header),hl	; LEN low/high
	ld a,(ioc_bulk_tx_type)
	ld (ioc_packet_header + 2),a
	ld a,(ioc_bulk_tx_seq)
	ld (ioc_packet_header + 3),a
	xor a
	ld (ioc_packet_header + 4),a	; request status
	ld hl,#ioc_packet_header
	ld bc,#5
	call ioc_crc_block
	ld hl,(ioc_bulk_ptr)
	ld bc,(ioc_bulk_len)
	call ioc_crc_continue		; DE = CRC(header + payload)
	ld (ioc_bulk_crc),de
	ld hl,(ioc_bulk_ptr)
	ld de,(ioc_bulk_len)

	; Interrupts off for the transfer: the MCU is clock master and does not
	; wait, so a stall here is lost data rather than latency.
	di

	; Arm channel A for transmit without touching the persistent RX boundary.
	; The full-duplex idle bytes received while we send are drained by IOCBULK
	; before the next MCU -> Z80 transfer.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_BULK_CTRL_PORT),a
	ld a,#0x03
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR3_BULK_TX
	out (SIO_BULK_CTRL_PORT),a

	; The common RTS-off path disables TX so External Sync can actually release
	; /RTSA.  Re-enable the transmitter for this preload without touching WR3
	; or the receiver's persistent boundary; no clock exists yet, so it cannot
	; shift until the PIC admits the transfer.
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_OFF
	out (SIO_BULK_CTRL_PORT),a

	; STAGE THE FIRST PREAMBLE BYTE BEFORE RAISING RTS.
	;
	; RTS is the MCU's "go": wait_for_host_ready() returns on it and the MCU
	; then asserts /CTSA and starts clocking.  It does not ask again.  So
	; anything sitting in the transmitter at that moment is what goes on the
	; wire -- and if the buffer is still empty, that is WR7 fill.
	;
	; Raising RTS first left a window of roughly a dozen instructions in which
	; the MCU could begin clocking fill.  The preamble then arrives that many
	; bit times late, past the 64-bit search, and the MCU reports BULK_NO_SYNC
	; having captured a window that opens with idle marking and ten bits of
	; fill before any data.  That is exactly what a failing transfer's raw
	; capture showed: no complete marker anywhere, but the payload ramp present further
	; in.
	;
	; Intermittent because it is a race: whether it fails depends on where the
	; MCU happens to be in its poll when RTS goes up.  Staging the byte first
	; removes the race rather than making it less likely -- there is no longer
	; a moment when RTS is high and the transmitter is empty.
	;
	; The buffer is empty on entry and the PIC has not opened SIO1/A's clock
	; gate, so this PUT cannot race the transfer.  The sacrificial lead-in is
	; retained from the proven wire format; the real preamble follows only after
	; admission, on a transmitter that is already running.
	push de
	ld a,#IOC_BULK_LEADIN
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP

	; EOM reset still follows the first buffered byte, as it must.
	ld a,#SIO_WR0_RESET_EOM
	out (SIO_BULK_CTRL_PORT),a

	; Now say "go".  The transmitter has something to send.
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_ON
	out (SIO_BULK_CTRL_PORT),a

	; TX admission.  Auto Enables used to make /CTSA hold the transmitter shut;
	; now it is an explicit level handshake.  The staged lead-in cannot shift
	; early because the PIC owns the clock and keeps /SIOA_CS closed until after
	; it asserts /CTSA and its 100 us setup guard expires.
	ld de,#0
IOCBULKW_CTS_ADMIT_WAIT:
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_BULK_CTRL_PORT),a
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RR0_CTS
	jr nz,IOCBULKW_ADMITTED
	dec de
	ld a,d
	or e
	jr nz,IOCBULKW_CTS_ADMIT_WAIT
	jp IOCBULKW_STALL_POP
IOCBULKW_ADMITTED:

	; Byte 1 goes in after RTS of necessity: the SIO holds one buffered byte
	; plus the shift register, so a second write cannot complete until the
	; first has started shifting -- which needs the clock, which needs RTS.
	; Preamble proper, on a transmitter that is now running.
	ld a,#IOC_BULK_PREAMBLE_0
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP
	ld a,#IOC_BULK_PREAMBLE_1
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP

	; Same five-byte header used by the command lane.
	ld hl,#ioc_packet_header
	ld b,#5
IOCBULKW_HEADER:
	ld a,(hl)
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP
	inc hl
	djnz IOCBULKW_HEADER
	pop de
	ld hl,(ioc_bulk_ptr)

	; OUTI loop, 56 T-states per byte, matching IOCBULK's INI loop.  B is the
	; counter, C the port, HL the source; DE is the whole-transfer stall
	; budget, so the block count has to live on the stack.
	ld a,d				; whole 256-byte blocks
	ld b,e				; remainder
	push af
	ld c,#SIO_BULK_DATA_PORT
	ld de,#0			; whole-transfer stall budget
	ld a,b
	or a
	jp nz,IOCBULKW_POLL		; remainder first

IOCBULKW_CHUNK:
	pop af
	or a
	jp z,IOCBULKW_SENT		; popped and not re-pushed: stack balanced
	dec a
	push af
	ld b,#0				; B = 0 means 256 bytes to OUTI

IOCBULKW_POLL:
	in a,(SIO_BULK_CTRL_PORT)	; 11
	and #SIO_TX_READY		;  7
	jr nz,IOCBULKW_GOT		; 12
	dec de				;  6
	ld a,d				;  4
	or e				;  4
	jr nz,IOCBULKW_POLL		; 12
	pop af				; drop the block count
	jp IOCBULKW_STALL
IOCBULKW_GOT:
	outi				; 16  out(C) <- (HL), HL++, B--
	jp nz,IOCBULKW_POLL		; 10
	jr IOCBULKW_CHUNK

IOCBULKW_SENT:
	; CRC trailer, most significant byte first, matching the MCU.  It is
	; transport, not payload: callers pass a payload-sized buffer.
	ld a,(ioc_bulk_crc + 1)
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL
	ld a,(ioc_bulk_crc)
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL

	; Did the transmitter run dry?  RR1 bit 6 was cleared after the first
	; preamble byte, so finding it set means fill went out in place of data.
	; There is a small race -- it also sets legitimately once the final byte
	; finishes shifting -- and erring toward a false alarm is the right side
	; when the alternative is the MCU committing zeros.
	ld a,#0x01
	out (SIO_BULK_CTRL_PORT),a
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RR1_TX_UNDERRUN
	jp nz,IOCBULKW_UNDERRUN

	; WAIT FOR THE LAST BYTE TO REACH THE WIRE.
	;
	; IOCBULKW_PUT returns when the transmit BUFFER is free, which is one byte
	; earlier than the wire.  IOCBULK_RTS_OFF then writes WR5 = 00h and
	; DISABLES the transmitter, so a byte still sitting in the buffer or shift
	; register is simply discarded.
	;
	; Measured: the CRC trailer's second byte never reached the MCU.  The raw
	; window showed the payload complete through its last byte, then the CRC
	; MSB, then fill -- and the byte after a value with a clear MSB has to be
	; even under the wire's one-bit shift, so the FFh there could only be fill.
	; The MCU read fill as the CRC low byte and rejected the transfer.
	;
	; This is the bulk lane's version of the trailing filler the command lane
	; clocks for exactly the same reason.
	; PUSH THE LAST CRC BYTE ONTO THE WIRE with trailing filler.
	;
	; IOCBULKW_PUT returns when the transmit BUFFER is free, one byte before
	; the wire, and IOCBULK_RTS_OFF then disables the transmitter -- discarding
	; whatever is still in the shift register.  Measured: the CRC high byte
	; arrived correctly and the low byte was replaced by fill.
	;
	; Two fillers, not one.  PUT waits for buffer-empty, so the first
	; guarantees the CRC low byte has moved buffer -> shift register, and the
	; second guarantees it has finished shifting.  This is what the command
	; lane does; RR1's All Sent bit is an ASYNCHRONOUS-mode status and a
	; synchronous transmitter never idles -- it shifts sync characters on
	; underrun -- so waiting on it exits immediately and buys nothing.
	;
	; The MCU ignores these: it de-shifts exactly payload+CRC bytes from the
	; preamble, and the fillers land past that inside the same window.
	ld a,#IOC_BULK_LEADIN
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL
	ld a,#IOC_BULK_LEADIN
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL

	call IOCBULK_RTS_OFF
	ei

	; /CTSA is held by the MCU for the whole bulk phase -- and for a write it
	; stays asserted until the card commit finishes, so this also waits out
	; the SD write.
	;
	; Interrupts come back BEFORE the wait, not after.  Every byte is already
	; out and RTS is down, so nothing here is timing critical -- it is a poll
	; of a status bit.  Leaving them off would mean holding the machine for
	; the entire card programming time, which an SD card is entitled to
	; stretch to a couple of hundred milliseconds on an erase-block boundary.
	; That is the difference between a DI that guards a transfer and a DI
	; that guards a wait for someone else's flash.
	ld de,#0
IOCBULKW_CTS_WAIT:
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_BULK_CTRL_PORT),a
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RR0_CTS
	jr z,IOCBULKW_OK
	dec de
	ld a,d
	or e
	jr nz,IOCBULKW_CTS_WAIT
	ld a,#IOC_XPORT_HW_ERROR
	ret
IOCBULKW_OK:
	xor a
	ret

IOCBULKW_STALL_POP:
	pop de
IOCBULKW_STALL:
	call IOCBULK_RTS_OFF
	ei
	ld a,#IOC_XPORT_TIMEOUT
	ret

IOCBULKW_UNDERRUN:
	call IOCBULK_RTS_OFF
	ei
	ld a,#IOC_XPORT_HW_ERROR
	ret

	; Rejected before RTS was asserted and before the DI, so nothing to unwind.
IOCBULKW_BAD_LEN:
	ld a,#IOC_XPORT_BAD_FRAME
	ret

; Send one byte on the bulk lane.  In: A = byte.  Out: carry set on timeout.
; Clobbers: AF, DE.
IOCBULKW_PUT:
	push bc
	ld c,a
	ld de,#0
IOCBULKW_PUT_WAIT:
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_TX_READY
	jr nz,IOCBULKW_PUT_READY
	dec de
	ld a,d
	or e
	jr nz,IOCBULKW_PUT_WAIT
	pop bc
	scf
	ret
IOCBULKW_PUT_READY:
	ld a,c
	out (SIO_BULK_DATA_PORT),a
	pop bc
	or a
	ret

;
; One-time channel initialisation.
;
; sio_command_init issues WR0 = 18h, a CHANNEL RESET, which the SIO manual lists
; as one of the three things that destroy character synchronisation.  Calling it
; at the head of every IOCALL -- the "Phase 1 workaround" -- therefore made
; persistent External Sync impossible by construction.  It now runs once.
;
; Cold initialization reset both SIO channels; clear both software flags here
; so the hunt-once paths agree with that hardware state.
ioc_link_init_once:
	ld a,(ioc_link_ready)
	or a
	ret nz
	call sio_command_init
	xor a
	ld (ioc_rx_synced),a		; boundary not established yet
	ld (ioc_bulk_synced),a		; SIO1/A was reset by cold init too
	ld a,#1
	ld (ioc_link_ready),a
	xor a
	ret

;
; Cold-boot link bring-up.
;
; Sends one LINK_SYNC request through the ordinary IOCALL path.  That call runs
; ioc_link_init_once (channel reset and configuration), leaves ioc_rx_synced
; clear so the receiver enters Hunt exactly once, and the MCU's handler clears
; its own flag so the reply to this request carries the falling /SYNC edge.
; Locating that reply's preamble sets ioc_rx_synced, and from then on neither
; side touches synchronisation again.
;
; Returns A = 0 on success.  A failure here is not fatal to the boot: the link
; is simply unsynchronised, IOCALL reports transport errors, and the machine
; still runs on the VDrip console and A: drive, which share nothing with SIO1.
ioc_link_bringup:
	ld c,#IOC_LINK_BRINGUP_TRIES
ioc_lb_try:
	; Re-arm BOTH ends for each attempt.  Clearing ioc_rx_synced puts the
	; receiver back into Hunt, and the LINK_SYNC request clears the MCU's own
	; flag so its reply carries a fresh falling /SYNC edge.
	;
	; Retrying matters because the MCU sets that flag when it SENDS the edge,
	; not when the host receives it.  Without this, one missed reply left the
	; MCU believing the boundary was established and the host hunting for an
	; edge that would never come again -- an unrecoverable link from a single
	; lost byte.
	; Both lanes.  The MCU's LINK_SYNC handler resyncs command and bulk
	; together, so the host must re-arm Hunt on both or the two ends disagree
	; about which boundaries are still valid.
	xor a
	ld (ioc_rx_synced),a
	ld (ioc_bulk_synced),a

	ld hl,#MOVE_BUFFER
	ld b,#IOC_FRAME_SIZE
ioc_lb_clear:
	ld (hl),a
	inc hl
	djnz ioc_lb_clear

	ld hl,#MOVE_BUFFER
	ld (hl),#IOC_CMD_LINK_SYNC	; class; seq/status/len stay zero
	ld de,#(MOVE_BUFFER + IOC_FRAME_SIZE)
	push bc
	call IOCALL
	pop bc
	or a
	ret z				; synchronised
	dec c
	jr nz,ioc_lb_try

	ld a,#IOC_XPORT_TIMEOUT
	ret

; Adjacent and in this order because ioc_diag_capture_common copies the pair
; into the failure record with one ld hl,(nn).  Asserted below.
ioc_link_ready:	.db 0
ioc_rx_synced:	.db 0
	.if (ioc_rx_synced - ioc_link_ready) - 1
	.error 3			; capture copies these two as one 16-bit load
	.endif

; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; Link failure capture.
;
; Two entry points, one body.  Both fill the frozen 16-byte failure record at
; CBIOS_IOC_DIAG_BASE; docs/ioc-diagnostic-record.md holds the contract.
;
; These live here, with the Bulk transport in slot 3, rather than in the core
; BIOS spare region where the old capture routine sat.  Deleting the bring-up
; traces they replace is what made room here, and keeping them out of core BIOS
; is what leaves DCD0h-DD0Fh free for the core repack.
;
; Neither entry changes the interrupt state.  The register pointer is set and
; read back as an out/in pair, and an ISR touching the same SIO between those
; two instructions would silently redirect the read -- so masking stays the
; caller's decision, exactly as it was before.
; ---------------------------------------------------------------------------

; Command lane (SIO1/B).  In: A = IOC_XPORT_* status.  Out: A preserved.
; Clobbers: C, E, flags -- all within ioc_command_recv_frame's declared set.
ioc_diag_capture:
	; LANE = command AND BULK_REASON = none, in one store.  The second half
	; matters: this failure was not a Bulk packet rejection, so an older Bulk
	; stage must not be left standing beside it as though it belonged here.
	; The record's field order exists to make this a single instruction pair.
	ld hl,#0x0000
	ld (IOC_DIAG_LANE),hl
	ld c,#SIO_COMMAND_CTRL_PORT
	jr ioc_diag_capture_common

; Bulk lane (SIO1/A).  In: A = IOC_XPORT_* status.  Out: A preserved.
; The caller has already stored IOC_DIAG_BULK_REASON.
;
; BULK_TYPE/BULK_SEQ are the identity the data phase was bound to; BULK_STATUS
; comes straight out of ioc_packet_header, which still holds the rejected
; header -- so nothing has to be copied aside on the success path to have it
; available here.  That is the whole of what the old header copy existed to do.
ioc_bulk_diag_capture:
	push af
	ld a,#IOC_DIAG_LANE_BULK
	ld (IOC_DIAG_LANE),a		; BULK_REASON is the caller's, already stored
	ld a,(ioc_bulk_rx_type)
	ld (IOC_DIAG_BULK_TYPE),a
	ld a,(ioc_bulk_rx_seq)
	ld (IOC_DIAG_BULK_SEQ),a
	ld a,(ioc_packet_header + 4)
	ld (IOC_DIAG_BULK_STATUS),a
	pop af
	ld c,#SIO_BULK_CTRL_PORT

; In: A = status, C = failing lane's control port, LANE already stored.
ioc_diag_capture_common:
	ld (IOC_DIAG_STATUS),a
	push af

	; RR0 bit 4 is Sync/Hunt: 1 = the receiver is STILL HUNTING, i.e. the MCU's
	; falling /SYNC edge never landed.  That bit separates a marker that never
	; arrived from one that arrived and was rejected, which is why dropping the
	; scan-budget byte loses nothing.
	xor a
	out (c),a			; point at RR0
	in a,(c)
	ld (IOC_DIAG_RR0),a
	ld a,#0x01
	out (c),a			; point at RR1
	in a,(c)
	ld (IOC_DIAG_RR1),a

	; ioc_link_ready and ioc_rx_synced are adjacent, in that order, and the
	; record's READY/SYNCED pair mirrors them -- so both copy in one load and
	; one store.  Moving either pair apart silently costs six bytes that slot 3
	; does not have.
	ld hl,(ioc_link_ready)
	ld (IOC_DIAG_READY),hl

	; Sticky state, not an event: whether the Bulk lane has EVER completed a
	; CRC-verified transfer is the only evidence its character boundary was
	; established, and that is worth having on a command failure too.
	ld a,(ioc_bulk_synced)
	ld (IOC_DIAG_BULK_SYNCED),a

	; Correlates this failure with the controller's view of the same exchange.
	ld a,(ioc_seq)
	ld (IOC_DIAG_SEQ),a

	pop af
	ret

; Rejection stages.  The scan count and last-scanned byte are gone: the lane's
; character alignment is established, so WHICH STAGE rejected is the answer,
; not which byte the scan stopped on.
IOC_BULK_REJECT_MARKER:
	ld a,#IOC_BULK_REASON_MARKER
	jr IOC_BULK_REJECT_PACKET
IOC_BULK_REJECT_LENGTH:
	ld a,#IOC_BULK_REASON_LEN
	jr IOC_BULK_REJECT_PACKET
IOC_BULK_REJECT_TYPE:
	ld a,#IOC_BULK_REASON_TYPE
	jr IOC_BULK_REJECT_PACKET
IOC_BULK_REJECT_SEQ:
	ld a,#IOC_BULK_REASON_SEQ
	jr IOC_BULK_REJECT_PACKET
IOC_BULK_REJECT_STATUS:
	ld a,#IOC_BULK_REASON_STATUS
IOC_BULK_REJECT_PACKET:
	ld (IOC_DIAG_BULK_REASON),a
	jp IOCBULK_BAD_PACKET

; Rejected before RTS was asserted: nothing reached the wire, so the SIO state
; the record captures is the idle lane.  That is the honest reading of it.
IOC_BULK_REJECT_INPUT:
	ld a,#IOC_BULK_REASON_INPUT
	ld (IOC_DIAG_BULK_REASON),a
	ld a,#IOC_XPORT_BAD_FRAME
	jp ioc_bulk_diag_capture

; The lane is already released and interrupts restored before CRC comparison.
IOC_BULK_REJECT_CRC:
	ld a,#IOC_BULK_REASON_CRC
	ld (IOC_DIAG_BULK_REASON),a
	ld a,#IOC_XPORT_BAD_CRC
	jp ioc_bulk_diag_capture

; Receive the five-byte common header without falling behind the MCU's Bulk
; byte rate.  A single whole-header timeout budget replaces five call/return
; pairs and five reloads.  INI provides the same 56-T-state ready path as the
; payload loop below it.
; Out: carry set on timeout.  Clobbers: AF, BC, DE, HL.
IOCBULK_GET_HEADER:
	ld hl,#ioc_packet_header
	ld b,#5
	ld c,#SIO_BULK_DATA_PORT
	ld de,#0
IOCBULK_GET_HEADER_WAIT:
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,IOCBULK_GET_HEADER_READY
	dec de
	ld a,d
	or e
	jr nz,IOCBULK_GET_HEADER_WAIT
	scf
	ret
IOCBULK_GET_HEADER_READY:
	ini
	jp nz,IOCBULK_GET_HEADER_WAIT
	or a				; clear carry
	ret

; Receive one byte from the bulk lane.  Carry set on timeout.
; Clobbers: AF, DE.
IOCBULK_GET:
	ld de,#0
IOCBULK_GET_WAIT:
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RX_READY
	jr nz,IOCBULK_GET_READY
	dec de
	ld a,d
	or e
	jr nz,IOCBULK_GET_WAIT
	scf
	ret
IOCBULK_GET_READY:
	in a,(SIO_BULK_DATA_PORT)
	or a				; clear carry
	ret

IOC_BULK_CODE_END:

	.area CODE (ABS)
