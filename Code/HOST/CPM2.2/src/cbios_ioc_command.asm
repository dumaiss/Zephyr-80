; Zephyr-80 BIOS IOC Command-channel byte helpers — Phase 1.
;
; These routines provide polled byte I/O and fixed-frame send/receive for
; the IO Controller Command channel (SIO1/B — bring-up retarget; see
; cbios_defs.inc).
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
; SIO1/B External Sync framing:
;   BIOS sends a software preamble byte followed by 32 transparent IOC payload
;   bytes.  The MCU drives /SYNCB and the clock; BIOS receives bytes from the
;   SIO RX buffer and hunts the preamble before copying the 32-byte reply.
;
; Placement:
;   CBIOS_IOC_COMMAND_CODE_BASE = F52Ch (gap after VDrip console driver).

	.globl sio_command_rts_assert,sio_command_rts_release
	.globl sio_command_put_byte,sio_command_get_byte
	.globl sio_command_wait_ready
	.globl ioc_command_send_frame,ioc_command_recv_frame
	.globl IOCBULK,IOCBULKW
	.globl ioc_frame_crc,ioc_crc_block,ioc_frame_stamp,ioc_frame_check
	.globl IOC_CMD_CODE_START,IOC_CMD_CODE_END

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
; ioc_frame_crc
; CRC-16-CCITT (poly 1021h, init 0000h, MSB first) over the first
; IOC_CRC_COVERED bytes of the frame at HL.
;
; Nibble table: two lookups per byte, 32 bytes of table, ~70 T-states per byte.
; 30 bytes costs ~210 us, paid twice per transaction against a ~2 ms transfer.
; A bitwise loop would be ~720 us each and a 256-entry table would cost 512
; bytes of BIOS for a saving that does not matter at this frame size.
;
; Must match sio_link_crc16_update() on the MCU, which is the same algorithm.
;
; In:  HL = frame
; Out: DE = CRC
; Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
ioc_frame_crc:
	ld bc,#IOC_CRC_COVERED
	; fall through

; ---------------------------------------------------------------------------
; ioc_crc_block
; Same CRC over an arbitrary run, so one engine serves both lanes: 30-byte
; command frames and 512-byte bulk payloads.
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

; ---------------------------------------------------------------------------
; ioc_frame_stamp — write the outgoing sequence and CRC into the frame at HL.
; In:  HL = frame.  Out: A = the sequence stamped.  Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
ioc_frame_stamp:
	; Next sequence.  Rolls modulo 256; 0 is not special.
	ld a,(ioc_seq)
	inc a
	ld (ioc_seq),a

	push hl
	inc hl				; IOC_OFF_SEQ = 1
	ld (hl),a
	pop hl

	push hl
	call ioc_frame_crc		; DE = CRC over bytes 0..IOC_CRC_COVERED-1
	pop hl

	push hl
	ld bc,#IOC_OFF_CRC_LO
	add hl,bc
	ld (hl),e
	inc hl
	ld (hl),d
	pop hl

	ld a,(ioc_seq)
	ret

; ---------------------------------------------------------------------------
; ioc_frame_check — verify the CRC of the frame at HL.
; Out: A = 0 if the CRC matches, non-zero otherwise.  Clobbers: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
ioc_frame_check:
	push hl
	call ioc_frame_crc		; DE = computed
	pop hl
	push hl
	ld bc,#IOC_OFF_CRC_LO
	add hl,bc
	ld a,(hl)
	cp e
	jr nz,IOC_CRC_BAD
	inc hl
	ld a,(hl)
	cp d
	jr nz,IOC_CRC_BAD
	pop hl
	xor a
	ret
IOC_CRC_BAD:
	pop hl
	ld a,#1
	ret

; Rolling transaction sequence.  Lives in the code region, which is RAM at
; runtime after the shadow copy.
ioc_seq:
	.db 0

; ---------------------------------------------------------------------------
; ioc_command_send_frame
; Send exactly IOC_FRAME_SIZE (32) bytes via SIO1/B (Command channel) in
; External Sync mode (transparent bytes; optional software preamble only).
;
; Z80 SIO synchronous-transmit requirement: after the first data byte is loaded
; the Tx Underrun/EOM latch must be reset (WR0 = 0xC0) so the transmitter leaves
; its idle/mark state and shifts the buffered data.  Without this the first byte
; is never consumed, TBE never re-asserts, and the send times out.
; In:  HL = pointer to 32-byte TX frame in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
; Clobbers: AF, B, C, DE, HL
; ---------------------------------------------------------------------------
ioc_command_send_frame:
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

	; Optional sync preamble first (byte-alignment marker for the MCU), then reset the
	; Tx Underrun/EOM latch so the transmitter shifts the buffered bytes.
	ld c,#IOC_SYNC_PREAMBLE
	call sio_command_put_byte
	or a
	jr z,IOC_CMD_SEND_EOM
	ei
	ret				; return error code on timeout
IOC_CMD_SEND_EOM:
	ld a,#0xc0			; WR0: Reset Tx Underrun/EOM latch
	out (SIO_COMMAND_CTRL_PORT),a

	; 32 transparent frame bytes.
	ld b,#IOC_FRAME_SIZE
IOC_CMD_SEND_LOOP:
	ld c,(hl)
	call sio_command_put_byte
	or a
	jr z,IOC_CMD_SEND_NEXT
	ei
	ret				; return error code on timeout
IOC_CMD_SEND_NEXT:
	inc hl
	djnz IOC_CMD_SEND_LOOP

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
	jr z,IOC_CMD_SEND_TRAIL_NEXT
	ei
	ret
IOC_CMD_SEND_TRAIL_NEXT:
	djnz IOC_CMD_SEND_TRAILER

	; Deliberately returns with interrupts STILL MASKED on success.
	;
	; The MCU begins its reply only EXTSYNC_REPLY_GUARD_US (200 us) after the
	; request window, and the host must have its receiver armed and hunting by
	; then.  Re-enabling here let a pending interrupt -- one is always pending,
	; the send masks for ~1.1 ms -- run before the arm, and with console
	; interrupts stacking on top the receiver could be armed part-way through
	; the reply.  It then synced on a later edge, saw no 7Eh, and timed out:
	; RR0 showed hunt CLEAR with no byte available.
	;
	; ioc_command_recv_frame arms the receiver and re-enables interrupts before
	; its scan.  Error exits above re-enable normally; only this path stays
	; masked, and only until the arm.
	xor a
	ret

; ---------------------------------------------------------------------------
; ioc_command_recv_frame
; Receive exactly IOC_FRAME_SIZE (32) bytes from SIO1/B (Command channel).
; BIOS hunts the optional software preamble when present, or accepts a direct
; PING reply class byte at the start of the receive window during bring-up.
; In:  DE = pointer to 32-byte RX frame buffer in caller RAM
; Out: A = IOC_XPORT_OK or IOC_XPORT_TIMEOUT on error
;      32-byte frame written to buffer at DE on success.
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
	; RX was disabled during request TX, so the request-capture clock window
	; cannot fill the SIO RX FIFO with full-duplex junk.  Clear any stale error
	; latch, then enable RX in hunt mode before the PIC's guarded reply sync
	; sequence starts.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#0x03
	out (SIO_COMMAND_CTRL_PORT),a
	ld a,#SIO_WR3_CMD_RX
	out (SIO_COMMAND_CTRL_PORT),a

	; Receiver is armed and hunting; the reply can no longer be missed.
	; Everything from here to the preamble match is the WAIT, so unmask.
	ei

	push de
	pop hl				; HL = RX buffer pointer

	; Skip received bytes until the sync preamble is seen (byte boundary is
	; provided by the SIO RX via /SYNC; we just locate the frame start).
	; Bounded so a missing preamble fails rather than spinning.
	ld b,#SIO_COMMAND_REPLY_SCAN_LIMIT
IOC_CMD_RECV_SYNC:
	call sio_command_get_byte	; clobbers AF,C; preserves B,DE,HL
	or a
	jr nz,IOC_CMD_RECV_SYNC_TIMEOUT
	ld a,c
	cp #IOC_SYNC_PREAMBLE
	jr z,IOC_CMD_RECV_BODY
	cp #IOC_RSP_PING
	jr z,IOC_CMD_RECV_BODY_FIRST
	djnz IOC_CMD_RECV_SYNC
	ld a,#IOC_XPORT_BAD_FRAME	; preamble not found in window
	ret

; The preamble scan above runs with interrupts ENABLED: it is the WAIT for the
; MCU's reply, and that wait spans any card I/O the command triggered -- up to a
; second.  Masking it would be the multi-millisecond blackout the design
; explicitly rules out.
;
; From here the bytes are streaming and the MCU will not pause, so the body is
; masked.  32 bytes at the command pacing, ~1 ms.
IOC_CMD_RECV_BODY_FIRST:
	di
	ld (hl),c			; no preamble visible; first byte is reply class
	inc hl
	ld b,#(IOC_FRAME_SIZE - 1)
	jr IOC_CMD_RECV_LOOP

IOC_CMD_RECV_BODY:
	di
	ld b,#IOC_FRAME_SIZE
IOC_CMD_RECV_LOOP:
	call sio_command_get_byte
	or a
	jr nz,IOC_CMD_RECV_BODY_TIMEOUT
	ld (hl),c
	inc hl
	djnz IOC_CMD_RECV_LOOP
	ei
	xor a
	ret

IOC_CMD_RECV_SYNC_TIMEOUT:
	ld a,#IOC_XPORT_TIMEOUT_REPLY_MARKER
	ret

IOC_CMD_RECV_BODY_TIMEOUT:
	ei
	ld a,#IOC_XPORT_TIMEOUT_REPLY_BODY
	ret

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

	; Arm the receiver: clear any stale error latch, then RX enable in hunt
	; with Auto Enables.  /DCDA is still deasserted by the MCU at this point,
	; so the receiver stays gated off and nothing can be latched early.
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
	ld a,#SIO_WR3_BULK_RX
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
IOCBULK_DRAIN:
	in a,(SIO_BULK_CTRL_PORT)
	and #SIO_RX_READY
	jr z,IOCBULK_DRAINED_FIFO
	in a,(SIO_BULK_DATA_PORT)
	jr IOCBULK_DRAIN
IOCBULK_DRAINED_FIFO:

	; Tell the MCU we are in the read loop.  It is blocked waiting on this.
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_ON
	out (SIO_BULK_CTRL_PORT),a

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
	jr z,IOCBULK_DRAINED		; popped and not re-pushed: stack balanced
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
	jr IOCBULK_TIMEOUT
IOCBULK_GOT:
	ini				; 16  (HL) <- in(C), HL++, B--
	jp nz,IOCBULK_POLL		; 10
	jr IOCBULK_CHUNK

	; Payload received.  The CRC trailer follows it on the wire but does NOT
	; go into the caller's buffer -- callers pass a payload-sized buffer and
	; never see integrity.  Most significant byte first, matching the MCU.
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
	; Only now check integrity: the lane is already released, so a bad CRC
	; costs one transfer rather than leaving the handshake half-done.
	ld hl,(ioc_bulk_ptr)
	ld bc,(ioc_bulk_len)
	call ioc_crc_block		; DE = computed
	ld hl,(ioc_bulk_crc)		; HL = received (L = low, H = high)
	ld a,l
	cp e
	jr nz,IOCBULK_CRC_FAIL
	ld a,h
	cp d
	jr nz,IOCBULK_CRC_FAIL
	xor a
	ret
IOCBULK_CRC_FAIL:
	ld a,#IOC_XPORT_BAD_CRC
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

	; Rejected before RTS was asserted, so there is no handshake to unwind.
IOCBULK_BAD_LEN:
	ld a,#IOC_XPORT_BAD_FRAME
	ret

IOCBULK_RTS_OFF:
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_OFF
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
; The preamble is transport, not payload: the MCU cannot know which clock edge
; the host's transmitter started on, so it searches for 7E 81 and de-shifts the
; rest against it.  Callers pass payload only.
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
	; CRC the payload BEFORE touching the lane.  The OUTI loop has to keep
	; pace with the MCU's clock and cannot afford ~0.7 ms of arithmetic
	; inside it, and ioc_crc_block clobbers HL/BC/DE so the caller's
	; arguments have to be reloaded afterwards.
	ld (ioc_bulk_ptr),hl
	ld (ioc_bulk_len),de
	push de
	pop bc
	call ioc_crc_block		; DE = CRC over the payload
	ld (ioc_bulk_crc),de
	ld hl,(ioc_bulk_ptr)
	ld de,(ioc_bulk_len)

	; Interrupts off for the transfer: the MCU is clock master and does not
	; wait, so a stall here is lost data rather than latency.
	di

	; Arm channel A for transmit.  RX stays DISABLED -- nothing is being sent
	; to us, and with Auto Enables the receiver would be gated by /DCDA anyway.
	ld a,#SIO_WR0_RESET_ERROR
	out (SIO_BULK_CTRL_PORT),a
	ld a,#0x03
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR3_BULK_TX
	out (SIO_BULK_CTRL_PORT),a
	ld a,#0x05
	out (SIO_BULK_CTRL_PORT),a
	ld a,#SIO_WR5_BULK_RTS_ON
	out (SIO_BULK_CTRL_PORT),a

	; Preamble byte 0, THEN the EOM reset, THEN byte 1.  See the note above:
	; the order is not interchangeable.
	push de
	ld a,#IOC_BULK_PREAMBLE_0
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP
	ld a,#SIO_WR0_RESET_EOM
	out (SIO_BULK_CTRL_PORT),a
	ld a,#IOC_BULK_PREAMBLE_1
	call IOCBULKW_PUT
	jp c,IOCBULKW_STALL_POP
	pop de

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

IOC_CMD_CODE_END:

	.area CODE (ABS)
